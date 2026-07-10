#!/usr/bin/env bash
# Do not use set -e here: the suite should report every failed check in one run.
set -uo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# The suite can test either the default local build prefix or explicit paths
# supplied by CI, Docker, or a developer comparing another curl binary.
CURL_BIN="${CURL_BIN:-}"
CURL_CONFIG="${CURL_CONFIG:-}"
PREFIX_DIR="${PREFIX_DIR:-}"
TIMEOUT="${TIMEOUT:-20}"
SKIP_NETWORK="${SKIP_NETWORK:-0}"
SKIP_LDAP="${SKIP_LDAP:-0}"
CHECK_PINNED_VERSIONS="${CHECK_PINNED_VERSIONS:-1}"
# Maximum number of independent network-check groups in flight. Set to 1 for
# serial diagnostics; the default balances runtime against public endpoint use.
NETWORK_JOBS="${NETWORK_JOBS:-4}"

# Public endpoints used by the network checks. They are intentionally
# configurable because protocol test services sometimes move or rate-limit.
HTTP1_URL="${HTTP1_URL:-https://example.com/}"
HTTP2_URL="${HTTP2_URL:-https://www.cloudflare.com/}"
HTTP3_URL="${HTTP3_URL:-https://www.cloudflare.com/}"
ECH_URL="${ECH_URL:-https://crypto.cloudflare.com/cdn-cgi/trace}"
DOH_URL="${DOH_URL:-https://cloudflare-dns.com/dns-query}"
CARES_DNS_SERVER="${CARES_DNS_SERVER:-1.1.1.1}"
CARES_DNS_URL="${CARES_DNS_URL:-https://example.com/}"
COMPRESSION_URL="${COMPRESSION_URL:-https://www.cloudflare.com/}"
LDAPS_URL="${LDAPS_URL:-ldaps://db.debian.org/uid=joey,ou=users,dc=debian,dc=org?cn}"

# Optional protocol endpoints. Emptying one of these variables skips that
# protocol-specific check without disabling all network tests.
FTP_TEST_URL="${FTP_TEST_URL:-ftp://demo:password@test.rebex.net/}"
SFTP_TEST_URL="${SFTP_TEST_URL:-sftp://demo:password@test.rebex.net/}"
SCP_TEST_URL="${SCP_TEST_URL:-scp://demo:password@test.rebex.net/readme.txt}"
WS_TEST_URL="${WS_TEST_URL:-wss://echo.websocket.org/}"

pass_count=0
fail_count=0
skip_count=0

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT
TEST_TMPDIR="$tmpdir"

# Keep output readable in terminals while leaving logs plain in non-TTY runs.
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

Options:
  --local             Test the local build prefix. This is the default.
  --curl-bin PATH     Local curl binary to test.
  --curl-config PATH  Local curl-config binary to test.
  --prefix PATH       Local install prefix for linkage checks.
  --help              Show this help text.

Useful environment variables:
  SKIP_NETWORK=1      Run only local metadata/linkage checks.
  SKIP_LDAP=1         Skip the public LDAPS query.
  TIMEOUT=20          Per-request timeout in seconds.
  CARES_DNS_SERVER=1.1.1.1
                      DNS server used by the c-ares runtime check.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --local)
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

CURL_BIN="${CURL_BIN:-$ROOT_DIR/curl-build/prefix/bin/curl}"
CURL_CONFIG="${CURL_CONFIG:-$ROOT_DIR/curl-build/prefix/bin/curl-config}"
PREFIX_DIR="${PREFIX_DIR:-$ROOT_DIR/curl-build/prefix}"

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

  require_file "$name" "$path"
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
  "$CURL_BIN" "$@"
}

run_in_target() {
  local entrypoint="$1"
  shift

  "$entrypoint" "$@"
}

target_has_command() {
  local command_name="$1"

  command -v "$command_name" >/dev/null 2>&1
}

