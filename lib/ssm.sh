#!/usr/bin/env bash
# Systems Manager: state parameters, managed instances, Run Command and the four documents.

# Run Command waits up to this long: more than the 600 s delivery timeout plus the 1,800 s of
# the longest document (InstallWildFly), so the poll never gives up on a command still running.
COMMAND_WAIT_SECONDS=3000

# state_get NAME [DEFAULT]: …/state/NAME, or DEFAULT when it does not exist.
state_get() {
  aws ssm get-parameter \
    --name "${STATE_PATH}/$1" \
    --query Parameter.Value \
    --output text 2>/dev/null || printf '%s' "${2:-}"
}

# infra_alb [JQ_FILTER]: the …/infra/alb contract, or nothing when there is no ALB.
infra_alb() {
  local value
  value=$(aws ssm get-parameter \
    --name "$INFRA_ALB" \
    --query Parameter.Value \
    --output text 2>/dev/null) || return 0
  jq -r "${1:-.}" <<<"$value"
}

wait_online() {
  local instance="$1" status="" n
  log "waiting for ${instance} to be Online in Systems Manager"
  for ((n = 0; n < 60; n++)); do
    status=$(aws ssm describe-instance-information \
      --filters "Key=InstanceIds,Values=${instance}" \
      --query 'InstanceInformationList[0].PingStatus' \
      --output text 2>/dev/null) || status=""
    [ "$status" != Online ] || return 0
    sleep 10
  done
  die "${instance} is not Online after 10 minutes (last status: ${status:-none})"
}

wait_command() {
  local command_id="$1" status="" waited
  for ((waited = 0; waited < COMMAND_WAIT_SECONDS; waited += 10)); do
    status=$(aws ssm list-command-invocations \
      --command-id "$command_id" \
      --query 'CommandInvocations[0].Status' \
      --output text) || return 1
    case "$status" in
      Success | Failed | Cancelled | TimedOut) break ;;
    esac
    sleep 10
  done
  printf '%s' "$status"
}

# plugin_output COMMAND_ID INSTANCE PLUGIN FIELD: one field of one step of the invocation.
plugin_output() {
  aws ssm get-command-invocation \
    --command-id "$1" \
    --instance-id "$2" \
    --plugin-name "$3" \
    --query "$4" \
    --output text
}

# run_document DOCUMENT INSTANCE [Name=value…]: Run Command and wait. stdout gets the standard
# output of every step, cut to its last lines (the API returns at most 24,000 characters per
# step anyway); stderr gets their standard error. Fails when the command does not succeed.
run_document() {
  local document="$1" instance="$2" command_id status plugin
  shift 2
  command_id=$(aws ssm send-command \
    --document-name "$document" \
    --instance-ids "$instance" \
    --parameters "$(parameters_json "$@")" \
    --timeout-seconds 600 \
    --comment "${0##*/} ${document}" \
    --query Command.CommandId \
    --output text) || return 1
  log "Run Command ${command_id}: ${document} on ${instance}"
  status=$(wait_command "$command_id") || return 1

  for plugin in $(aws ssm list-command-invocations \
    --command-id "$command_id" \
    --details \
    --query 'CommandInvocations[0].CommandPlugins[].Name' \
    --output text); do
    plugin_output "$command_id" "$instance" "$plugin" StandardOutputContent | tail -n 60
    plugin_output "$command_id" "$instance" "$plugin" StandardErrorContent | tail -n 30 >&2
  done
  [ "$status" = Success ] || { warn "${document} on ${instance}: ${status}"; return 1; }
}

# The documents: source file in ssm/, registered name, document type.
documents() {
  printf '%s\n' \
    "install-wildfly ${DOC_INSTALL} Command" \
    "validate ${DOC_VALIDATE} Command" \
    "release ${DOC_RELEASE} Automation" \
    "switch ${DOC_SWITCH} Automation"
}

