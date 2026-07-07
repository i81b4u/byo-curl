#!/usr/bin/env bash
# Do not use set -e here: the suite should report every failed check in one run.
set -uo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET=local
DOCKER_IMAGE="${DOCKER_IMAGE:-byo-curl:latest}"
CURL_BIN="${CURL_BIN:-}"
CURL_CONFIG="${CURL_CONFIG:-}"
PREFIX_DIR="${PREFIX_DIR:-}"
CONTAINER_CURL_BIN="${CONTAINER_CURL_BIN:-/opt/byo-curl/bin/curl}"
CONTAINER_CURL_CONFIG="${CONTAINER_CURL_CONFIG:-/opt/byo-curl/bin/curl-config}"
CONTAINER_PREFIX_DIR="${CONTAINER_PREFIX_DIR:-/opt/byo-curl}"
TIMEOUT="${TIMEOUT:-20}"
SKIP_NETWORK="${SKIP_NETWORK:-0}"
SKIP_LDAP="${SKIP_LDAP:-0}"
CHECK_PINNED_VERSIONS="${CHECK_PINNED_VERSIONS:-1}"

HTTP1_URL="${HTTP1_URL:-https://example.com/}"
HTTP2_URL="${HTTP2_URL:-https://www.cloudflare.com/}"
HTTP3_URL="${HTTP3_URL:-https://www.cloudflare.com/}"
ECH_URL="${ECH_URL:-https://crypto.cloudflare.com/cdn-cgi/trace}"
DOH_URL="${DOH_URL:-https://cloudflare-dns.com/dns-query}"
GZIP_URL="${GZIP_URL:-https://nghttp2.org/httpbin/gzip}"
BROTLI_URL="${BROTLI_URL:-https://nghttp2.org/httpbin/brotli}"
HEADERS_URL="${HEADERS_URL:-https://nghttp2.org/httpbin/headers}"
LDAPS_URL="${LDAPS_URL:-ldaps://db.debian.org/uid=joey,ou=users,dc=debian,dc=org?cn}"

# Optional authenticated or environment-specific services. Set these to enable
# additional protocol checks.
FTP_TEST_URL="${FTP_TEST_URL:-}"
SFTP_TEST_URL="${SFTP_TEST_URL:-}"
SCP_TEST_URL="${SCP_TEST_URL:-}"
WS_TEST_URL="${WS_TEST_URL:-}"

pass_count=0
fail_count=0
skip_count=0

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT
TEST_TMPDIR="$tmpdir"

green=
red=
yellow=
reset=
if [[ -t 1 ]]; then
  green=$'\033[32m'
  red=$'\033[31m'
  yellow=$'\033[33m'
  reset=$'\033[0m'
fi

