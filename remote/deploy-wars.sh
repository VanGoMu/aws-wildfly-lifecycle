#!/usr/bin/env bash
# CodeDeploy hooks. --clean (BeforeInstall) empties release/wars: the files section only adds and
# overwrites, so without it a WAR dropped from the revision would stay. Without arguments
# (AfterInstall) it deploys every WAR there and undeploys the deployments no longer in the set.
set -euo pipefail

# shellcheck source=remote/common.sh
source "$(dirname "$0")/common.sh"

# CodeDeploy's own cleanup is not enough: the agent removes only what the same deployment group
# installed, and an instance born from the AMI of the other color brings WARs it does not know.
clean() {
  install -d -m 0755 "$WARS_DIR"
  find "$WARS_DIR" -mindepth 1 -delete
  log "release/wars emptied"
}

# Through jboss-cli, never by copying into deployments/: the deployment scanner would be a second
# owner of <deployments>. deploy --force is synchronous, and jboss-cli fails on a failed outcome.
deploy_all() {
  local war
  for war in "$WARS_DIR"/*.war; do
    jboss_cli --command="deploy ${war} --force"
    log "deployed ${war##*/}"
  done
}

undeploy_stale() {
  local name
  for name in $(cli_json ':read-children-names(child-type=deployment)' | jq -r '.result[]'); do
    [ -f "${WARS_DIR}/${name}" ] && continue
    jboss_cli --command="undeploy ${name}"
    log "undeployed ${name}"
  done
}

# The variables CodeDeploy gives the hooks of an S3 bundle: what is deployed, for validate.sh.
write_release_env() {
  printf '%s\n' \
    "BUNDLE_KEY=${BUNDLE_KEY:-}" \
    "BUNDLE_VERSION=${BUNDLE_VERSION:-}" \
    "BUNDLE_ETAG=${BUNDLE_ETAG:-}" \
    "DEPLOYMENT_ID=${DEPLOYMENT_ID:-}" > "$RELEASE_ENV"
}

main() {
  if [ "${1:-}" = --clean ]; then
    clean
    return 0
  fi
  compgen -G "${WARS_DIR}/*.war" >/dev/null || die "the revision has no WAR in wars/"
  wait_running || die "WildFly is not running: journalctl -u wildfly"
  deploy_all
  undeploy_stale
  write_release_env
}

main "$@"
