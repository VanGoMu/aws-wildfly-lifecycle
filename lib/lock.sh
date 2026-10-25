#!/usr/bin/env bash
# The lock: …/state/lock, the same parameter the Lock and Unlock steps of the Release runbook
# use. It is created without --overwrite, so only one release or switch changes the environment
# at a time; EventBridge delivers at least once and two releases can arrive almost together.

LOCK_OWNER=""

lock_acquire() {
  local output
  LOCK_OWNER="local:${USER:-unknown}@$(hostname -s):$$"
  if ! output=$(aws ssm put-parameter \
    --name "${STATE_PATH}/lock" \
    --type String \
    --value "$LOCK_OWNER" 2>&1); then
    [[ "$output" == *ParameterAlreadyExists* ]] || die "$output"
    die "the environment is locked by $(state_get lock); if it is orphaned: bin/app.sh unlock"
  fi
  trap lock_release EXIT
}

# Deletes the lock only if it is still ours.
lock_release() {
  [ -n "$LOCK_OWNER" ] && [ "$(state_get lock)" = "$LOCK_OWNER" ] || return 0
  aws ssm delete-parameter --name "${STATE_PATH}/lock"
  LOCK_OWNER=""
}
