#!/usr/bin/env bash
set -Eeuo pipefail

# Pinned upstream versions. Most are git tags; OpenSSL and curl use the tag
# naming convention expected by their repositories. Every value can be
# overridden from the environment when testing a newer dependency.
OPENSSL_VERSION="${OPENSSL_VERSION:-openssl-4.0.2}"
NGHTTP2_VERSION="${NGHTTP2_VERSION:-v1.70.0}"
NGHTTP3_VERSION="${NGHTTP3_VERSION:-v1.18.0}"
NGTCP2_VERSION="${NGTCP2_VERSION:-v1.25.0}"
CURL_VERSION="${CURL_VERSION:-curl-8_21_0}"
ZLIB_VERSION="${ZLIB_VERSION:-v1.3.2}"
CARES_VERSION="${CARES_VERSION:-v1.34.8}"
BROTLI_VERSION="${BROTLI_VERSION:-v1.2.0}"
ZSTD_VERSION="${ZSTD_VERSION:-v1.5.7}"
LIBUNISTRING_VERSION="${LIBUNISTRING_VERSION:-1.4.2}"
LIBIDN2_VERSION="${LIBIDN2_VERSION:-v2.3.8}"
LIBPSL_VERSION="${LIBPSL_VERSION:-0.23.3}"
LIBSSH_VERSION="${LIBSSH_VERSION:-libssh-0.12.2}"
OPENLDAP_VERSION="${OPENLDAP_VERSION:-OPENLDAP_REL_ENG_2_7_0}"
KRB5_VERSION="${KRB5_VERSION:-krb5-1.22.2-final}"
CURL_BUILD_SUFFIX="${CURL_BUILD_SUFFIX:-i81b4u}"
CURL_RELEASE_DATE="${CURL_RELEASE_DATE:-$(date +%Y-%m-%d)}"

# Everything is built below WORK_DIR. Sources, out-of-tree builds, and the
# final install prefix stay separate so a failed build can be inspected.
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK_DIR="${WORK_DIR:-$ROOT_DIR/curl-build}"
SRC_DIR="$WORK_DIR/src"
BUILD_DIR="$WORK_DIR/build"
PREFIX="${PREFIX:-$WORK_DIR/prefix}"
JOBS="${JOBS:-$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 2)}"
# Reuse completed components only when all inputs that affect their output are
# unchanged. REFRESH_SOURCES opts into a network refresh of existing checkouts.
BUILD_CACHE="${BUILD_CACHE:-1}"
REFRESH_SOURCES="${REFRESH_SOURCES:-0}"
# State holds cache keys; logs contain the complete output for each stage.
STATE_DIR="$WORK_DIR/state"
LOG_DIR="$WORK_DIR/logs"
DOWNLOAD_DIR="$WORK_DIR/downloads"
LIBUNISTRING_URL="${LIBUNISTRING_URL:-https://ftp.gnu.org/gnu/libunistring/libunistring-$LIBUNISTRING_VERSION.tar.gz}"
TOTAL_STAGES=17
stage_number=0

# Prefer the freshly built dependencies over system libraries and embed rpaths
# so the resulting curl can run from this prefix without extra linker setup.
export PATH="$PREFIX/bin:$PATH"
export PKG_CONFIG_PATH="$PREFIX/lib/pkgconfig:$PREFIX/lib64/pkgconfig:$PREFIX/share/pkgconfig:${PKG_CONFIG_PATH:-}"
export CPPFLAGS="-I$PREFIX/include ${CPPFLAGS:-}"
export LDFLAGS="-L$PREFIX/lib -L$PREFIX/lib64 -Wl,-rpath,$PREFIX/lib -Wl,-rpath,$PREFIX/lib64 ${LDFLAGS:-}"
export LD_LIBRARY_PATH="$PREFIX/lib:$PREFIX/lib64:${LD_LIBRARY_PATH:-}"
export CFLAGS="${CFLAGS:--O2}"
export CXXFLAGS="${CXXFLAGS:--O2}"

log() {
  printf '\n==> %s\n' "$*"
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    printf 'Missing required command: %s\n' "$1" >&2
    exit 1
  }
}