check_status_version() {
  # Fetch a URL and assert both a successful status code and the negotiated HTTP
  # version. This catches regressions where a protocol is compiled in but not
  # actually usable against a real endpoint.
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
  # Use for checks where curl's response body or trace output should contain a
  # small stable marker.
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
  # Protocol checks such as FTP/SFTP/SCP are useful but endpoint-dependent. A
  # caller can set the URL to an empty string to skip a single protocol.
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

run_header_check() {
  # Header-based checks are used for content negotiation so the body does not
  # need to be downloaded or parsed.
  local name="$1"
  local needle="$2"
  shift 2
  local headers_file="$tmpdir/${name//[^A-Za-z0-9_]/_}.headers"
  local output

  if output="$(curl_capture --dump-header "$headers_file" --output /dev/null "$@" 2>&1)"; then
    if grep -qi "$needle" "$headers_file"; then
      pass "$name"
    else
      fail "$name" "response headers did not contain: $needle"
    fi
  else
    fail "$name" "$output"
  fi
}

run_ws_check() {
  # The public websocket endpoint keeps the connection open long enough for curl
  # to hit the timeout after receiving a server banner. Treat that as success.
  local name="$1"
  local url="$2"
  local output rc

  output="$(run_curl --silent --show-error --max-time 5 "$url" 2>&1)"
  rc=$?
  if [[ $rc -eq 0 ]]; then
    pass "$name"
  elif [[ $rc -eq 28 && "$output" == *"Request served by"* ]]; then
    pass "$name"
  else
    fail "$name" "$output"
  fi
}

run_parallel_check() {
  local name="$1"
  shift
  # Wait for the current batch before starting another so NETWORK_JOBS is a
  # strict upper bound without losing the output needed for the final summary.
  if (( ${#parallel_pids[@]} >= NETWORK_JOBS )); then
    collect_parallel_checks
    parallel_pids=()
    parallel_logs=()
  fi
  # Child output is collected from a file, so keep it free of terminal escape
  # sequences. The collector uses the PASS/FAIL/SKIP prefix to update totals.
  (
    green=
    red=
    yellow=
    reset=
    "$@"
  ) >"$tmpdir/$name.log" 2>&1 &
  parallel_pids+=("$!")
  parallel_logs+=("$tmpdir/$name.log")
}

collect_parallel_checks() {
  local pid log line
  # Functions run in background subshells, so their counter updates do not
  # reach this shell. Rebuild those totals from their plain-text result logs.
  for pid in "${parallel_pids[@]}"; do
    wait "$pid" || true
  done
  for log in "${parallel_logs[@]}"; do
    while IFS= read -r line || [[ -n "$line" ]]; do
      case "$line" in
        PASS\ *)
          printf '%sPASS%s%s\n' "$green" "$reset" "${line#PASS}"
          pass_count=$((pass_count + 1))
          ;;
        FAIL\ *)
          printf '%sFAIL%s%s\n' "$red" "$reset" "${line#FAIL}"
          fail_count=$((fail_count + 1))
          ;;
        SKIP\ *)
          printf '%sSKIP%s%s\n' "$yellow" "$reset" "${line#SKIP}"
          skip_count=$((skip_count + 1))
          ;;
        *) printf '%s\n' "$line" ;;
      esac
    done <"$log"
  done
}

network_http_checks() {
  check_status_version "HTTPS over HTTP/1.1" '1.1' --http1.1 "$HTTP1_URL"
  check_status_version "HTTPS over HTTP/2" '2' --http2 "$HTTP2_URL"
  check_status_version "HTTPS over HTTP/3" '3' --http3 --tlsv1.3 "$HTTP3_URL"
  check_status_version "c-ares DNS server override" '1.1' \
    --http1.1 --dns-servers "$CARES_DNS_SERVER" "$CARES_DNS_URL"
}

network_compression_checks() {
  run_header_check "gzip negotiation" '^content-encoding: gzip' \
    --compressed --header 'Accept-Encoding: gzip' "$COMPRESSION_URL"
  run_header_check "Brotli negotiation" '^content-encoding: br' \
    --compressed --header 'Accept-Encoding: br' "$COMPRESSION_URL"
  run_text_check "zstd advertised in Accept-Encoding" 'Accept-Encoding: deflate, gzip, br, zstd' \
    --trace-ascii - --compressed --output /dev/null "$COMPRESSION_URL"
}

network_ech_check() {
  local ech_output ech_rc
  ech_output="$(curl_capture --tlsv1.3 --ech hard --doh-url "$DOH_URL" "$ECH_URL" 2>&1)"
  ech_rc=$?
  if [[ $ech_rc -eq 0 ]]; then
    assert_contains "ECH encrypts SNI" "$ech_output" 'sni=encrypted'
    assert_contains "ECH endpoint used TLS 1.3" "$ech_output" 'tls=TLSv1.3'
  else
    fail "ECH request" "$ech_output"
  fi
}

network_cache_checks() {
  local hsts_file alt_svc_file
  hsts_file="$TEST_TMPDIR/hsts.txt"
  if curl_capture --hsts "$hsts_file" --output /dev/null "$HTTP2_URL" >/dev/null 2>&1 && [[ -s "$hsts_file" ]]; then
    pass "HSTS cache file populated"
  else
    fail "HSTS cache file populated" "no HSTS data written to $hsts_file"
  fi

  alt_svc_file="$TEST_TMPDIR/alt-svc.txt"
  if curl_capture --alt-svc "$alt_svc_file" --output /dev/null "$HTTP2_URL" >/dev/null 2>&1 && grep -q 'h3' "$alt_svc_file"; then
    pass "Alt-Svc cache records HTTP/3"
  else
    fail "Alt-Svc cache records HTTP/3" "no h3 entry written to $alt_svc_file"
  fi
}

