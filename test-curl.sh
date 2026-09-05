#!/bin/sh
# Do not use set -e here: the suite should report every failed check in one run.
set -u

ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"

# When run from a checkout, test its local build.  The Docker image installs
# this script in <prefix>/bin, so detect that layout as well.  This keeps the
# normal local workflow unchanged while making the installed script runnable
# without command-line path overrides.
if [ -x "$ROOT_DIR/curl-build/prefix/bin/curl" ]; then
  DEFAULT_PREFIX="$ROOT_DIR/curl-build/prefix"
  DEFAULT_BUILD_CONFIG="$ROOT_DIR/build-curl.sh"
elif [ -x "$(dirname "$ROOT_DIR")/bin/curl" ]; then
  DEFAULT_PREFIX="$(dirname "$ROOT_DIR")"
  DEFAULT_BUILD_CONFIG="$DEFAULT_PREFIX/share/byo-curl/build-curl.sh"
elif [ -x /opt/byo-curl/bin/curl ]; then
  DEFAULT_PREFIX="/opt/byo-curl"
  DEFAULT_BUILD_CONFIG="$DEFAULT_PREFIX/share/byo-curl/build-curl.sh"
else
  DEFAULT_PREFIX="$ROOT_DIR/curl-build/prefix"
  DEFAULT_BUILD_CONFIG="$ROOT_DIR/build-curl.sh"
fi

# The suite can test either the default local build prefix or explicit paths
# supplied by CI, Docker, or a developer comparing another curl binary.
CURL_BIN="${CURL_BIN:-}"
CURL_CONFIG="${CURL_CONFIG:-}"
PREFIX_DIR="${PREFIX_DIR:-}"
BUILD_CONFIG="${BUILD_CONFIG:-$DEFAULT_BUILD_CONFIG}"
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
FTP_TEST_URL="${FTP_TEST_URL-ftp://demo:password@test.rebex.net/}"
SFTP_TEST_URL="${SFTP_TEST_URL-sftp://demo:password@test.rebex.net/}"
SCP_TEST_URL="${SCP_TEST_URL-scp://demo:password@test.rebex.net/readme.txt}"
WS_TEST_URL="${WS_TEST_URL-wss://echo.websocket.org/}"

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
if [ -t 1 ]; then
  green=$(printf '\033[32m')
  red=$(printf '\033[31m')
  yellow=$(printf '\033[33m')
  reset=$(printf '\033[0m')
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

while [ "$#" -gt 0 ]; do
  case "$1" in
    --local)
      shift
      ;;
    --curl-bin)
      if [ "$#" -lt 2 ]; then
        printf 'Missing value for --curl-bin\n' >&2
        exit 2
      fi
      CURL_BIN="$2"
      shift 2
      ;;
    --curl-config)
      if [ "$#" -lt 2 ]; then
        printf 'Missing value for --curl-config\n' >&2
        exit 2
      fi
      CURL_CONFIG="$2"
      shift 2
      ;;
    --prefix)
      if [ "$#" -lt 2 ]; then
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

CURL_BIN="${CURL_BIN:-$DEFAULT_PREFIX/bin/curl}"
CURL_CONFIG="${CURL_CONFIG:-$DEFAULT_PREFIX/bin/curl-config}"
PREFIX_DIR="${PREFIX_DIR:-$DEFAULT_PREFIX}"

pass() {
  if [ "${IN_PARALLEL:-0}" = 1 ]; then
    printf 'PASS %s\n' "$1"
  else
    printf '%sPASS%s %s\n' "$green" "$reset" "$1"
  fi
  pass_count=$((pass_count + 1))
}

fail() {
  if [ "${IN_PARALLEL:-0}" = 1 ]; then
    printf 'FAIL %s\n' "$1"
  else
    printf '%sFAIL%s %s\n' "$red" "$reset" "$1"
  fi
  if [ "$#" -gt 1 ] && [ -n "$2" ]; then
    printf '     %s\n' "$2"
  fi
  fail_count=$((fail_count + 1))
}

skip() {
  if [ "${IN_PARALLEL:-0}" = 1 ]; then
    printf 'SKIP %s\n' "$1"
  else
    printf '%sSKIP%s %s\n' "$yellow" "$reset" "$1"
  fi
  if [ "$#" -gt 1 ] && [ -n "$2" ]; then
    printf '     %s\n' "$2"
  fi
  skip_count=$((skip_count + 1))
}

require_file() {
  require_file_name="$1"
  require_file_path="$2"

  if [ -x "$require_file_path" ]; then
    pass "$require_file_name"
  else
    fail "$require_file_name" "missing executable: $require_file_path"
  fi
}