usage() {
  cat <<'EOF'
Usage:
  ./test-curl.sh [--local] [--curl-bin PATH] [--curl-config PATH] [--prefix PATH]
  ./test-curl.sh --docker [IMAGE]

Options:
  --local             Test the local build prefix. This is the default.
  --curl-bin PATH     Local curl binary to test.
  --curl-config PATH  Local curl-config binary to test.
  --prefix PATH       Local install prefix for linkage checks.
  --docker [IMAGE]    Test a Docker image. Defaults to byo-curl:latest.
  --help              Show this help text.

Useful environment variables:
  SKIP_NETWORK=1      Run only local metadata/linkage checks.
  SKIP_LDAP=1         Skip the public LDAPS query.
  TIMEOUT=20          Per-request timeout in seconds.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --local)
      TARGET=local
      shift
      ;;
    --curl-bin)
      if [[ $# -lt 2 ]]; then
        printf 'Missing value for --curl-bin\n' >&2
        exit 2
      fi
      CURL_BIN="$2"
      shift 2
      ;;
    --curl-config)
      if [[ $# -lt 2 ]]; then
        printf 'Missing value for --curl-config\n' >&2
        exit 2
      fi
      CURL_CONFIG="$2"
      shift 2
      ;;
    --prefix)
      if [[ $# -lt 2 ]]; then
        printf 'Missing value for --prefix\n' >&2
        exit 2
      fi
      PREFIX_DIR="$2"
      shift 2
      ;;
    --docker)
      TARGET=docker
      if [[ $# -gt 1 && "$2" != --* ]]; then
        DOCKER_IMAGE="$2"
        shift 2
      else
        shift
      fi
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      printf 'Unknown option: %s\n\n' "$1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if [[ "$TARGET" == "local" ]]; then
  CURL_BIN="${CURL_BIN:-$ROOT_DIR/curl-build/prefix/bin/curl}"
  CURL_CONFIG="${CURL_CONFIG:-$ROOT_DIR/curl-build/prefix/bin/curl-config}"
  PREFIX_DIR="${PREFIX_DIR:-$ROOT_DIR/curl-build/prefix}"
else
  CURL_BIN="${CURL_BIN:-$CONTAINER_CURL_BIN}"
  CURL_CONFIG="${CURL_CONFIG:-$CONTAINER_CURL_CONFIG}"
  PREFIX_DIR="${PREFIX_DIR:-$CONTAINER_PREFIX_DIR}"
  # Curl writes HSTS and Alt-Svc cache files inside the container. Mount the
  # host temp directory there so those checks can inspect the files afterward.
  TEST_TMPDIR=/tmp/byo-curl-tests
fi

pass() {
  printf '%sPASS%s %s\n' "$green" "$reset" "$1"
  pass_count=$((pass_count + 1))
}

fail() {
  printf '%sFAIL%s %s\n' "$red" "$reset" "$1"
  if [[ $# -gt 1 && -n "$2" ]]; then
    printf '     %s\n' "$2"
  fi
  fail_count=$((fail_count + 1))
}

skip() {
  printf '%sSKIP%s %s\n' "$yellow" "$reset" "$1"
  if [[ $# -gt 1 && -n "$2" ]]; then
    printf '     %s\n' "$2"
  fi
  skip_count=$((skip_count + 1))
}

require_file() {
  local name="$1"
  local path="$2"

  if [[ -x "$path" ]]; then
    pass "$name"
  else
    fail "$name" "missing executable: $path"
  fi
}

require_target_executable() {
  local name="$1"
  local path="$2"

  if [[ "$TARGET" == "docker" ]]; then
    if docker run --rm --entrypoint /bin/sh "$DOCKER_IMAGE" \
      -c 'test -x "$1"' sh "$path"; then
      pass "$name"
    else
      fail "$name" "missing executable in image: $path"
    fi
  else
    require_file "$name" "$path"
  fi
}

contains() {
  local text="$1"
  local needle="$2"
  [[ "$text" == *"$needle"* ]]
}

assert_contains() {
  local name="$1"
  local text="$2"
  local needle="$3"

  if contains "$text" "$needle"; then
    pass "$name"
  else
    fail "$name" "expected to find: $needle"
  fi
}

assert_not_contains() {
  local name="$1"
  local text="$2"
  local needle="$3"

  if contains "$text" "$needle"; then
    fail "$name" "unexpectedly found: $needle"
  else
    pass "$name"
  fi
}

curl_capture() {
  run_curl --silent --show-error --max-time "$TIMEOUT" "$@"
}

curl_status_version() {
  run_curl --silent --show-error --max-time "$TIMEOUT" \
    --output /dev/null --write-out '%{http_code} %{http_version}' "$@"
}

run_curl() {
  if [[ "$TARGET" == "docker" ]]; then
    docker run --rm --volume "$tmpdir:$TEST_TMPDIR" "$DOCKER_IMAGE" "$@"
  else
    "$CURL_BIN" "$@"
  fi
}

run_in_target() {
  local entrypoint="$1"
  shift

  if [[ "$TARGET" == "docker" ]]; then
    docker run --rm --entrypoint "$entrypoint" "$DOCKER_IMAGE" "$@"
  else
    "$entrypoint" "$@"
  fi
}

target_has_command() {
  local command_name="$1"

  if [[ "$TARGET" == "docker" ]]; then
    docker run --rm --entrypoint /bin/sh "$DOCKER_IMAGE" \
      -c 'command -v "$1" >/dev/null 2>&1' sh "$command_name"
  else
    command -v "$command_name" >/dev/null 2>&1
  fi
}

require_docker_image() {
  if ! command -v docker >/dev/null 2>&1; then
    fail "docker command exists" "docker is required for --docker mode"
    return 1
  fi

  if docker image inspect "$DOCKER_IMAGE" >/dev/null 2>&1; then
    pass "docker image exists"
    return 0
  fi

  fail "docker image exists" "missing image: $DOCKER_IMAGE"
  return 1
}

check_status_version() {
  local name="$1"
  local expected_version="$2"
  shift 2
  local output

  if output="$(curl_status_version "$@" 2>&1)"; then
    local code="${output%% *}"
    local version="${output#* }"
    if [[ "$code" =~ ^2[0-9][0-9]$ && "$version" == "$expected_version" ]]; then
      pass "$name"
    else
      fail "$name" "got HTTP $code over version $version"
    fi
  else
    fail "$name" "$output"
  fi
}

run_text_check() {
  local name="$1"
  local needle="$2"
  shift 2
  local output

  if output="$(curl_capture "$@" 2>&1)"; then
    if contains "$output" "$needle"; then
      pass "$name"
    else
      fail "$name" "response did not contain: $needle"
    fi
  else
    fail "$name" "$output"
  fi
}

run_optional_url_check() {
  local name="$1"
  local url="$2"
  shift 2

  if [[ -z "$url" ]]; then
    skip "$name" "set ${name}_URL or the documented protocol-specific variable to enable"
    return
  fi

  local output
  if output="$(curl_capture "$@" --output /dev/null "$url" 2>&1)"; then
    pass "$name"
  else
    fail "$name" "$output"
  fi
}

pin_default() {
  local name="$1"
  sed -n 's/^'"$name"'="${'"$name"':-\([^}]*\)}".*/\1/p' "$ROOT_DIR/build-curl.sh"
}

strip_v() {
  local value="$1"
  printf '%s\n' "${value#v}"
}

openldap_version() {
  local value="$1"
  value="${value#OPENLDAP_REL_ENG_}"
  printf '%s\n' "${value//_/.}"
}

check_pinned_versions() {
  local openssl nghttp2 nghttp3 ngtcp2 zlib brotli zstd libidn2 libpsl libssh openldap
  # Keep expected dependency versions in one place by reading the defaults from
  # build-curl.sh instead of duplicating them in this test script.
  openssl="$(pin_default OPENSSL_VERSION)"
  nghttp2="$(strip_v "$(pin_default NGHTTP2_VERSION)")"
  nghttp3="$(strip_v "$(pin_default NGHTTP3_VERSION)")"
  ngtcp2="$(strip_v "$(pin_default NGTCP2_VERSION)")"
  zlib="$(strip_v "$(pin_default ZLIB_VERSION)")"
  brotli="$(strip_v "$(pin_default BROTLI_VERSION)")"
  zstd="$(strip_v "$(pin_default ZSTD_VERSION)")"
  libidn2="$(strip_v "$(pin_default LIBIDN2_VERSION)")"
  libpsl="$(pin_default LIBPSL_VERSION)"
  libssh="$(pin_default LIBSSH_VERSION)"
  libssh="${libssh#libssh-}"
  openldap="$(openldap_version "$(pin_default OPENLDAP_VERSION)")"

  local missing=0
  for value in "$openssl" "$nghttp2" "$nghttp3" "$ngtcp2" "$zlib" \
               "$brotli" "$zstd" "$libidn2" "$libpsl" "$libssh" \
               "$openldap"; do
    if [[ -z "$value" ]]; then
      missing=1
    fi
  done

  if [[ "$missing" == "1" ]]; then
    skip "pinned dependency version checks" "could not read all defaults from build-curl.sh"
    return
  fi

  for needle in \
    "OpenSSL/$openssl" \
    "zlib/$zlib" \
    "brotli/$brotli" \
    "zstd/$zstd" \
    "libidn2/$libidn2" \
    "libpsl/$libpsl" \
    "libssh/$libssh" \
    "nghttp2/$nghttp2" \
    "ngtcp2/$ngtcp2" \
    "nghttp3/$nghttp3" \
    "OpenLDAP/$openldap"; do
    assert_contains "version reports $needle" "$version_output" "$needle"
  done
}

if [[ "$TARGET" == "docker" ]]; then
  printf 'Testing Docker image: %s\n' "$DOCKER_IMAGE"
  printf 'Container curl: %s\n\n' "$CURL_BIN"
  require_docker_image || {
    printf '\nCannot continue without a Docker image.\n' >&2
    exit 1
  }
else
  printf 'Testing curl binary: %s\n\n' "$CURL_BIN"
fi

require_target_executable "curl binary exists" "$CURL_BIN"
require_target_executable "curl-config exists" "$CURL_CONFIG"

if [[ "$TARGET" == "local" && ! -x "$CURL_BIN" ]]; then
  printf '\nCannot continue without a curl binary.\n' >&2
  exit 1
fi

version_output="$(run_curl --version 2>&1)"
config_features="$(run_in_target "$CURL_CONFIG" --features 2>/dev/null || true)"
config_protocols="$(run_in_target "$CURL_CONFIG" --protocols 2>/dev/null || true)"

printf '%s\n\n' "$version_output"

if [[ "$CHECK_PINNED_VERSIONS" == "1" ]]; then
  check_pinned_versions
else
  skip "pinned dependency version checks" "CHECK_PINNED_VERSIONS=0"
fi

assert_not_contains "version does not report libssh2" "$version_output" 'libssh2'

for feature in ECH HTTP2 HTTP3 HTTPSRR IDN PSL SSL brotli zstd; do
  assert_contains "feature $feature enabled" "$config_features"$'\n'"$version_output" "$feature"
done

for protocol in http https ldap ldaps scp sftp ws wss; do
  assert_contains "protocol $protocol enabled" "$config_protocols"$'\n'"$version_output" "$protocol"
done

if target_has_command ldd; then
  ldd_output="$(run_in_target ldd "$CURL_BIN" 2>&1)"
  assert_contains "ldd uses prefix libcurl" "$ldd_output" "$PREFIX_DIR/lib/libcurl.so"
  assert_contains "ldd uses prefix ngtcp2" "$ldd_output" "$PREFIX_DIR/lib/libngtcp2.so"
  assert_contains "ldd uses prefix nghttp3" "$ldd_output" "$PREFIX_DIR/lib/libnghttp3.so"
  assert_contains "ldd uses prefix libssh" "$ldd_output" "$PREFIX_DIR/lib/libssh.so"
  assert_not_contains "ldd does not use libssh2" "$ldd_output" 'libssh2'
else
  skip "ldd checks" "ldd is not available in target"
fi

if target_has_command readelf; then
  readelf_output="$(run_in_target readelf -d "$CURL_BIN" 2>&1)"
  assert_contains "curl has prefix RUNPATH" "$readelf_output" "$PREFIX_DIR/lib"
else
  skip "RUNPATH check" "readelf is not available in target"
fi

if [[ "$SKIP_NETWORK" == "1" ]]; then
  skip "network tests" "SKIP_NETWORK=1"
else
  check_status_version "HTTPS over HTTP/1.1" '1.1' --http1.1 "$HTTP1_URL"
  check_status_version "HTTPS over HTTP/2" '2' --http2 "$HTTP2_URL"
  check_status_version "HTTPS over HTTP/3" '3' --http3 --tlsv1.3 "$HTTP3_URL"

  run_text_check "gzip decompression" '"gzipped":true' --compressed "$GZIP_URL"
  run_text_check "Brotli decompression" '"brotli":true' --compressed "$BROTLI_URL"
  run_text_check "zstd advertised in Accept-Encoding" 'zstd' --compressed "$HEADERS_URL"

  ech_output="$(curl_capture --tlsv1.3 --ech hard --doh-url "$DOH_URL" "$ECH_URL" 2>&1)"
  ech_rc=$?
  if [[ $ech_rc -eq 0 ]]; then
    assert_contains "ECH encrypts SNI" "$ech_output" 'sni=encrypted'
    assert_contains "ECH endpoint used TLS 1.3" "$ech_output" 'tls=TLSv1.3'
  else
    fail "ECH request" "$ech_output"
  fi

  hsts_file="$TEST_TMPDIR/hsts.txt"
  hsts_host_file="$tmpdir/hsts.txt"
  if curl_capture --hsts "$hsts_file" --output /dev/null "$HTTP2_URL" >/dev/null 2>&1 &&
     [[ -s "$hsts_host_file" ]]; then
    pass "HSTS cache file populated"
  else
    fail "HSTS cache file populated" "no HSTS data written to $hsts_host_file"
  fi

  alt_svc_file="$TEST_TMPDIR/alt-svc.txt"
  alt_svc_host_file="$tmpdir/alt-svc.txt"
  if curl_capture --alt-svc "$alt_svc_file" --output /dev/null "$HTTP2_URL" >/dev/null 2>&1 &&
     grep -q 'h3' "$alt_svc_host_file"; then
    pass "Alt-Svc cache records HTTP/3"
  else
    fail "Alt-Svc cache records HTTP/3" "no h3 entry written to $alt_svc_host_file"
  fi

  if [[ "$SKIP_LDAP" == "1" ]]; then
    skip "LDAPS query" "SKIP_LDAP=1"
  else
    run_text_check "LDAPS query" 'DN: uid=joey,ou=users,dc=debian,dc=org' "$LDAPS_URL"
  fi

  run_optional_url_check "FTP_TEST" "$FTP_TEST_URL"
  run_optional_url_check "SFTP_TEST" "$SFTP_TEST_URL"
  run_optional_url_check "SCP_TEST" "$SCP_TEST_URL"
  run_optional_url_check "WS_TEST" "$WS_TEST_URL"
fi

printf '\nSummary: %d passed, %d failed, %d skipped\n' \
  "$pass_count" "$fail_count" "$skip_count"

if [[ "$fail_count" -gt 0 ]]; then
  exit 1
fi
