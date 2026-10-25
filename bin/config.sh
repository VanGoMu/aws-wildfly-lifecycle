#!/usr/bin/env bash
# 4 · The configuration lifecycle. set, unset and secret change what the instances read
# (Parameter Store and the secret); release builds and publishes the configuration release of the
# contract (--dry-run only builds it); apply takes a version, or the active one, through Release.
# Applying the same version after a set or a rotation is normal: the fingerprint changes.
# shellcheck source-path=SCRIPTDIR/..
set -euo pipefail

LIB="$(cd "$(dirname "$0")/../lib" && pwd)"
# shellcheck source=lib/common.sh
source "${LIB}/common.sh"
# shellcheck source=lib/release.sh
source "${LIB}/release.sh"
# shellcheck source=lib/automation.sh
source "${LIB}/automation.sh"

NAME_PATTERN='^app\.[a-z0-9.-]+$'
KEY_PATTERN='^[A-Z][A-Z0-9_]{0,63}$'
GALAXY=https://galaxy.ansible.com/api/v3/plugin/ansible/content/published/collections/artifacts

usage() {
  cat >&2 <<EOF_USAGE
usage: ${0##*/} set <name> <value> | unset <name> | secret <KEY> | show
                 | release <version> [--dry-run] | apply [<version>]
  <name> matches ${NAME_PATTERN}, <value> is one line of up to 4 KB;
  <KEY> matches ${KEY_PATTERN} and its value is read from stdin
EOF_USAGE
  exit 2
}

set_parameter() {
  aws ssm put-parameter \
    --name "${CONFIG_PATH}/$1" \
    --type String \
    --value "$2" \
    --overwrite >/dev/null
  log "${CONFIG_PATH}/$1 set; it reaches the instances with: bin/config.sh apply"
}

# The value comes from stdin without echo, never as an argument (it would stay in the shell
# history), and reaches the CLI through stdin, never through argv. One line: systemd cannot carry
# a multi-line value in an EnvironmentFile. AWS-managed key aws/secretsmanager, no CMK.
set_secret() {
  local key="$1" value current
  if [ -t 0 ]; then
    read -rs -p "${key}: " value
    echo >&2
  else
    IFS= read -r value
  fi
  [ -n "$value" ] || die "empty value"

  if ! current=$(aws secretsmanager get-secret-value \
    --secret-id "$SECRET_ID" \
    --query SecretString \
    --output text 2>&1); then
    [[ "$current" == *ResourceNotFoundException* ]] || die "$current"
    jq -nc --arg k "$key" --rawfile v /dev/fd/3 '{($k): ($v | rtrimstr("\n"))}' 3<<<"$value" \
      | aws secretsmanager create-secret \
        --name "$SECRET_ID" \
        --secret-string file:///dev/stdin \
        --tags "Key=Project,Value=${PROJECT}" "Key=Environment,Value=${ENV_NAME}" \
        "Key=Component,Value=config" >/dev/null
  else
    jq -c --arg k "$key" --rawfile v /dev/fd/3 '.[$k] = ($v | rtrimstr("\n"))' \
      <<<"$current" 3<<<"$value" \
      | aws secretsmanager put-secret-value \
        --secret-id "$SECRET_ID" \
        --secret-string file:///dev/stdin >/dev/null
  fi
  log "${SECRET_ID}: ${key} stored; WildFly reads it after bin/config.sh apply"
}

# The configuration, and of the secret only the key names.
show() {
  log "Parameter Store ${CONFIG_PATH}:"
  aws ssm get-parameters-by-path \
    --path "$CONFIG_PATH" \
    --recursive \
    --query 'Parameters[].[Name, Value]' \
    --output text | sed "s|^${CONFIG_PATH}/|  |" >&2
  log "keys of ${SECRET_ID}:"
  aws secretsmanager get-secret-value \
    --secret-id "$SECRET_ID" \
    --query SecretString \
    --output text 2>/dev/null | jq -r 'keys[] | "  " + .' >&2 || log "  (no secret)"
}

# The collection travels inside the release: the instance needs neither Galaxy nor Internet, and
# Ansible finds collections/ next to the playbook without configuration. Its symlinks (docs,
# tests, licenses) become plain files, so the zip holds what they point to.
stage_collection() {
  local stage="$1" archive tmp
  archive="${ROOT_DIR}/build/cache/community-general-${COMMUNITY_GENERAL_VERSION}.tar.gz"
  mkdir -p "${archive%/*}"
  if ! printf '%s  %s\n' "$COMMUNITY_GENERAL_SHA256" "$archive" | sha256sum --check --status \
    2>/dev/null; then
    curl --fail --silent --show-error --location --retry 3 --output "$archive" \
      "${GALAXY}/community-general-${COMMUNITY_GENERAL_VERSION}.tar.gz"
    printf '%s  %s\n' "$COMMUNITY_GENERAL_SHA256" "$archive" | sha256sum --check --status \
      || die "${archive##*/}: the SHA-256 is not COMMUNITY_GENERAL_SHA256"
  fi
  tmp=$(mktemp -d)
  tar -xzf "$archive" -C "$tmp"
  mkdir -p "${stage}/collections/ansible_collections/community/general"
  cp -rL "${tmp}/." "${stage}/collections/ansible_collections/community/general/"
  rm -rf "$tmp"
}

# The contract: site.yml at the root, vars/ and collections/, zipped reproducibly.
release() {
  local version="$1" dry_run="$2" stage="${ROOT_DIR}/build/config/stage" zip status=0
  rm -rf "$stage"
  mkdir -p "$stage"
  cp "${ROOT_DIR}/ansible/site.yml" "${stage}/site.yml"
  cp -r "${ROOT_DIR}/ansible/vars" "${stage}/vars"
  stage_collection "$stage"
  zip="${ROOT_DIR}/build/config/wildfly-config-${version}.zip"
  build_zip "$stage" "$zip"
  log "${zip##*/} sha256 $(sha256_hex "$zip")"
  [ "$dry_run" = 0 ] || { printf '%s\n' "$zip"; return 0; }
  publish_release "$zip" \
    "config-releases/wildfly-config/${version}/wildfly-config-${version}.zip" || status=$?
  [ "$status" != 3 ] || die "configuration ${version} is already published: publish a new version"
  [ "$status" = 0 ] || exit "$status"
  log "nothing is applied yet: bin/config.sh apply ${version}"
}

main() {
  case "${1:-} $#" in
    "set 3") [[ "$2" =~ $NAME_PATTERN && ${#3} -le 4096 && "$3" != *$'\n'* ]] || usage ;;
    "unset 2") [[ "$2" =~ $NAME_PATTERN ]] || usage ;;
    "secret 2") [[ "$2" =~ $KEY_PATTERN ]] || usage ;;
    "show 1") ;;
    "release 2" | "release 3")
      [[ "$2" =~ $VERSION_PATTERN ]] && [[ "${3:-}" =~ ^(--dry-run)?$ ]] || usage ;;
    "apply 1" | "apply 2") [[ "${2:-}" =~ ^$|$VERSION_PATTERN ]] || usage ;;
    *) usage ;;
  esac
  if [ "${1:-} ${3:-}" = "release --dry-run" ]; then
    load_config --offline
  else
    load_config
  fi
  require_config COMMUNITY_GENERAL_VERSION COMMUNITY_GENERAL_SHA256

  case "$1" in
    set) set_parameter "$2" "$3" ;;
    unset) aws ssm delete-parameter --name "${CONFIG_PATH}/$2" && log "${CONFIG_PATH}/$2 deleted" ;;
    secret) set_secret "$2" ;;
    show) show ;;
    release) release "$2" "$([ "${3:-}" = --dry-run ] && echo 1 || echo 0)" ;;
    apply) start_runbook "$DOC_RELEASE" "ConfigVersion=${2:-}" Promote=true ;;
  esac
}

main "$@"
