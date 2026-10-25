#!/usr/bin/env bash
# AfterInstall: deploys every WAR of the revision and undeploys the ones that are gone.
set -euo pipefail
exec /opt/wildfly-lifecycle/bin/deploy-wars.sh