require_target_executable() {
  require_file "$1" "$2"
}

contains() {
  case "$1" in
    *"$2"*) return 0 ;;
    *) return 1 ;;
  esac
}

assert_contains() {
  if contains "$2" "$3"; then
    pass "$1"
  else
    fail "$1" "expected to find: $3"
  fi
}

assert_not_contains() {
  if contains "$2" "$3"; then
    fail "$1" "unexpectedly found: $3"
  else
    pass "$1"
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
  entrypoint="$1"
  shift

  "$entrypoint" "$@"
}

target_has_command() {
  command -v "$1" >/dev/null 2>&1
}

check_status_version() {
  # Fetch a URL and assert both a successful status code and the negotiated HTTP
  # version. This catches regressions where a protocol is compiled in but not
  # actually usable against a real endpoint.
  csv_name="$1"
  csv_expected_version="$2"
  shift 2

  if csv_output="$(curl_status_version "$@" 2>&1)"; then
    csv_code=${csv_output%% *}
    csv_version=${csv_output#* }
    case "$csv_code" in
      2[0-9][0-9]) csv_success=1 ;;
      *) csv_success=0 ;;
    esac
    if [ "$csv_success" = 1 ] && [ "$csv_version" = "$csv_expected_version" ]; then
      pass "$csv_name"
    else
      fail "$csv_name" "got HTTP $csv_code over version $csv_version"
    fi
  else
    fail "$csv_name" "$csv_output"
  fi
}

run_text_check() {
  # Use for checks where curl's response body or trace output should contain a
  # small stable marker.
  rtc_name="$1"
  rtc_needle="$2"
  shift 2

  if rtc_output="$(curl_capture "$@" 2>&1)"; then
    if contains "$rtc_output" "$rtc_needle"; then
      pass "$rtc_name"
    else
      fail "$rtc_name" "response did not contain: $rtc_needle"
    fi
  else
    fail "$rtc_name" "$rtc_output"
  fi
}

run_optional_url_check() {
  # Protocol checks such as FTP/SFTP/SCP are useful but endpoint-dependent. A
  # caller can set the URL to an empty string to skip a single protocol.
  rouc_name="$1"
  rouc_url="$2"
  shift 2

  if [ -z "$rouc_url" ]; then
    skip "$rouc_name" "set ${rouc_name}_URL or the documented protocol-specific variable to enable"
    return
  fi

  if rouc_output="$(curl_capture "$@" --output /dev/null "$rouc_url" 2>&1)"; then
    pass "$rouc_name"
  else
    fail "$rouc_name" "$rouc_output"
  fi
}

run_header_check() {
  # Header-based checks are used for content negotiation so the body does not
  # need to be downloaded or parsed.
  rhc_name="$1"
  rhc_needle="$2"
  shift 2
  rhc_safe_name=$(printf '%s' "$rhc_name" | tr -c '[:alnum:]_' '_')
  rhc_headers_file="$tmpdir/$rhc_safe_name.headers"

  if rhc_output="$(curl_capture --dump-header "$rhc_headers_file" --output /dev/null "$@" 2>&1)"; then
    if grep -qi "$rhc_needle" "$rhc_headers_file"; then
      pass "$rhc_name"
    else
      fail "$rhc_name" "response headers did not contain: $rhc_needle"
    fi
  else
    fail "$rhc_name" "$rhc_output"
  fi
}

run_ws_check() {
  # The public websocket endpoint keeps the connection open long enough for curl
  # to hit the timeout after receiving a server banner. Treat that as success.
  rws_name="$1"
  rws_url="$2"

  if [ -z "$rws_url" ]; then
    skip "$rws_name" "set WS_TEST_URL to enable"
    return
  fi

  rws_output="$(run_curl --silent --show-error --max-time 5 "$rws_url" 2>&1)"
  rws_rc=$?
  if [ "$rws_rc" -eq 0 ]; then
    pass "$rws_name"
  elif [ "$rws_rc" -eq 28 ] && contains "$rws_output" 'Request served by'; then
    pass "$rws_name"
  else
    fail "$rws_name" "$rws_output"
  fi
}

run_parallel_check() {
  rpc_name="$1"
  shift
  # Wait for the current batch before starting another so NETWORK_JOBS is a
  # strict upper bound without losing the output needed for the final summary.
  if [ "$parallel_count" -ge "$NETWORK_JOBS" ]; then
    collect_parallel_checks
    parallel_pids=
    parallel_logs=
    parallel_count=0
  fi
  # Child output is collected from a file, so keep it free of terminal escape
  # sequences. The collector uses the PASS/FAIL/SKIP prefix to update totals.
  (IN_PARALLEL=1 "$@") >"$tmpdir/$rpc_name.log" 2>&1 &
  parallel_pids="$parallel_pids $!"
  parallel_logs="$parallel_logs $tmpdir/$rpc_name.log"
  parallel_count=$((parallel_count + 1))
}

