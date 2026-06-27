#!/usr/bin/env bash
set -Eeuo pipefail

OPENSSL_VERSION="${OPENSSL_VERSION:-4.0.1}"
NGHTTP2_VERSION="${NGHTTP2_VERSION:-v1.69.0}"
NGHTTP3_VERSION="${NGHTTP3_VERSION:-v1.17.0}"
NGTCP2_VERSION="${NGTCP2_VERSION:-v1.23.0}"
CURL_VERSION="${CURL_VERSION:-curl-8_21_0}"
ZLIB_VERSION="${ZLIB_VERSION:-v1.3.2}"
BROTLI_VERSION="${BROTLI_VERSION:-v1.2.0}"
ZSTD_VERSION="${ZSTD_VERSION:-v1.5.7}"
LIBUNISTRING_VERSION="${LIBUNISTRING_VERSION:-v1.4.2}"
LIBIDN2_VERSION="${LIBIDN2_VERSION:-v2.3.8}"
LIBPSL_VERSION="${LIBPSL_VERSION:-0.22.0}"
LIBSSH_VERSION="${LIBSSH_VERSION:-libssh-0.12.0}"
OPENLDAP_VERSION="${OPENLDAP_VERSION:-OPENLDAP_REL_ENG_2_6_13}"
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
    git -C "$dst" fetch --depth 1 origin "$branch"
    git -C "$dst" checkout -q FETCH_HEAD
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
  local commands=(
    autoconf automake autoreconf cmake gengetopt git gperf libtoolize make
    date perl pkg-config sed autopoint
  )
  for cmd in "${commands[@]}"; do
    need_cmd "$cmd"
  done
}

prepare() {
  mkdir -p "$SRC_DIR" "$BUILD_DIR" "$PREFIX"
}

# Fetch all sources from git. Some projects need submodules because their build
# system or test-disabled library build expects bundled helper files.
fetch_sources() {
  clone_repo openssl "openssl-$OPENSSL_VERSION" https://github.com/openssl/openssl.git
  clone_repo nghttp2 "$NGHTTP2_VERSION" https://github.com/nghttp2/nghttp2.git
  clone_repo nghttp3 "$NGHTTP3_VERSION" https://github.com/ngtcp2/nghttp3.git yes
  clone_repo ngtcp2 "$NGTCP2_VERSION" https://github.com/ngtcp2/ngtcp2.git yes
  clone_repo zlib "$ZLIB_VERSION" https://github.com/madler/zlib.git
  clone_repo brotli "$BROTLI_VERSION" https://github.com/google/brotli.git
  clone_repo zstd "$ZSTD_VERSION" https://github.com/facebook/zstd.git
  clone_repo libunistring "$LIBUNISTRING_VERSION" https://https.git.savannah.gnu.org/git/libunistring.git/
  clone_repo libidn2 "$LIBIDN2_VERSION" https://github.com/libidn/libidn2.git
  clone_repo libpsl "$LIBPSL_VERSION" https://github.com/rockdaboot/libpsl.git yes
  clone_repo libssh "$LIBSSH_VERSION" https://git.libssh.org/projects/libssh.git
  clone_repo openldap "$OPENLDAP_VERSION" https://github.com/openldap/openldap.git
  clone_repo curl "$CURL_VERSION" https://github.com/curl/curl.git
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

# The curl git tag reports itself as 8.20.0-DEV and "[unreleased]". Stamp the
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

build_openssl() {
  log "Building OpenSSL $OPENSSL_VERSION"
  (
    cd "$SRC_DIR/openssl"
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
    git clean -xfd
    ./configure --prefix="$PREFIX"
    make -j"$JOBS"
    make install
  )
}

build_brotli() {
  log "Building Brotli $BROTLI_VERSION"
  cmake_build brotli \
    -DBUILD_SHARED_LIBS=ON \
    -DBROTLI_DISABLE_TESTS=ON
}

build_zstd() {
  log "Building zstd $ZSTD_VERSION"
  make -C "$SRC_DIR/zstd/lib" -j"$JOBS" PREFIX="$PREFIX" install
}

# The libunistring release tarball includes generated gnulib/doc files. The git
# checkout does not, so pull gnulib and build only the library/header subtree;
# curl/libidn2 do not need libunistring's generated Texinfo documentation.
build_libunistring() {
  log "Building libunistring $LIBUNISTRING_VERSION"
  local src="$SRC_DIR/libunistring"
  local bld="$BUILD_DIR/libunistring"

  (
    cd "$src"
    if [[ -x ./gitsub.sh && ! -d gnulib ]]; then
      sed -i 's#git://git.savannah.gnu.org/gnulib.git#https://git.savannah.gnu.org/git/gnulib.git#' .gitmodules
      ./gitsub.sh pull --depth 1 gnulib
    fi
  )
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
    "$src/configure" --prefix="$PREFIX" --disable-static
    make -C lib -j"$JOBS"
    make -C lib install
  )
}

build_libidn2() {
  log "Building libidn2 $LIBIDN2_VERSION"
  autotools_build libidn2 \
    --disable-doc \
    --disable-nls \
    --with-libunistring-prefix="$PREFIX"
}

build_libpsl() {
  log "Building libpsl $LIBPSL_VERSION"
  autotools_build libpsl \
    --disable-gtk-doc \
    --disable-man \
    --disable-runtime \
    --enable-builtin=libidn2 \
    --with-libidn2
}

build_nghttp2() {
  log "Building nghttp2 $NGHTTP2_VERSION"
  cmake_build nghttp2 \
    -DBUILD_SHARED_LIBS=ON \
    -DENABLE_LIB_ONLY=ON \
    -DENABLE_DOC=OFF
}

build_nghttp3() {
  log "Building nghttp3 $NGHTTP3_VERSION"
  cmake_build nghttp3 \
    -DBUILD_SHARED_LIBS=ON \
    -DENABLE_LIB_ONLY=ON \
    -DENABLE_DOC=OFF
}

build_ngtcp2() {
  log "Building ngtcp2 $NGTCP2_VERSION"
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
  cmake_build libssh \
    -DBUILD_SHARED_LIBS=ON \
    -DWITH_EXAMPLES=OFF \
    -DWITH_TESTING=OFF \
    -DWITH_GSSAPI=OFF \
    -DOPENSSL_ROOT_DIR="$PREFIX"
}

build_openldap() {
  log "Building OpenLDAP $OPENLDAP_VERSION"
  local src="$SRC_DIR/openldap"
  local bld="$BUILD_DIR/openldap"

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
    --enable-ldap \
    --enable-ldaps
}

main() {
  require_tools
  prepare
  fetch_sources

  # Apply source edits that are specific to this pinned dependency set.
  patch_openldap
  patch_curl_version

  # Build dependency order matters: ngtcp2 needs OpenSSL/nghttp3, libidn2 needs
  # libunistring, libpsl uses libidn2, and curl consumes the full prefix.
  build_openssl
  build_zlib
  build_brotli
  build_zstd
  build_libunistring
  build_libidn2
  build_libpsl
  build_nghttp2
  build_nghttp3
  build_ngtcp2
  build_libssh
  build_openldap
  build_curl

  log "Done"
  "$PREFIX/bin/curl" --version
  printf '\nBuilt curl: %s/bin/curl\n' "$PREFIX"
}

main "$@"