# Clone a shallow checkout at the requested tag/branch. Existing checkouts are
# refreshed to the requested revision instead of recloned.
clone_repo() {
  local name="$1"
  local branch="$2"
  local url="$3"
  local submodules="${4:-no}"
  local dst="$SRC_DIR/$name"

  if [[ -d "$dst/.git" ]]; then
    log "Using existing source: $name"
    if [[ "$REFRESH_SOURCES" == "1" ]] || ! git -C "$dst" rev-parse -q --verify "$branch^{commit}" >/dev/null; then
      git -C "$dst" fetch --depth 1 origin "$branch"
      git -C "$dst" checkout -q FETCH_HEAD
    else
      git -C "$dst" checkout -q "$branch"
    fi
  else
    log "Cloning $name ($branch)"
    git clone --depth 1 --branch "$branch" "$url" "$dst"
  fi

  if [[ "$submodules" == "yes" ]]; then
    git -C "$dst" submodule update --init --recursive --depth 1
  fi
}

# Git checkouts often lack generated configure scripts. Use the local bootstrap
# helper when a project provides one, otherwise fall back to autoreconf.
run_autogen_if_needed() {
  if [[ -x ./autogen.sh ]]; then
    ./autogen.sh
  elif [[ -x ./buildconf ]]; then
    ./buildconf
  elif [[ -x ./bootstrap ]]; then
    ./bootstrap
  elif [[ -x ./bootstrap.sh ]]; then
    ./bootstrap.sh
  elif [[ -f configure.ac || -f configure.in ]] && [[ ! -x ./configure ]]; then
    autoreconf -fi
  fi
}

# Common CMake builder used by Brotli, nghttp2/nghttp3, and libssh.
cmake_build() {
  local name="$1"
  shift
  local src="$SRC_DIR/$name"
  local bld="$BUILD_DIR/$name"

  rm -rf "$bld"
  cmake -S "$src" -B "$bld" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX="$PREFIX" \
    -DCMAKE_INSTALL_LIBDIR=lib \
    -DCMAKE_PREFIX_PATH="$PREFIX" \
    -DCMAKE_INSTALL_RPATH="$PREFIX/lib;$PREFIX/lib64" \
    "$@"
  cmake --build "$bld" --parallel "$JOBS"
  cmake --install "$bld"
}

# Common Autotools builder. Configure is generated from git checkouts only when
# it is not already present.
autotools_build() {
  local name="$1"
  shift
  local src="$SRC_DIR/$name"
  local bld="$BUILD_DIR/$name"

  rm -rf "$bld"
  mkdir -p "$bld"
  (
    cd "$src"
    if [[ ! -x ./configure ]]; then
      run_autogen_if_needed
    fi
  )
  (
    cd "$bld"
    "$src/configure" --prefix="$PREFIX" "$@"
    make -j"$JOBS"
    make install
  )
}

require_tools() {
  # These are host build tools, not curl runtime dependencies.
  local commands=(
    autoconf automake autoreconf cmake gengetopt git gperf libtoolize make
    date perl pkg-config sed autopoint yacc awk sha256sum tar
  )
  for cmd in "${commands[@]}"; do
    need_cmd "$cmd"
  done
}

prepare() {
  mkdir -p "$SRC_DIR" "$BUILD_DIR" "$PREFIX" "$STATE_DIR" "$LOG_DIR" "$DOWNLOAD_DIR"
}

