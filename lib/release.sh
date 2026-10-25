#!/usr/bin/env bash
# The release artifacts (the contract in README.md) and platform.zip are built and published the
# same way.

# build_zip SOURCE_DIR ZIP: reproducible. Sorted entries, a fixed date (zip stores local time:
# hence TZ=UTC), normalized modes (755 for scripts), no directory entries, no extra attributes.
build_zip() {
  local source="$1" zip="$2"
  rm -f "$zip"
  (
    cd "$source" || exit 1
    find . -type f -perm -u+x -exec chmod 0755 {} +
    find . -type f ! -perm -u+x -exec chmod 0644 {} +
    find . -exec touch -h -d '2000-01-01T00:00:00Z' {} +
    find . -type f | LC_ALL=C sort | TZ=UTC zip -X -D -q "$zip" -@
  )
}

sha256_hex() { sha256sum "$1" | cut -d' ' -f1; }

# S3 takes the checksum in base64; the tags carry it in hex.
hex_to_base64() { printf '%b' "$(sed 's/../\\x&/g' <<<"$1")" | base64; }

# GitHub Actions sets GITHUB_SHA; on a laptop, the checked-out commit.
git_sha() {
  [ -z "${GITHUB_SHA:-}" ] || { printf '%s' "$GITHUB_SHA"; return 0; }
  git -C "$ROOT_DIR" rev-parse --verify --quiet HEAD || echo unknown
}

# build_platform: remote/ without its installer, as build/platform/platform.zip. Its key is the
# hash of its content, so publishing the same scripts twice is a no-op.
build_platform() {
  local stage="${ROOT_DIR}/build/platform/stage"
  rm -rf "$stage"
  mkdir -p "$stage"
  find "${ROOT_DIR}/remote" -maxdepth 1 -name '*.sh' ! -name install-wildfly.sh \
    -exec cp {} "$stage/" \;
  build_zip "$stage" "${ROOT_DIR}/build/platform/platform.zip"
  PLATFORM_SHA256=$(sha256_hex "${ROOT_DIR}/build/platform/platform.zip")
  PLATFORM_KEY="platform/${PLATFORM_SHA256}/platform.zip"
  export PLATFORM_SHA256 PLATFORM_KEY
}

# publish_release ZIP KEY: a single put-object with the checksum S3 recomputes (s3 cp would go
# multipart and leave a composite checksum), write-once (--if-none-match, which the bucket policy
# requires there) and with the tags the runbook checks. The version is the folder of the key.
# Prints the VersionId; returns 3 when the key already exists (412), for the caller to decide.
publish_release() {
  local zip="$1" key="$2" hex version output
  hex=$(sha256_hex "$zip")
  version="${key%/*}"
  version="${version##*/}"
  log "publishing s3://${BUCKET}/${key} (sha256 ${hex})"
  if ! output=$(aws s3api put-object \
    --bucket "$BUCKET" \
    --key "$key" \
    --body "$zip" \
    --checksum-sha256 "$(hex_to_base64 "$hex")" \
    --if-none-match '*' \
    --tagging "Version=${version}&Sha256=${hex}&GitSha=$(git_sha)" \
    --metadata "version=${version},sha256=${hex}" \
    --query VersionId \
    --output text 2>&1); then
    [[ "$output" != *PreconditionFailed* ]] || return 3
    die "upload failed: ${output}"
  fi
  printf '%s\n' "$output"
}
