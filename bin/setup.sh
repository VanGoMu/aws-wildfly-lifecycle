#!/usr/bin/env bash
# 0 · The foundation. up: check the pinned CodeDeploy agent, deploy templates/foundation.yml,
# publish platform.zip, render and register the documents and runbooks, and point
# …/state/active-color at blue. render: only build/ssm/*.yml and build/events/*, which the console
# manual pastes.
# down: the documents, every version in the bucket, and the foundation stack.
# shellcheck source-path=SCRIPTDIR/..
set -euo pipefail

LIB="$(cd "$(dirname "$0")/../lib" && pwd)"
# shellcheck source=lib/common.sh
source "${LIB}/common.sh"
# shellcheck source=lib/cfn.sh
source "${LIB}/cfn.sh"
# shellcheck source=lib/ssm.sh
source "${LIB}/ssm.sh"
# shellcheck source=lib/release.sh
source "${LIB}/release.sh"

usage() {
  echo "usage: ${0##*/} up | render | down" >&2
  exit 2
}

# The agent 2.x is being published region by region. The resource kit bucket is public.
check_agent() {
  local url="https://aws-codedeploy-${AWS_REGION}.s3.${AWS_REGION}.amazonaws.com/releases"
  url="${url}/codedeploy-agent-${CODEDEPLOY_AGENT_VERSION}.x86_64.rpm"
  curl -sfI "$url" >/dev/null \
    || die "CodeDeploy agent ${CODEDEPLOY_AGENT_VERSION} is not published in ${AWS_REGION}: ${url}"
}

# The sub claim depends on the repository (classic or immutable IDs): it is read, not guessed.
github_subject() {
  local prefix
  [ -n "$GITHUB_REPOSITORY" ] || return 0
  require_cmd gh
  prefix=$(gh api "repos/${GITHUB_REPOSITORY}/actions/oidc/customization/sub" \
    --jq .sub_claim_prefix) || return 1
  printf '%s:environment:%s' "$prefix" "$ENV_NAME"
}

deploy_foundation() {
  local subject
  subject=$(github_subject) || die "cannot read the OIDC sub of ${GITHUB_REPOSITORY}: gh auth login"
  deploy_stack "$STACK_FOUNDATION" foundation.yml foundation \
    "Project=${PROJECT}" \
    "EnvName=${ENV_NAME}" \
    "Prefix=${PREFIX}" \
    "BucketName=${BUCKET}" \
    "ParameterRoot=${PARAM_ROOT}" \
    "SecretName=${SECRET_ID}" \
    "GitHubSubject=${subject}" \
    "CreateOidcProvider=${CREATE_OIDC_PROVIDER}" || die "${STACK_FOUNDATION} failed"
  [ -z "$subject" ] || log "GitHub role: $(stack_output "$STACK_FOUNDATION" GitHubRoleArn)"
}

# The key is the hash of the content: a 412 means these exact scripts are already there.
publish_platform() {
  local status=0
  publish_release "${ROOT_DIR}/build/platform/platform.zip" "$PLATFORM_KEY" >/dev/null || status=$?
  case "$status" in
    0) log "platform.zip published" ;;
    3) log "platform.zip ${PLATFORM_SHA256:0:12} already published" ;;
    *) die "platform.zip was not published" ;;
  esac
}

init_state() {
  local output
  output=$(aws ssm put-parameter \
    --name "${STATE_PATH}/active-color" \
    --type String \
    --value blue 2>&1) && { log "active color: blue"; return 0; }
  [[ "$output" == *ParameterAlreadyExists* ]] || die "$output"
  log "active color: $(state_get active-color)"
}

# Every version and every delete marker: s3 rm --recursive leaves them in a versioned bucket.
empty_bucket() {
  local batch
  while batch=$(aws s3api list-object-versions \
    --bucket "$BUCKET" \
    --max-items 1000 \
    --output json 2>/dev/null \
    | jq -c '{Objects: [(.Versions // [])[], (.DeleteMarkers // [])[] | {Key, VersionId}],
              Quiet: true}'); do
    [ "$(jq '.Objects | length' <<<"$batch")" -gt 0 ] || return 0
    aws s3api delete-objects \
      --bucket "$BUCKET" \
      --delete file:///dev/stdin <<<"$batch" >/dev/null
  done
}

# The pattern and the input transformer of the release rule, from templates/foundation.yml with
# the bucket filled in: what the EventBridge console asks for.
render_rule() {
  local template="${ROOT_DIR}/templates/foundation.yml" out="${ROOT_DIR}/build/events"
  local rule='.Resources.ReleaseRule.Properties' input
  input="${rule}.Targets[0].InputTransformer"
  mkdir -p "$out"
  yq -o=json "${rule}.EventPattern | .detail.bucket.name = [strenv(BUCKET)]" "$template" \
    > "${out}/release-pattern.json"
  yq -o=json "${input}.InputPathsMap" "$template" > "${out}/release-input-paths.json"
  yq "${input}.InputTemplate" "$template" > "${out}/release-input-template.txt"
  log "rendered build/events (rule ${PREFIX}-release)"
}

up() {
  check_agent
  deploy_foundation
  render_documents
  publish_platform
  sync_documents
  init_state
  # S3 documents it ("Enabling Amazon EventBridge"): about five minutes after enabling it.
  warn "S3 takes about five minutes to start delivering events to EventBridge"
}

down() {
  confirm "Delete the documents, every version in ${BUCKET} and ${STACK_FOUNDATION}?"
  delete_documents
  empty_bucket
  delete_stack "$STACK_FOUNDATION"
}

main() {
  case "${1:-} $#" in
    "up 1" | "render 1" | "down 1") ;;
    *) usage ;;
  esac
  load_config
  require_cmd yq jq zip curl
  case "$1" in
    up) up ;;
    render) render_documents && render_rule ;;
    down) down ;;
  esac
}

main "$@"
