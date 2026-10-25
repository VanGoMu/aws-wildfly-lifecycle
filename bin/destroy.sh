#!/usr/bin/env bash
# Everything, in reverse order: the colors, the ALB, the AMI backups (unless --keep-amis), the
# state and configuration parameters, the secret and the foundation. Ends asking the tagging API
# what is still alive, and exits 1 if anything is.
# shellcheck source-path=SCRIPTDIR/..
set -euo pipefail

LIB="$(cd "$(dirname "$0")/../lib" && pwd)"
# shellcheck source=lib/common.sh
source "${LIB}/common.sh"
# shellcheck source=lib/cfn.sh
source "${LIB}/cfn.sh"
# shellcheck source=lib/ssm.sh
source "${LIB}/ssm.sh"
# shellcheck source=lib/ami.sh
source "${LIB}/ami.sh"

usage() {
  echo "usage: ${0##*/} [--keep-amis]   (FORCE=1 asks nothing)" >&2
  exit 2
}

# …/state/* and …/config/*; …/infra/alb went with the ALB stack.
delete_parameters() {
  local -a names
  mapfile -t names < <(for path in "$STATE_PATH" "$CONFIG_PATH"; do
    aws ssm get-parameters-by-path \
      --path "$path" \
      --recursive \
      --query 'Parameters[].Name' \
      --output json | jq -r '.[]'
  done)
  while [ "${#names[@]}" -gt 0 ]; do
    aws ssm delete-parameters --names "${names[@]:0:10}" >/dev/null
    names=("${names[@]:10}")
  done
  log "state and configuration parameters deleted"
}

delete_secret() {
  aws secretsmanager describe-secret --secret-id "$SECRET_ID" >/dev/null 2>&1 || return 0
  aws secretsmanager delete-secret \
    --secret-id "$SECRET_ID" \
    --force-delete-without-recovery >/dev/null
  log "secret ${SECRET_ID} deleted"
}

# The tagging API keeps listing for a while what is already gone: each type is asked to its own
# service, and only what really exists counts as alive.
gone() {
  case "$1" in
    *:instance/*)
      [[ "$(aws ec2 describe-instances --instance-ids "${1##*/}" \
        --query 'Reservations[0].Instances[0].State.Name' --output text 2>/dev/null)" \
        =~ ^(terminated|shutting-down|None|)$ ]] ;;
    *:image/*) [ -z "$(aws ec2 describe-images --image-ids "${1##*/}" \
      --query 'Images[].ImageId' --output text 2>/dev/null)" ] ;;
    *:snapshot/*) ! aws ec2 describe-snapshots --snapshot-ids "${1##*/}" >/dev/null 2>&1 ;;
    *:volume/*) ! aws ec2 describe-volumes --volume-ids "${1##*/}" >/dev/null 2>&1 ;;
    *:security-group/*) ! aws ec2 describe-security-groups --group-ids "${1##*/}" >/dev/null 2>&1 ;;
    *) return 1 ;;
  esac
}

leftovers() {
  local arn alive=0
  while read -r arn; do
    [ -n "$arn" ] || continue
    if gone "$arn"; then
      log "  gone, still listed for a while: ${arn}"
    else
      warn "  alive: ${arn}"
      alive=1
    fi
  done < <(aws resourcegroupstaggingapi get-resources \
    --tag-filters "Key=Project,Values=${PROJECT}" "Key=Environment,Values=${ENV_NAME}" \
    --output json | jq -r '.ResourceTagMappingList[].ResourceARN')
  log "not deletable right away: CloudWatch metrics, Automation and CodeDeploy history"
  return "$alive"
}

main() {
  local keep_amis=0
  case "${1:-} $#" in
    " 0") ;;
    "--keep-amis 1") keep_amis=1 ;;
    *) usage ;;
  esac
  load_config
  confirm "Destroy ${PREFIX} in ${AWS_REGION} (account ${ACCOUNT_ID})?"
  # Asked now, done in its place: the secret cannot be recovered.
  confirm "Also delete the secret ${SECRET_ID} without recovery?"
  export FORCE=1

  "${ROOT_DIR}/bin/instance.sh" down blue --force
  "${ROOT_DIR}/bin/instance.sh" down green --force
  "${ROOT_DIR}/bin/alb.sh" down
  if [ "$keep_amis" = 0 ]; then
    rotate_backups 0
  fi
  delete_parameters
  delete_secret
  "${ROOT_DIR}/bin/setup.sh" down
  leftovers || die "something is still alive; run ${0##*/} again or delete it by hand"
  log "${PREFIX} destroyed"
}

main "$@"
