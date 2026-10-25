#!/usr/bin/env bash
# ExecStartPre=+ of wildfly.service: reads the secret with the instance role and writes it to
# /run/wildfly/secrets.env (tmpfs, 0640 root:wildfly), which systemd loads with EnvironmentFile
# before ExecStart. The values never reach a persistent disk, so no AMI contains them, and
# standalone.xml only holds ${env.KEY} expressions.
# shellcheck disable=SC2154  # REGION and SECRET_ID come from instance.env
set -euo pipefail

# shellcheck source=remote/common.sh
source "$(dirname "$0")/common.sh"

SECRETS_FILE=/run/wildfly/secrets.env

# A missing secret is an empty one. SECRET_ID=file://… reads a local JSON file: the test
# container has no AWS credentials.
read_secret() {
  local output
  case "$SECRET_ID" in
    file://*) cat "${SECRET_ID#file://}"; return ;;
  esac
  if output=$(aws secretsmanager get-secret-value \
    --region "$REGION" \
    --secret-id "$SECRET_ID" \
    --query SecretString \
    --output text 2>&1); then
    printf '%s' "$output"
  elif [[ "$output" == *ResourceNotFoundException* ]]; then
    printf '{}'
  else
    printf '%s\n' "$output" >&2
    return 1
  fi
}

# KEY="value": inside double quotes systemd unescapes \" and \\ (what @json writes), but not \n,
# so a multi-line value cannot travel in an EnvironmentFile and is refused.
write_env_file() {
  local tmp="${SECRETS_FILE}.new"
  [ -d "${SECRETS_FILE%/*}" ] || install -d -m 0750 -o root -g wildfly "${SECRETS_FILE%/*}"
  (umask 0177 && jq -r '
    if any(.[]; tostring | test("[\r\n]")) then error("secret values must be single-line")
    else to_entries[] | "\(.key)=\(.value | tostring | @json)" end' > "$tmp") <<<"$1"
  chown root:wildfly "$tmp"
  chmod 0640 "$tmp"
  mv -f "$tmp" "$SECRETS_FILE"
}

main() {
  local secret attempt
  load_instance_env
  # At boot the network can still be coming up.
  for attempt in 1 2 3; do
    secret=$(read_secret) && break
    [ "$attempt" -lt 3 ] || exit 1
    sleep 5
  done
  write_env_file "$secret"
}

main "$@"
