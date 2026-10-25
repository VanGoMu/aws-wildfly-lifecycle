#!/usr/bin/env bash
# CloudFormation: one stack per layer, always deployed with the standard tags.

stack_status() {
  aws cloudformation describe-stacks \
    --stack-name "$1" \
    --query 'Stacks[0].StackStatus' \
    --output text 2>/dev/null || echo NONE
}

# stack_output STACK KEY: the value, or nothing when the stack or the output does not exist.
stack_output() {
  local value
  value=$(aws cloudformation describe-stacks \
    --stack-name "$1" \
    --query "Stacks[0].Outputs[?OutputKey=='$2'].OutputValue | [0]" \
    --output text 2>/dev/null) || value=""
  [ "$value" = None ] || printf '%s' "$value"
}

# The reason is not always in a *_FAILED event: a rollback can carry it in the stack's own
# ROLLBACK_IN_PROGRESS event.
stack_failure() {
  aws cloudformation describe-stack-events \
    --stack-name "$1" \
    --max-items 40 \
    --query "StackEvents[?contains(ResourceStatus, 'FAILED') \
      || ResourceStatus == 'ROLLBACK_IN_PROGRESS'].[LogicalResourceId, ResourceStatusReason]" \
    --output text 2>/dev/null | head -n 5 || true
}

# deploy_stack STACK TEMPLATE COMPONENT [Key=Value…]: create or update; an empty change set is a
# success. A failed creation leaves ROLLBACK_COMPLETE, which can only be deleted: it goes first.
# Parameters left out keep their current value.
deploy_stack() {
  local stack="$1" template="$2" component="$3"
  local -a tag_args
  shift 3
  mapfile -t tag_args < <(tags "$component")
  if [ "$(stack_status "$stack")" = ROLLBACK_COMPLETE ]; then
    delete_stack "$stack"
  fi

  log "deploying ${stack}"
  aws cloudformation deploy \
    --stack-name "$stack" \
    --template-file "${ROOT_DIR}/templates/${template}" \
    --capabilities CAPABILITY_NAMED_IAM \
    --no-fail-on-empty-changeset \
    --parameter-overrides "$@" \
    --tags "${tag_args[@]}" \
    && return 0
  warn "${stack}: $(stack_failure "$stack")"
  return 1
}

delete_stack() {
  [ "$(stack_status "$1")" != NONE ] || return 0
  log "deleting ${1}"
  aws cloudformation delete-stack --stack-name "$1"
  aws cloudformation wait stack-delete-complete --stack-name "$1" \
    || die "${1} was not deleted: $(stack_failure "$1")"
}
