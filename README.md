# BYO curl build with OpenSSL 4 and HTTP/3

This directory contains scripts to build a custom curl from pinned upstream git
tags, install it into a local prefix, and optionally package that prefix into a
Docker runtime image.

The resulting curl is built with OpenSSL 4, HTTP/3 via ngtcp2/nghttp3, zlib,
Brotli, zstd, libidn2, libpsl, libssh, and OpenLDAP.

## Files

- `build-curl.sh` clones and builds curl plus all pinned dependencies.
- `build-docker-image.sh` packages the already-built prefix into a Docker image.
- `Dockerfile` defines the runtime image used by `build-docker-image.sh`.
- `.dockerignore` keeps the Docker context focused on `curl-build/prefix`.

## Prerequisites

On Ubuntu, the build script expects common build tooling such as:

```bash
sudo apt install autoconf automake autopoint bison cmake flex gettext \
  gengetopt git gperf libtool make perl pkg-config
```

Docker is only needed for image packaging:

```bash
sudo apt install docker.io
sudo usermod -aG docker "$USER"
```

After changing Docker group membership, start a new login session before using
Docker as your normal user.

## Build curl

Run:

```bash
./build-curl.sh
```

The script builds under `curl-build/`:

- `curl-build/src` contains git checkouts.
- `curl-build/build` contains out-of-tree build directories.
- `curl-build/prefix` contains the final installed curl and dependencies.

The resulting binary is:

```bash
./curl-build/prefix/bin/curl
```

Check it with:

```bash
./curl-build/prefix/bin/curl --version
```

## Customization

Most versions and paths can be overridden with environment variables. Examples:

```bash
CURL_BUILD_SUFFIX=mybuild ./build-curl.sh
```

```bash
WORK_DIR="$PWD/out" PREFIX="$PWD/out/prefix" ./build-curl.sh
```

The default curl version stamp is `8.20.0-i81b4u`, and the release date defaults
to the build date. Override both like this:

```bash
CURL_BUILD_SUFFIX=i81b4u CURL_RELEASE_DATE=2026-06-08 ./build-curl.sh
```

## Docker image

After `./build-curl.sh` has completed, build the runtime image:

```bash
./build-docker-image.sh
```

The helper tags the image with the curl version and `latest`, for example:

```text
byo-curl:8.20.0-i81b4u
byo-curl:latest
```

Run curl from the image:

```bash
docker run --rm byo-curl:latest --version
```

Run a MLKEM test on www.google.com:

```bash
docker run --rm byo-curl:latest \
  --silent --head --tlsv1.3 --curves MLKEM1024 \
  https://www.google.com
```

Run a HTTP/3 and MLKEM test on www.cloudflare.com:

```bash
docker run --rm byo-curl:latest \
  --silent --head --tlsv1.3 --curves X25519MLKEM768 --http3 \
  https://www.cloudflare.com
```

Start a shell inside the runtime image:

```bash
docker run --rm -it --entrypoint /bin/bash byo-curl:latest
```

To change the Docker image name:

```bash
IMAGE_NAME=my-curl ./build-docker-image.sh
```

## Notes

OpenLDAP `OPENLDAP_REL_ENG_2_6_13` needs a small source edit for OpenSSL 4
because it still dereferences opaque `ASN1_STRING` internals. The build script
applies that edit before building OpenLDAP.

The libunistring git checkout needs its `gnulib` checkout pulled before
bootstrap. The script does this and then builds only the library/header subtree,
so `texinfo` is not required.

RTMP/librtmp is intentionally not included. curl 8.20.0 removed RTMP support, so
building librtmp would not make this curl support RTMP.

## Verified output

A successful build should report features similar to:

```text
curl 8.20.0-i81b4u ... OpenSSL/4.0.0 ... ngtcp2/1.23.0 nghttp3/1.16.0 ...
Features: alt-svc AsynchDNS brotli HSTS HTTP3 HTTPS-proxy IDN IPv6 Largefile libz PSL SSL threadsafe TLS-SRP UnixSockets zstd
```
