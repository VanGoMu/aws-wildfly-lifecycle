#!/usr/bin/env bash
# SSM Automation: start a runbook and follow it to the end.

# The longest legitimate run: WaitDeploy (3,600 s) plus the canary window (up to 62 min).
RUNBOOK_WAIT_SECONDS=9000

execution_field() {
  aws ssm get-automation-execution \
    --automation-execution-id "$1" \
    --query "AutomationExecution.$2" \
    --output text
}

# start_runbook RUNBOOK [Name=value…]: start an execution, print every step as it begins, and a
# summary at the end. On failure it prints each failed step with its FailureMessage and returns 1.
start_runbook() {
  local runbook="$1" execution status step="" previous="" waited current
  shift
  execution=$(aws ssm start-automation-execution \
    --document-name "$runbook" \
    --parameters "$(parameters_json "$@")" \
    --query AutomationExecutionId \
    --output text) || return 1
  log "${runbook}: execution ${execution}"

  for ((waited = 0; waited < RUNBOOK_WAIT_SECONDS; waited += 15)); do
    current=$(execution_field "$execution" '[AutomationExecutionStatus, CurrentStepName]') \
      || return 1
    read -r status step <<<"$current"
    if [ "$step" != "$previous" ] && [ "$step" != None ]; then
      log "  step ${step}"
      previous="$step"
    fi
    case "$status" in
      Success | CompletedWithSuccess)
        execution_field "$execution" Outputs | sed 's/^/  /' >&2
        return 0 ;;
      Failed | TimedOut | Cancelled | Rejected | CompletedWithFailure | Exited)
        warn "${runbook}: ${status}"
        execution_field "$execution" "StepExecutions[?StepStatus=='Failed' \
          || StepStatus=='TimedOut'].[StepName, FailureMessage]" | sed 's/^/  /' >&2
        return 1 ;;
    esac
    sleep 15
  done
  warn "${runbook}: still running after ${RUNBOOK_WAIT_SECONDS} s; see ${execution} in the console"
  return 1
}
