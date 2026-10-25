#!/usr/bin/env bash
# BeforeInstall: empties release/wars (see deploy-wars.sh). The logic lives on the instance.
set -euo pipefail
exec /opt/wildfly-lifecycle/bin/deploy-wars.sh --clean