network_optional_checks() {
  if [[ "$SKIP_LDAP" == "1" ]]; then
    skip "LDAPS query" "SKIP_LDAP=1"
  else
    run_text_check "LDAPS query" 'DN: uid=joey,ou=users,dc=debian,dc=org' "$LDAPS_URL"
  fi
  run_optional_url_check "FTP_TEST" "$FTP_TEST_URL"
  run_optional_url_check "SFTP_TEST" "$SFTP_TEST_URL" --insecure
  run_optional_url_check "SCP_TEST" "$SCP_TEST_URL" --insecure
  run_ws_check "WS_TEST" "$WS_TEST_URL"
}

skip_network_checks() {
  # Keep local-only output aligned with the full suite: every assertion that
  # would make a public request gets its own explicit skipped result.
  local name
  for name in \
    "HTTPS over HTTP/1.1" \
    "HTTPS over HTTP/2" \
    "HTTPS over HTTP/3" \
    "c-ares DNS server override" \
    "gzip negotiation" \
    "Brotli negotiation" \
    "zstd advertised in Accept-Encoding" \
    "ECH encrypts SNI" \
    "ECH endpoint used TLS 1.3" \
    "HSTS cache file populated" \
    "Alt-Svc cache records HTTP/3" \
    "LDAPS query" \
    "FTP_TEST" \
    "SFTP_TEST" \
    "SCP_TEST" \
    "WS_TEST"; do
    skip "$name"
  done
}

pin_default() {
  # Read version defaults directly from build-curl.sh so the test expectations
  # stay aligned with the build script.
  local name="$1"
  sed -n 's/^'"$name"'="${'"$name"':-\([^}]*\)}".*/\1/p' "$ROOT_DIR/build-curl.sh"
}

strip_v() {
  local value="$1"
  printf '%s\n' "${value#v}"
}

openssl_runtime_version() {
  # OpenSSL's Git tag is openssl-X.Y.Z, but curl reports OpenSSL/X.Y.Z.
  local value="$1"
  printf '%s\n' "${value#openssl-}"
}

openldap_version() {
  local value="$1"
  value="${value#OPENLDAP_REL_ENG_}"
  printf '%s\n' "${value//_/.}"
}

check_pinned_versions() {
  local openssl nghttp2 nghttp3 ngtcp2 zlib cares brotli zstd libidn2 libpsl libssh openldap krb5
  # Keep expected dependency versions in one place by reading the defaults from
  # build-curl.sh instead of duplicating them in this test script.
  openssl="$(openssl_runtime_version "$(pin_default OPENSSL_VERSION)")"
  nghttp2="$(strip_v "$(pin_default NGHTTP2_VERSION)")"
  nghttp3="$(strip_v "$(pin_default NGHTTP3_VERSION)")"
  ngtcp2="$(strip_v "$(pin_default NGTCP2_VERSION)")"
  zlib="$(strip_v "$(pin_default ZLIB_VERSION)")"
  cares="$(strip_v "$(pin_default CARES_VERSION)")"
  brotli="$(strip_v "$(pin_default BROTLI_VERSION)")"
  zstd="$(strip_v "$(pin_default ZSTD_VERSION)")"
  libidn2="$(strip_v "$(pin_default LIBIDN2_VERSION)")"
  libpsl="$(pin_default LIBPSL_VERSION)"
  libssh="$(pin_default LIBSSH_VERSION)"
  libssh="${libssh#libssh-}"
  openldap="$(openldap_version "$(pin_default OPENLDAP_VERSION)")"
  krb5="$(pin_default KRB5_VERSION)"
  krb5="${krb5#krb5-}"
  krb5="${krb5%-final}"

  local missing=0
  for value in "$openssl" "$nghttp2" "$nghttp3" "$ngtcp2" "$zlib" \
               "$cares" "$brotli" "$zstd" "$libidn2" "$libpsl" \
               "$libssh" "$openldap" "$krb5"; do
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
    "c-ares/$cares" \
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

  if [[ -x "$PREFIX_DIR/bin/krb5-config" ]]; then
    local krb5_output
    krb5_output="$(run_in_target "$PREFIX_DIR/bin/krb5-config" --version 2>&1)"
    assert_contains "krb5-config reports $krb5" "$krb5_output" "$krb5"
  else
    fail "krb5-config exists" "missing executable: $PREFIX_DIR/bin/krb5-config"
  fi
}