collect_parallel_checks() {
  # Functions run in background subshells, so their counter updates do not
  # reach this shell. Rebuild those totals from their plain-text result logs.
  for cpc_pid in $parallel_pids; do
    wait "$cpc_pid" || :
  done
  for cpc_log in $parallel_logs; do
    while IFS= read -r cpc_line || [ -n "$cpc_line" ]; do
      case "$cpc_line" in
        PASS\ *)
          printf '%sPASS%s%s\n' "$green" "$reset" "${cpc_line#PASS}"
          pass_count=$((pass_count + 1))
          ;;
        FAIL\ *)
          printf '%sFAIL%s%s\n' "$red" "$reset" "${cpc_line#FAIL}"
          fail_count=$((fail_count + 1))
          ;;
        SKIP\ *)
          printf '%sSKIP%s%s\n' "$yellow" "$reset" "${cpc_line#SKIP}"
          skip_count=$((skip_count + 1))
          ;;
        *) printf '%s\n' "$cpc_line" ;;
      esac
    done <"$cpc_log"
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
  ech_output="$(curl_capture --tlsv1.3 --ech hard --doh-url "$DOH_URL" "$ECH_URL" 2>&1)"
  ech_rc=$?
  if [ "$ech_rc" -eq 0 ]; then
    assert_contains "ECH encrypts SNI" "$ech_output" 'sni=encrypted'
    assert_contains "ECH endpoint used TLS 1.3" "$ech_output" 'tls=TLSv1.3'
  else
    fail "ECH request" "$ech_output"
  fi
}

network_cache_checks() {
  hsts_file="$TEST_TMPDIR/hsts.txt"
  if curl_capture --hsts "$hsts_file" --output /dev/null "$HTTP2_URL" >/dev/null 2>&1 && grep -Eq '^[[:space:]]*[^#[:space:]]' "$hsts_file"; then
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
  if [ "$SKIP_LDAP" = "1" ]; then
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
  for skip_name in \
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
    skip "$skip_name"
  done
}

pin_default() {
  # Read version defaults directly from build-curl.sh so the test expectations
  # stay aligned with the build script.
  pin_name="$1"
  [ -r "$BUILD_CONFIG" ] || return 0
  sed -n 's/^'"$pin_name"'="${'"$pin_name"':-\([^}]*\)}".*/\1/p' "$BUILD_CONFIG"
}

strip_v() {
  printf '%s\n' "${1#v}"
}

openssl_runtime_version() {
  # OpenSSL's Git tag is openssl-X.Y.Z, but curl reports OpenSSL/X.Y.Z.
  printf '%s\n' "${1#openssl-}"
}