# Run one named build stage in the background so its complete output can be
# retained in a log while the foreground reports progress. Non-interactive
# callers receive newline-delimited status instead of terminal control codes.
run_stage() {
  local name="$1"
  shift
  local stage_log slug pid start elapsed frame_index=0
  local -a frames=( '|' '/' '-' $'\\' )

  stage_number=$((stage_number + 1))
  slug="${name,,}"
  slug="${slug// /-}"
  slug="${slug//[^a-z0-9-]/}"
  stage_log="$LOG_DIR/$(printf '%02d' "$stage_number")-$slug.log"
  start=$SECONDS

  if [[ -t 1 ]]; then
    printf '[%02d/%02d] %s' "$stage_number" "$TOTAL_STAGES" "$name"
  else
    printf '[%02d/%02d] %s started\n' "$stage_number" "$TOTAL_STAGES" "$name"
  fi
  "$@" >"$stage_log" 2>&1 &
  pid=$!

  if [[ -t 1 ]]; then
    while kill -0 "$pid" 2>/dev/null; do
      printf '\r[%02d/%02d] %s %s' \
        "$stage_number" "$TOTAL_STAGES" "$name" "${frames[frame_index]}"
      frame_index=$(((frame_index + 1) % ${#frames[@]}))
      sleep 0.1
    done
  fi

  if wait "$pid"; then
    elapsed=$((SECONDS - start))
    if [[ -t 1 ]]; then
      printf '\r\033[K'
    fi
    printf '[%02d/%02d] %s done (%ss)\n' \
      "$stage_number" "$TOTAL_STAGES" "$name" "$elapsed"
    return
  fi

  elapsed=$((SECONDS - start))
  if [[ -t 1 ]]; then
    printf '\r\033[K'
  fi
  printf '[%02d/%02d] %s failed after %ss\n' \
    "$stage_number" "$TOTAL_STAGES" "$name" "$elapsed" >&2
  printf 'Log: %s\n\nLast 40 lines:\n' "$stage_log" >&2
  tail -n 40 "$stage_log" >&2 || true
  printf '\n' >&2
  return 1
}

component_state() {
  printf '%s/%s.sha256\n' "$STATE_DIR" "$1"
}

# A component key includes its source revision, build-affecting environment,
# this script's content, and direct dependency keys. A script edit therefore
# deliberately invalidates cached components for a conservative rebuild.
source_identity() {
  local name="$1"
  local src="$SRC_DIR/$name"

  if [[ -d "$src/.git" ]]; then
    git -C "$src" rev-parse HEAD
  elif [[ -f "$src/.source-archive" ]]; then
    cat "$src/.source-archive"
  else
    printf 'missing source identity for %s\n' "$name" >&2
    return 1
  fi
}

component_key() {
  local name="$1"
  shift
  {
    printf '%s\n' "source=$(source_identity "$name")"
    printf '%s\n' "script=$(sha256sum "${BASH_SOURCE[0]}" | awk '{print $1}')"
    printf '%s\n' "prefix=$PREFIX" "cflags=$CFLAGS" "cxxflags=$CXXFLAGS"
    printf '%s\n' "cppflags=$CPPFLAGS" "ldflags=$LDFLAGS"
    local dependency
    for dependency in "$@"; do
      printf '%s=' "$dependency"
      cat "$(component_state "$dependency")" 2>/dev/null || printf 'missing\n'
    done
  } | sha256sum | awk '{print $1}'
}

build_cached() {
  local name="$1"
  local artifact="$2"
  local builder="$3"
  shift 3
  local state key
  state="$(component_state "$name")"
  key="$(component_key "$name" "$@")"

  # Do not trust a state file by itself: the expected installed artifact must
  # still be present before a component can be skipped.
  if [[ "$BUILD_CACHE" == "1" && -e "$artifact" && -f "$state" && "$(<"$state")" == "$key" ]]; then
    log "Using cached build: $name"
    return
  fi

  "$builder"
  printf '%s\n' "$key" > "$state"
}

# Fetch Git sources and the libunistring release archive. Some Git projects
# need submodules because their build system or test-disabled library build
# expects bundled helper files.
fetch_sources() {
  clone_repo openssl "$OPENSSL_VERSION" https://github.com/openssl/openssl.git
  clone_repo nghttp2 "$NGHTTP2_VERSION" https://github.com/nghttp2/nghttp2.git
  clone_repo nghttp3 "$NGHTTP3_VERSION" https://github.com/ngtcp2/nghttp3.git yes
  clone_repo ngtcp2 "$NGTCP2_VERSION" https://github.com/ngtcp2/ngtcp2.git yes
  clone_repo zlib "$ZLIB_VERSION" https://github.com/madler/zlib.git
  clone_repo c-ares "$CARES_VERSION" https://github.com/c-ares/c-ares.git
  clone_repo brotli "$BROTLI_VERSION" https://github.com/google/brotli.git
  clone_repo zstd "$ZSTD_VERSION" https://github.com/facebook/zstd.git
  fetch_libunistring
  clone_repo libidn2 "$LIBIDN2_VERSION" https://github.com/libidn/libidn2.git
  clone_repo libpsl "$LIBPSL_VERSION" https://github.com/rockdaboot/libpsl.git yes
  clone_repo libssh "$LIBSSH_VERSION" https://gitlab.com/libssh/libssh-mirror.git
  clone_repo openldap "$OPENLDAP_VERSION" https://github.com/openldap/openldap.git
  clone_repo krb5 "$KRB5_VERSION" https://github.com/krb5/krb5.git
  clone_repo curl "$CURL_VERSION" https://github.com/curl/curl.git
}

download_file() {
  local url="$1"
  local destination="$2"
  local temporary="$destination.part"

  # Download to a sibling temporary file so an interrupted refresh never
  # replaces the previously cached archive with a partial download.
  rm -f "$temporary"
  if command -v curl >/dev/null 2>&1; then
    curl --fail --location --retry 3 --retry-delay 2 --output "$temporary" "$url"
  elif command -v wget >/dev/null 2>&1; then
    wget --tries=4 --waitretry=2 --output-document="$temporary" "$url"
  else
    printf 'Missing downloader: install curl or wget to fetch libunistring.\n' >&2
    return 1
  fi
  mv "$temporary" "$destination"
}

# Keep libunistring on its GNU release archive. Its Git checkout needs a second
# gnulib fetch and has caused timeout or incomplete-checkout failures in this
# build. The archive contains the generated configure and gnulib files instead.
fetch_libunistring() {
  local archive="$DOWNLOAD_DIR/libunistring-$LIBUNISTRING_VERSION.tar.gz"
  local extracted="$SRC_DIR/libunistring-$LIBUNISTRING_VERSION"
  local src="$SRC_DIR/libunistring"
  local source_id

  if [[ ! -f "$archive" ]] || [[ "$REFRESH_SOURCES" == "1" ]]; then
    log "Downloading libunistring $LIBUNISTRING_VERSION"
    download_file "$LIBUNISTRING_URL" "$archive"
  else
    log "Using cached libunistring archive: $archive"
  fi

  source_id="url=$LIBUNISTRING_URL sha256=$(sha256sum "$archive" | awk '{print $1}')"
  if [[ ! -f "$src/.source-archive" ]] || [[ "$(<"$src/.source-archive")" != "$source_id" ]]; then
    log "Extracting libunistring $LIBUNISTRING_VERSION"
    rm -rf "$src" "$extracted"
    tar -xzf "$archive" -C "$SRC_DIR"
    mv "$extracted" "$src"
    printf '%s\n' "$source_id" > "$src/.source-archive"
  fi
}

# OpenLDAP 2.6.13 still dereferences ASN1_STRING internals in this file.
# OpenSSL 4 makes that type opaque, so switch the affected CN checks to the
# public accessor functions before building.
patch_openldap() {
  local file="$SRC_DIR/openldap/libraries/libldap/tls_o.c"

  if ! grep -q 'cn->length' "$file"; then
    return
  fi

  log "Patching OpenLDAP for OpenSSL 4 ASN1_STRING accessors"
  perl -0pi -e '
    s/cn->length/ASN1_STRING_length( cn )/g;
    s/cn->data/ASN1_STRING_data( cn )/g;
    s/&ASN1_STRING_data\( cn \)\[1\]/ASN1_STRING_data( cn ) + 1/g;
  ' "$file"
}

# The curl git tag reports itself as 8.21.0-DEV and "[unreleased]". Stamp the
# local build so --version and User-Agent identify this custom binary clearly.
patch_curl_version() {
  local header="$SRC_DIR/curl/include/curl/curlver.h"
  local major minor patch base_version stamped_version

  major="$(sed -n 's/^#define LIBCURL_VERSION_MAJOR \([0-9][0-9]*\)$/\1/p' "$header")"
  minor="$(sed -n 's/^#define LIBCURL_VERSION_MINOR \([0-9][0-9]*\)$/\1/p' "$header")"
  patch="$(sed -n 's/^#define LIBCURL_VERSION_PATCH \([0-9][0-9]*\)$/\1/p' "$header")"
  base_version="$major.$minor.$patch"

  if [[ -z "$major" || -z "$minor" || -z "$patch" ]]; then
    printf 'Could not read curl version parts from %s\n' "$header" >&2
    exit 1
  fi
  if [[ ! "$CURL_BUILD_SUFFIX" =~ ^[A-Za-z0-9._+~-]+$ ]]; then
    printf 'Invalid CURL_BUILD_SUFFIX: %s\n' "$CURL_BUILD_SUFFIX" >&2
    exit 1
  fi
  if [[ ! "$CURL_RELEASE_DATE" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
    printf 'Invalid CURL_RELEASE_DATE, expected YYYY-MM-DD: %s\n' "$CURL_RELEASE_DATE" >&2
    exit 1
  fi

  stamped_version="$base_version-$CURL_BUILD_SUFFIX"
  log "Stamping curl as $stamped_version with release date $CURL_RELEASE_DATE"
  perl -0pi -e \
    's/#define LIBCURL_VERSION "[^"]+"/#define LIBCURL_VERSION "'"$stamped_version"'"/;
     s/#define LIBCURL_TIMESTAMP "[^"]+"/#define LIBCURL_TIMESTAMP "'"$CURL_RELEASE_DATE"'"/;' \
    "$header"
}

apply_source_patches() {
  patch_openldap
  patch_curl_version
}

build_openssl() {
  local display_version="${OPENSSL_VERSION#openssl-}"
  log "Building OpenSSL $display_version"
  (
    cd "$SRC_DIR/openssl"
    # OpenSSL builds in-tree. Clean generated files so reruns use the current
    # configure arguments and do not accidentally retain objects from a prior
    # dependency experiment.
    git clean -xfd
    ./Configure \
      --prefix="$PREFIX" \
      --openssldir="$PREFIX/ssl" \
      shared \
      enable-quic \
      no-tests \
      "-Wl,-rpath,$PREFIX/lib"
    make -j"$JOBS" build_sw
    make install_sw
  )
}

build_zlib() {
  log "Building zlib $ZLIB_VERSION"
  (
    cd "$SRC_DIR/zlib"
    # zlib's upstream build is also in-tree.
    git clean -xfd
    ./configure --prefix="$PREFIX"
    make -j"$JOBS"
    make install
  )
}

build_cares() {
  log "Building c-ares $CARES_VERSION"
  # c-ares gives curl an asynchronous resolver. The smoke test later exercises
  # this path with curl's --dns-servers option, which is not available with the
  # default threaded resolver.
  cmake_build c-ares \
    -DBUILD_SHARED_LIBS=ON \
    -DCARES_STATIC=OFF \
    -DCARES_SHARED=ON \
    -DCARES_BUILD_TOOLS=OFF \
    -DCARES_BUILD_TESTS=OFF
}

build_brotli() {
  log "Building Brotli $BROTLI_VERSION"
  # curl links to libbrotlidec for response decompression.
  cmake_build brotli \
    -DBUILD_SHARED_LIBS=ON \
    -DBROTLI_DISABLE_TESTS=ON
}

build_zstd() {
  log "Building zstd $ZSTD_VERSION"
  # zstd's library makefile supports direct installation into PREFIX.
  make -C "$SRC_DIR/zstd/lib" -j"$JOBS" PREFIX="$PREFIX" install
}

# The release archive already includes generated configure and gnulib files.
# Build only the library/header subtree because curl and libidn2 do not require
# the Texinfo documentation.
build_libunistring() {
  log "Building libunistring $LIBUNISTRING_VERSION"
  local src="$SRC_DIR/libunistring"
  local bld="$BUILD_DIR/libunistring"

  rm -rf "$bld"
  mkdir -p "$bld"
  (
    cd "$bld"
    "$src/configure" --prefix="$PREFIX" --disable-static
    make -C lib -j"$JOBS"
    make -C lib install
  )
}

build_libidn2() {
  log "Building libidn2 $LIBIDN2_VERSION"
  # libidn2 provides IDNA support; it depends on the libunistring build above.
  autotools_build libidn2 \
    --disable-doc \
    --disable-nls \
    --with-libunistring-prefix="$PREFIX"
}

build_libpsl() {
  log "Building libpsl $LIBPSL_VERSION"
  # libpsl lets curl reason about public suffix boundaries for cookies and
  # related host policy decisions. Use the bundled public suffix data.
  autotools_build libpsl \
    --disable-gtk-doc \
    --disable-man \
    --disable-runtime \
    --disable-nls \
    --enable-builtin=libidn2 \
    --with-libidn2
}

build_nghttp2() {
  log "Building nghttp2 $NGHTTP2_VERSION"
  # nghttp2 supplies curl's HTTP/2 implementation.
  cmake_build nghttp2 \
    -DBUILD_SHARED_LIBS=ON \
    -DENABLE_LIB_ONLY=ON \
    -DENABLE_DOC=OFF
}

build_nghttp3() {
  log "Building nghttp3 $NGHTTP3_VERSION"
  # nghttp3 is the HTTP/3 layer used by ngtcp2.
  cmake_build nghttp3 \
    -DBUILD_SHARED_LIBS=ON \
    -DENABLE_LIB_ONLY=ON \
    -DENABLE_DOC=OFF
}

build_ngtcp2() {
  log "Building ngtcp2 $NGTCP2_VERSION"
  # ngtcp2 supplies QUIC transport for curl's HTTP/3 support. This build binds
  # it to the OpenSSL QUIC/TLS stack built earlier.
  autotools_build ngtcp2 \
    --enable-lib-only \
    --with-openssl="$PREFIX" \
    --with-libnghttp3="$PREFIX" \
    --disable-gnutls \
    --disable-wolfssl \
    --disable-boringssl \
    --disable-picotls
}

build_libssh() {
  log "Building libssh $LIBSSH_VERSION"
  # libssh provides curl's SCP/SFTP protocols. WITH_GSSAPI makes SSH
  # authentication able to use the MIT Kerberos libraries built below.
  cmake_build libssh \
    -DBUILD_SHARED_LIBS=ON \
    -DWITH_EXAMPLES=OFF \
    -DWITH_TESTING=OFF \
    -DWITH_GSSAPI=ON \
    -DOPENSSL_ROOT_DIR="$PREFIX"
}

build_krb5() {
  log "Building MIT Kerberos $KRB5_VERSION"
  local src="$SRC_DIR/krb5/src"
  local bld="$BUILD_DIR/krb5"

  # The krb5 repository keeps the Autotools project below src/.
  rm -rf "$bld"
  mkdir -p "$bld"
  (
    cd "$src"
    if [[ ! -x ./configure ]]; then
      if [[ -x ./util/reconf ]]; then
        ./util/reconf
      else
        # The released krb5 tree carries its generated aclocal.m4.  Running
        # autoreconf invokes aclocal first, which overwrites that file and
        # breaks this version with newer Autoconf (as shipped by Arch).
        # Run the generators separately so aclocal is not invoked.  Autoheader
        # produces the config-header template required by configure.
        autoheader
        autoconf
      fi
    fi
  )
  (
    cd "$bld"
    # MIT krb5's default warning flags can turn harmless const-qualifier
    # warnings into build failures with newer compilers. PKINIT is not needed
    # for curl's GSS-API/SPNEGO support and this pinned krb5 tag does not
    # compile that plugin against OpenSSL 4's opaque ASN.1 types.
    WARN_CFLAGS='' WARN_CXXFLAGS='' "$src/configure" \
      --prefix="$PREFIX" \
      --disable-static \
      --disable-pkinit \
      --without-system-verto
    make -j"$JOBS"
    make install
  )
}

build_openldap() {
  log "Building OpenLDAP $OPENLDAP_VERSION"
  local src="$SRC_DIR/openldap"
  local bld="$BUILD_DIR/openldap"

  # curl only needs LDAP client libraries, not the slapd server, backends, or
  # overlays. Cyrus SASL is disabled because this build uses curl's GSS-API path
  # through MIT Kerberos instead.
  rm -rf "$bld"
  mkdir -p "$bld"
  (
    cd "$src"
    if [[ ! -x ./configure ]]; then
      run_autogen_if_needed
    fi
  )
  (
    cd "$bld"
    "$src/configure" \
      --prefix="$PREFIX" \
      --disable-slapd \
      --disable-backends \
      --disable-overlays \
      --disable-syslog \
      --without-cyrus-sasl \
      --with-tls=openssl
    make depend
    make -j"$JOBS"
    make install
  )
}

build_curl() {
  log "Building curl $CURL_VERSION"
  # This is where the locally built dependency graph is wired into curl. The
  # explicit --enable/--with options make configure fail loudly if an expected
  # dependency cannot be found in PREFIX.
  autotools_build curl \
    --with-openssl="$PREFIX" \
    --with-nghttp2="$PREFIX" \
    --with-nghttp3="$PREFIX" \
    --with-ngtcp2="$PREFIX" \
    --with-zlib="$PREFIX" \
    --with-brotli="$PREFIX" \
    --with-zstd="$PREFIX" \
    --with-libidn2="$PREFIX" \
    --with-libpsl="$PREFIX" \
    --with-libssh="$PREFIX" \
    --enable-ares="$PREFIX" \
    --with-gssapi="$PREFIX" \
    --enable-ech \
    --enable-ldap \
    --enable-ldaps
}

main() {
  require_tools
  prepare
  printf 'Build logs: %s\n\n' "$LOG_DIR"
  run_stage "Fetching sources" fetch_sources

  # Apply source edits that are specific to this pinned dependency set.
  run_stage "Patching sources" apply_source_patches

  # Build dependency order matters: ngtcp2 needs OpenSSL/nghttp3, libidn2 needs
  # libunistring, libpsl uses libidn2, libssh can use krb5, and curl consumes
  # the full prefix.
  run_stage "Building OpenSSL" build_cached openssl "$PREFIX/lib64/libssl.so" build_openssl
  run_stage "Building zlib" build_cached zlib "$PREFIX/lib/libz.so" build_zlib
  run_stage "Building c-ares" build_cached c-ares "$PREFIX/lib/libcares.so" build_cares
  run_stage "Building Brotli" build_cached brotli "$PREFIX/lib/libbrotlidec.so" build_brotli
  run_stage "Building zstd" build_cached zstd "$PREFIX/lib/libzstd.so" build_zstd
  run_stage "Building libunistring" build_cached libunistring "$PREFIX/lib/libunistring.so" build_libunistring
  run_stage "Building libidn2" build_cached libidn2 "$PREFIX/lib/libidn2.so" build_libidn2 libunistring
  run_stage "Building libpsl" build_cached libpsl "$PREFIX/lib/libpsl.so" build_libpsl libidn2
  run_stage "Building nghttp2" build_cached nghttp2 "$PREFIX/lib/libnghttp2.so" build_nghttp2
  run_stage "Building nghttp3" build_cached nghttp3 "$PREFIX/lib/libnghttp3.so" build_nghttp3
  run_stage "Building ngtcp2" build_cached ngtcp2 "$PREFIX/lib/libngtcp2.so" build_ngtcp2 openssl nghttp3
  run_stage "Building MIT Kerberos" build_cached krb5 "$PREFIX/lib/libkrb5.so" build_krb5 openssl
  run_stage "Building libssh" build_cached libssh "$PREFIX/lib/libssh.so" build_libssh openssl krb5
  run_stage "Building OpenLDAP" build_cached openldap "$PREFIX/lib/libldap.so" build_openldap openssl
  run_stage "Building curl" build_cached curl "$PREFIX/bin/curl" build_curl \
    openssl zlib c-ares brotli zstd libidn2 libpsl nghttp2 nghttp3 ngtcp2 krb5 libssh openldap

  printf '\nBuild complete.\n'
  "$PREFIX/bin/curl" --version
  printf '\nBuilt curl: %s/bin/curl\n' "$PREFIX"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
