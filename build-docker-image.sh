#!/usr/bin/env bash
set -Eeuo pipefail

# IMAGE_NAME controls the repository/name used for the generated image. CURL_BIN
# points at the already-built curl binary whose version becomes the image tag.
IMAGE_NAME="${IMAGE_NAME:-byo-curl}"
CURL_BIN="${CURL_BIN:-curl-build/prefix/bin/curl}"

# The Docker image packages the local prefix; it does not rebuild curl. Make
# sure ./build-curl.sh completed before sending the build context to Docker.
if [[ ! -x "$CURL_BIN" ]]; then
  printf 'Missing built curl binary: %s\nRun ./build-curl.sh first.\n' "$CURL_BIN" >&2
  exit 1
fi

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    printf 'Missing required command: %s\n' "$1" >&2
    exit 1
  }
}

need_cmd docker

# Use curl's version token as a stable Docker tag, for example
# byo-curl:8.22.0-i81b4u, and also refresh byo-curl:latest.
version="$("$CURL_BIN" --version | sed -n '1s/^curl \([^ ]*\).*/\1/p')"
if [[ -z "$version" ]]; then
  printf 'Could not determine curl version from %s\n' "$CURL_BIN" >&2
  exit 1
fi

docker build -t "$IMAGE_NAME:$version" -t "$IMAGE_NAME:latest" .

printf '\nBuilt Docker image:\n'
printf '  %s:%s\n' "$IMAGE_NAME" "$version"
printf '  %s:latest\n' "$IMAGE_NAME"