# The derived names and the configuration each document needs, as the default of the parameter
# with the same name. Instances then run the documents without parameters.
document_defaults() {
  local vendor="s3://${BUCKET}/vendor/wildfly/${WILDFLY_VERSION}/wildfly-${WILDFLY_VERSION}.tar.gz"
  printf '%s\n' \
    "Region=${AWS_REGION}" "Environment=${ENV_NAME}" "Project=${PROJECT}" "Prefix=${PREFIX}" \
    "Bucket=${BUCKET}" "ParameterRoot=${PARAM_ROOT}" "ConfigPath=${CONFIG_PATH}" \
    "SecretId=${SECRET_ID}" "SwitchRunbook=${DOC_SWITCH}" "ValidateDocument=${DOC_VALIDATE}" \
    "AutomationAssumeRole=${AUTOMATION_ROLE_ARN}" "CanaryWeight=${CANARY_WEIGHT}" \
    "AppPort=${APP_PORT}" "HealthPath=${HEALTH_PATH}" "JavaPackage=${JAVA_PACKAGE}" \
    "WildFlyVersion=${WILDFLY_VERSION}" "WildFlySha256=${WILDFLY_SHA256}" \
    "WildFlySource=${vendor}" "CodeDeployAgentVersion=${CODEDEPLOY_AGENT_VERSION}" \
    "PlatformSource=s3://${BUCKET}/${PLATFORM_KEY}" "PlatformSha256=${PLATFORM_SHA256}" \
    | jq -Rn '[inputs | capture("^(?<key>[^=]+)=(?<value>.*)$")] | from_entries
      | .CanaryWeight |= tonumber'
}

# What the render injects besides the defaults: the real bash and Python files, which stay
# ordinary files that shellcheck and ruff check, and two constants of the canary.
render_expression() {
  local load='load_str(strenv(ROOT_DIR) + "/'
  case "$1" in
    install-wildfly)
      printf '%s' ".mainSteps[0].inputs.runCommand = [${load}remote/install-wildfly.sh\")]" ;;
    validate) printf '%s' '.' ;;
    release | switch)
      printf '%s' "(.mainSteps[] | select(.action == \"aws:executeScript\") | .inputs.Script)
          = ${load}automation/runbook.py\")
        | (.mainSteps[] | select(.name == \"Observe\") | .inputs.Duration) = strenv(OBSERVE)
        | (.mainSteps[] | select(.name == \"CheckCanary\") | .inputs.InputPayload.MinRequests)
          = (strenv(MIN_REQUESTS) | tonumber)" ;;
  esac
}

# Observe waits the canary window plus two minutes, because ALB metrics arrive late.
render_documents() {
  local out="${ROOT_DIR}/build/ssm" source name type
  local defaults='with(select(has("parameters")); .parameters |= with_entries(
    .value.default = (load(strenv(DEFAULTS))[.key] // .value.default)))'
  build_platform
  mkdir -p "$out"
  document_defaults > "${out}/defaults.json"
  while read -r source name type; do
    DEFAULTS="${out}/defaults.json" OBSERVE="PT$((CANARY_MINUTES + 2))M" \
      MIN_REQUESTS="$CANARY_MIN_REQUESTS" \
      yq "${defaults} | $(render_expression "$source")" \
      "${ROOT_DIR}/ssm/${source}.yml" > "${out}/${source}.yml"
  done < <(documents)
  log "rendered build/ssm (platform.zip ${PLATFORM_SHA256:0:12})"
}

# sync_document NAME TYPE FILE: create; or update and make it the default, only if it changed.
sync_document() {
  local name="$1" type="$2" file="$3" remote output
  if ! remote=$(aws ssm describe-document \
    --name "$name" \
    --query Document.Hash \
    --output text 2>/dev/null); then
    aws ssm create-document \
      --name "$name" \
      --document-type "$type" \
      --document-format YAML \
      --content "file://${file}" \
      --tags "Key=Project,Value=${PROJECT}" "Key=Environment,Value=${ENV_NAME}" \
      "Key=Component,Value=ssm" >/dev/null
    log "${name}: created"
    return 0
  fi
  [ "$remote" != "$(sha256sum "$file" | cut -d' ' -f1)" ] || { log "${name}: unchanged"; return 0; }

  if ! output=$(aws ssm update-document \
    --name "$name" \
    --document-format YAML \
    --content "file://${file}" \
    --document-version '$LATEST' \
    --query DocumentDescription.DocumentVersion \
    --output text 2>&1); then
    [[ "$output" == *DuplicateDocumentContent* ]] || die "${name}: ${output}"
    log "${name}: unchanged"
    return 0
  fi
  aws ssm update-document-default-version \
    --name "$name" \
    --document-version "$output" >/dev/null
  log "${name}: version ${output} is now the default"
}

sync_documents() {
  local source name type
  while read -r source name type; do
    sync_document "$name" "$type" "${ROOT_DIR}/build/ssm/${source}.yml"
  done < <(documents)
}

delete_documents() {
  local source name type
  while read -r source name type; do
    if aws ssm delete-document --name "$name" 2>/dev/null; then
      log "${name}: deleted (${type})"
    fi
  done < <(documents)
}
