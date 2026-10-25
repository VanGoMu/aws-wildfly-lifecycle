#!/usr/bin/env bash
# Builds the WAR on its own: bin/artifact.sh build calls Maven the same way.
set -euo pipefail

main() {
  local version="${1:-1.0.0}" name="${2:-wildfly-demo}"
  cd "$(dirname "$0")"
  command -v mvn >/dev/null 2>&1 || { echo "missing command: mvn" >&2; exit 1; }
  mvn -q -DskipTests -Dapp.version="$version" -Dapp.name="$name" clean package
  printf '%s\n' "target/${name}.war"
}

main "$@"
