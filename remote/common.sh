#!/usr/bin/env bash
# Shared by the platform scripts, installed in /opt/wildfly-lifecycle/bin/ from platform.zip.

# shellcheck disable=SC2034  # constants for the scripts that source this file
WILDFLY_HOME=/opt/wildfly
LIFECYCLE_DIR=/opt/wildfly-lifecycle
WARS_DIR="${LIFECYCLE_DIR}/release/wars"
# shellcheck disable=SC2034
RELEASE_ENV="${LIFECYCLE_DIR}/release/release.env"
INSTANCE_ENV=/etc/wildfly-lifecycle/instance.env

log() { printf '[%s] %s\n' "${0##*/}" "$*"; }
die() { printf '[%s] ERROR: %s\n' "${0##*/}" "$*" >&2; exit 1; }

# What install-wildfly.sh wrote and is not secret: region, environment, paths, versions.
load_instance_env() {
  # shellcheck source=/dev/null
  source "$INSTANCE_ENV"
}

# jboss_cli ARGS…: as wildfly, the owner of the server files, with the local authentication of
# jboss-cli (no password: it reads a token under standalone/tmp/auth).
jboss_cli() { runuser -u wildfly -- "${WILDFLY_HOME}/bin/jboss-cli.sh" --connect "$@"; }

# cli_json COMMAND: the result as one JSON line, or nothing while the server cannot answer (then
# jboss-cli prints text, not JSON).
cli_json() { jboss_cli --output-json --command="$1" 2>/dev/null | jq -c . 2>/dev/null || true; }

wait_running() {
  local n
  for ((n = 0; n < 60; n++)); do
    cli_json ':read-attribute(name=server-state)' | jq -e '.result == "running"' >/dev/null \
      && return 0
    sleep 2
  done
  return 1
}

# fetch URI DEST: s3://bucket/key[?versionId=…] with the instance role, https://, or file://
# (the test container).
fetch() {
  local uri="$1" dest="$2" path
  local -a version=()
  case "$uri" in
    s3://*)
      path="${uri#s3://}"
      if [[ "$path" == *'?versionId='* ]]; then
        version=(--version-id "${path#*\?versionId=}")
        path="${path%%\?*}"
      fi
      aws s3api get-object \
        --region "$REGION" \
        --bucket "${path%%/*}" \
        --key "${path#*/}" \
        "${version[@]}" \
        "$dest" >/dev/null ;;
    https://*) curl --fail --silent --show-error --location --retry 3 --output "$dest" "$uri" ;;
    file://*) cp "${uri#file://}" "$dest" ;;
    *) die "unsupported source: ${uri}" ;;
  esac
}
