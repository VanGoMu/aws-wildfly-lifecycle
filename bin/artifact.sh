#!/usr/bin/env bash
# 2 · The application release. build: the CodeDeploy revision of the contract (appspec.yml,
# hooks/, wars/), made reproducibly, from app/ or from the WARs given. publish: write-once to S3,
# which deploys it (EventBridge starts Release). mirror-wildfly: the WildFly tarball, verified,
# under vendor/, so installs do not depend on GitHub.
# shellcheck source-path=SCRIPTDIR/..
set -euo pipefail

LIB="$(cd "$(dirname "$0")/../lib" && pwd)"
# shellcheck source=lib/common.sh
source "${LIB}/common.sh"
# shellcheck source=lib/release.sh
source "${LIB}/release.sh"

usage() {
  echo "usage: ${0##*/} build <version> [war…] | publish <zip> | mirror-wildfly" >&2
  exit 2
}

# The argument frontier: a version, and WAR files with distinct names of the contract.
check_build_args() {
  local war
  local -A seen=()
  [[ "${1:-}" =~ $VERSION_PATTERN ]] || usage
  shift
  for war in "$@"; do
    [ -f "$war" ] || die "no such file: ${war}"
    [[ "${war##*/}" =~ $WAR_PATTERN ]] || die "${war##*/} is not a WAR name of the contract"
    [ -z "${seen[${war##*/}]:-}" ] || die "${war##*/} is given twice"
    seen[${war##*/}]=1
  done
}

# Without WARs, the demo of app/. Prints the path of the zip on stdout; the rest goes to stderr.
build() {
  local version="$1" stage="${ROOT_DIR}/build/revision" zip
  shift
  local -a wars=("$@")
  if [ "${#wars[@]}" -eq 0 ]; then
    require_cmd mvn
    log "mvn package ${version}"
    mvn -q -f "${ROOT_DIR}/app/pom.xml" -DskipTests -Dapp.version="$version" clean package >&2
    wars=("${ROOT_DIR}/app/target/wildfly-demo.war")
  fi

  rm -rf "$stage"
  mkdir -p "${stage}/wars"
  cp "${ROOT_DIR}/codedeploy/appspec.yml" "${stage}/appspec.yml"
  cp -r "${ROOT_DIR}/codedeploy/hooks" "${stage}/hooks"
  cp "${wars[@]}" "${stage}/wars/"
  zip="${ROOT_DIR}/build/${APP_NAME}-${version}.zip"
  build_zip "$stage" "$zip"
  log "${zip##*/}: ${#wars[@]} WAR, sha256 $(sha256_hex "$zip")"
  printf '%s\n' "$zip"
}

publish() {
  local zip="$1" name version version_id status=0
  name="${zip##*/}"
  version="${name#"${APP_NAME}-"}"
  version="${version%.zip}"
  [ "$name" = "${APP_NAME}-${version}.zip" ] && [[ "$version" =~ $VERSION_PATTERN ]] \
    || die "${zip} is not a ${APP_NAME}-<version>.zip built by ${0##*/} build"
  version_id=$(publish_release "$zip" "releases/${APP_NAME}/${version}/${name}") || status=$?
  [ "$status" != 3 ] || die "${APP_NAME} ${version} is already published: publish a new version"
  [ "$status" = 0 ] || exit "$status"
  log "VersionId ${version_id}"
  log "publishing is deploying: EventBridge starts ${DOC_RELEASE}; follow it with bin/app.sh status"
}

mirror_wildfly() {
  local version="$WILDFLY_VERSION" key tarball
  key="vendor/wildfly/${version}/wildfly-${version}.tar.gz"
  tarball="${ROOT_DIR}/build/wildfly-${version}.tar.gz"
  if aws s3api head-object --bucket "$BUCKET" --key "$key" >/dev/null 2>&1; then
    log "s3://${BUCKET}/${key} already exists"
    return 0
  fi

  mkdir -p "${ROOT_DIR}/build"
  curl --fail --silent --show-error --location --retry 3 --output "$tarball" \
    "https://github.com/wildfly/wildfly/releases/download/${version}/wildfly-${version}.tar.gz"
  printf '%s  %s\n' "$WILDFLY_SHA256" "$tarball" | sha256sum --check --status \
    || die "${tarball}: the SHA-256 is not WILDFLY_SHA256"
  aws s3api put-object \
    --bucket "$BUCKET" \
    --key "$key" \
    --body "$tarball" \
    --checksum-sha256 "$(hex_to_base64 "$WILDFLY_SHA256")" \
    --if-none-match '*' >/dev/null
  log "mirrored to s3://${BUCKET}/${key}"
}

main() {
  case "${1:-}" in
    build)
      shift
      check_build_args "$@"
      load_config --offline
      require_cmd zip
      build "$@" ;;
    publish)
      [ "$#" = 2 ] && [ -f "$2" ] || usage
      load_config
      publish "$2" ;;
    mirror-wildfly)
      [ "$#" = 1 ] || usage
      load_config
      mirror_wildfly ;;
    *) usage ;;
  esac
}

main "$@"