printf 'Testing curl binary: %s\n\n' "$CURL_BIN"

require_target_executable "curl binary exists" "$CURL_BIN"
require_target_executable "curl-config exists" "$CURL_CONFIG"

if [[ ! -x "$CURL_BIN" ]]; then
  printf '\nCannot continue without a curl binary.\n' >&2
  exit 1
fi

version_output="$(run_curl --version 2>&1)"
config_features="$(run_in_target "$CURL_CONFIG" --features 2>/dev/null || true)"
config_protocols="$(run_in_target "$CURL_CONFIG" --protocols 2>/dev/null || true)"

printf '%s\n\n' "$version_output"

if [[ "$CHECK_PINNED_VERSIONS" == "1" ]]; then
  # These checks prove the expected libraries were compiled into this curl, not
  # merely that a feature name appeared in curl-config output.
  check_pinned_versions
else
  skip "pinned dependency version checks" "CHECK_PINNED_VERSIONS=0"
fi

# libssh and libssh2 provide the same curl protocols but are distinct libraries.
assert_not_contains "version does not report libssh2" "$version_output" 'libssh2'

# curl-config and curl --version use slightly different formats, so check both.
for feature in ECH GSS-API HTTP2 HTTP3 HTTPSRR IDN Kerberos PSL SPNEGO SSL brotli zstd; do
  assert_contains "feature $feature enabled" "$config_features"$'\n'"$version_output" "$feature"
done

for protocol in http https ldap ldaps scp sftp ws wss; do
  assert_contains "protocol $protocol enabled" "$config_protocols"$'\n'"$version_output" "$protocol"
done

if target_has_command ldd; then
  # Linkage checks make sure runtime resolution points at curl-build/prefix
  # instead of compatible libraries accidentally found on the host system.
  ldd_output="$(run_in_target ldd "$CURL_BIN" 2>&1)"
  assert_contains "ldd uses prefix libcurl" "$ldd_output" "$PREFIX_DIR/lib/libcurl.so"
  assert_contains "ldd uses prefix ngtcp2" "$ldd_output" "$PREFIX_DIR/lib/libngtcp2.so"
  assert_contains "ldd uses prefix nghttp3" "$ldd_output" "$PREFIX_DIR/lib/libnghttp3.so"
  assert_contains "ldd uses prefix libssh" "$ldd_output" "$PREFIX_DIR/lib/libssh.so"
  assert_contains "ldd uses prefix c-ares" "$ldd_output" "$PREFIX_DIR/lib/libcares.so"
  assert_contains "ldd uses prefix GSS-API" "$ldd_output" "$PREFIX_DIR/lib/libgssapi_krb5.so"
  assert_contains "ldd uses prefix krb5" "$ldd_output" "$PREFIX_DIR/lib/libkrb5.so"
  assert_not_contains "ldd does not use libssh2" "$ldd_output" 'libssh2'
else
  skip "ldd checks" "ldd is not available in target"
fi

if target_has_command readelf; then
  # RUNPATH is what lets the built curl run from its prefix without requiring a
  # user to export LD_LIBRARY_PATH manually.
  readelf_output="$(run_in_target readelf -d "$CURL_BIN" 2>&1)"
  assert_contains "curl has prefix RUNPATH" "$readelf_output" "$PREFIX_DIR/lib"
else
  skip "RUNPATH check" "readelf is not available in target"
fi

if [[ "$SKIP_NETWORK" == "1" ]]; then
  skip_network_checks
else
  # Network checks exercise protocol behavior that cannot be proven from
  # --version output alone.
  if [[ ! "$NETWORK_JOBS" =~ ^[1-9][0-9]*$ ]]; then
    printf 'NETWORK_JOBS must be a positive integer: %s\n' "$NETWORK_JOBS" >&2
    exit 2
  fi
  parallel_pids=()
  parallel_logs=()
  # The groups are independent and each retains its detailed assertions. Four
  # concurrent groups keeps the suite fast without overloading public services.
  run_parallel_check http network_http_checks
  run_parallel_check compression network_compression_checks
  run_parallel_check ech network_ech_check
  run_parallel_check cache network_cache_checks
  run_parallel_check optional network_optional_checks
  collect_parallel_checks
fi

printf '\nSummary: %d passed, %d failed, %d skipped\n' \
  "$pass_count" "$fail_count" "$skip_count"

if [[ "$fail_count" -gt 0 ]]; then
  exit 1
fi
