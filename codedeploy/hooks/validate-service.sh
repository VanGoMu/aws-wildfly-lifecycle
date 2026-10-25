#!/usr/bin/env bash
# ValidateService: the shared validation, the same one the Validate document runs.
set -euo pipefail
exec /opt/wildfly-lifecycle/bin/validate.sh