openldap_version() {
  olv_value=${1#OPENLDAP_REL_ENG_}
  printf '%s\n' "$olv_value" | tr '_' '.'
}

check_pinned_versions() {
  # Keep expected dependency versions in one place by reading the defaults from
  # build-curl.sh instead of duplicating them in this test script.
  cpv_openssl="$(openssl_runtime_version "$(pin_default OPENSSL_VERSION)")"
  cpv_nghttp2="$(strip_v "$(pin_default NGHTTP2_VERSION)")"
  cpv_nghttp3="$(strip_v "$(pin_default NGHTTP3_VERSION)")"
  cpv_ngtcp2="$(strip_v "$(pin_default NGTCP2_VERSION)")"
  cpv_zlib="$(strip_v "$(pin_default ZLIB_VERSION)")"
  cpv_cares="$(strip_v "$(pin_default CARES_VERSION)")"
  cpv_brotli="$(strip_v "$(pin_default BROTLI_VERSION)")"
  cpv_zstd="$(strip_v "$(pin_default ZSTD_VERSION)")"
  cpv_libidn2="$(strip_v "$(pin_default LIBIDN2_VERSION)")"
  cpv_libpsl="$(pin_default LIBPSL_VERSION)"
  cpv_libssh="$(pin_default LIBSSH_VERSION)"
  cpv_libssh="${cpv_libssh#libssh-}"
  cpv_openldap="$(openldap_version "$(pin_default OPENLDAP_VERSION)")"
  cpv_krb5="$(pin_default KRB5_VERSION)"
  cpv_krb5="${cpv_krb5#krb5-}"
  cpv_krb5="${cpv_krb5%-final}"

  cpv_missing=0
  for cpv_value in "$cpv_openssl" "$cpv_nghttp2" "$cpv_nghttp3" "$cpv_ngtcp2" "$cpv_zlib" \
                   "$cpv_cares" "$cpv_brotli" "$cpv_zstd" "$cpv_libidn2" "$cpv_libpsl" \
                   "$cpv_libssh" "$cpv_openldap" "$cpv_krb5"; do
    if [ -z "$cpv_value" ]; then
      cpv_missing=1
    fi
  done

  if [ "$cpv_missing" = "1" ]; then
    skip "pinned dependency version checks" "could not read all defaults from $BUILD_CONFIG"
    return
  fi

  for needle in \
    "OpenSSL/$cpv_openssl" \
    "zlib/$cpv_zlib" \
    "c-ares/$cpv_cares" \
    "brotli/$cpv_brotli" \
    "zstd/$cpv_zstd" \
    "libidn2/$cpv_libidn2" \
    "libpsl/$cpv_libpsl" \
    "libssh/$cpv_libssh" \
    "nghttp2/$cpv_nghttp2" \
    "ngtcp2/$cpv_ngtcp2" \
    "nghttp3/$cpv_nghttp3" \
    "OpenLDAP/$cpv_openldap"; do
    assert_contains "version reports $needle" "$version_output" "$needle"
  done

  if [ -x "$PREFIX_DIR/bin/krb5-config" ]; then
    cpv_krb5_output="$(run_in_target "$PREFIX_DIR/bin/krb5-config" --version 2>&1)"
    assert_contains "krb5-config reports $cpv_krb5" "$cpv_krb5_output" "$cpv_krb5"
  else
    fail "krb5-config exists" "missing executable: $PREFIX_DIR/bin/krb5-config"
  fi
}

printf 'Testing curl binary: %s\n\n' "$CURL_BIN"

require_target_executable "curl binary exists" "$CURL_BIN"
require_target_executable "curl-config exists" "$CURL_CONFIG"

if [ ! -x "$CURL_BIN" ]; then
  printf '\nCannot continue without a curl binary.\n' >&2
  exit 1
fi

version_output="$(run_curl --version 2>&1)"
config_features="$(run_in_target "$CURL_CONFIG" --features 2>/dev/null || true)"
config_protocols="$(run_in_target "$CURL_CONFIG" --protocols 2>/dev/null || true)"

printf '%s\n\n' "$version_output"

if [ "$CHECK_PINNED_VERSIONS" = "1" ]; then
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
  config_and_version="$config_features
$version_output"
  assert_contains "feature $feature enabled" "$config_and_version" "$feature"
done

for protocol in http https ldap ldaps scp sftp ws wss; do
  config_and_version="$config_protocols
$version_output"
  assert_contains "protocol $protocol enabled" "$config_and_version" "$protocol"
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
  # user to export LD_LIBRARY_PATH manually.  The Docker image relocates the
  # prefix from the host build directory to /opt/byo-curl, so it supplies that
  # directory through LD_LIBRARY_PATH instead.
  readelf_output="$(run_in_target readelf -d "$CURL_BIN" 2>&1)"
  if contains "$readelf_output" "$PREFIX_DIR/lib"; then
    pass "curl has prefix RUNPATH"
  elif contains ":${LD_LIBRARY_PATH:-}:" ":$PREFIX_DIR/lib:"; then
    pass "curl loads prefix libraries via LD_LIBRARY_PATH"
  else
    fail "curl has prefix RUNPATH" "expected RUNPATH or LD_LIBRARY_PATH to contain: $PREFIX_DIR/lib"
  fi
else
  skip "RUNPATH check" "readelf is not available in target"
fi

if [ "$SKIP_NETWORK" = "1" ]; then
  skip_network_checks
else
  # Network checks exercise protocol behavior that cannot be proven from
  # --version output alone.
  case "$NETWORK_JOBS" in
    ''|*[!0-9]*) network_jobs_valid=0 ;;
    *)
      if [ "$NETWORK_JOBS" -gt 0 ]; then
        network_jobs_valid=1
      else
        network_jobs_valid=0
      fi
      ;;
  esac
  if [ "$network_jobs_valid" -ne 1 ]; then
    printf 'NETWORK_JOBS must be a positive integer: %s\n' "$NETWORK_JOBS" >&2
    exit 2
  fi
  parallel_pids=
  parallel_logs=
  parallel_count=0
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

if [ "$fail_count" -gt 0 ]; then
  exit 1
fi
