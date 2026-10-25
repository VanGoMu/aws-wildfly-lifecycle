#!/usr/bin/env bash
# AMI backups of a color: create, rotate, find the latest.

backup_filters() {
  printf '%s\n' \
    "Name=tag:Project,Values=${PROJECT}" \
    "Name=tag:Environment,Values=${ENV_NAME}" \
    "Name=tag:Component,Values=backup"
}

# create_backup INSTANCE COLOR: create-image WITH reboot, so the disk is consistent; WildFly and
# the agent come back on their own (systemd). The AMI and its snapshots get the same tags. The
# secrets live in /run (tmpfs), so no AMI ever contains them. Prints the AMI id.
create_backup() {
  local instance="$1" color="$2" release config tag_list image
  release=$(state_get "${color}/release" '{}' | jq -r '.version // "none"')
  config=$(state_get "${color}/config" '{}' | jq -r '.version // "none"')
  tag_list=$(tags backup "Color=${color}" "WildFlyVersion=${WILDFLY_VERSION}" \
    "Release=${release}" "ConfigVersion=${config}" \
    | jq -Rr 'capture("^(?<k>[^=]+)=(?<v>.*)$") | "{Key=\(.k),Value=\(.v)}"' | paste -sd,)
  log "creating an AMI of ${instance} (${color}); the instance reboots"
  image=$(aws ec2 create-image \
    --instance-id "$instance" \
    --name "${PREFIX}-${color}-$(date -u +%Y%m%dT%H%M%SZ)" \
    --description "${PROJECT} ${ENV_NAME} ${color}: release ${release}, config ${config}" \
    --tag-specifications "ResourceType=image,Tags=[${tag_list}]" \
    "ResourceType=snapshot,Tags=[${tag_list}]" \
    --query ImageId \
    --output text) || return 1
  retry 4 1 aws ec2 wait image-available --image-ids "$image" || return 1
  log "AMI ${image} available"
  printf '%s\n' "$image"
}

# rotate_backups KEEP: keeps the KEEP newest AMIs of the environment; deregisters the rest and
# deletes their snapshots (they would otherwise stay, and bill, after the AMI is gone).
rotate_backups() {
  local keep="$1" image
  local -a filters
  mapfile -t filters < <(backup_filters)
  for image in $(aws ec2 describe-images \
    --owners self \
    --filters "${filters[@]}" \
    --query 'sort_by(Images, &CreationDate)[].ImageId' \
    --output text | tr '\t' '\n' | head -n "-${keep}"); do
    aws ec2 deregister-image --image-id "$image" --delete-associated-snapshots >/dev/null
    log "deregistered ${image} and its snapshots"
  done
}

latest_backup() {
  local -a filters
  mapfile -t filters < <(backup_filters)
  aws ec2 describe-images \
    --owners self \
    --filters "${filters[@]}" \
    --query 'sort_by(Images, &CreationDate)[-1].ImageId' \
    --output text
}
