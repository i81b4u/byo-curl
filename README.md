# BYO curl build with OpenSSL 4, HTTP/2, and HTTP/3

This directory contains scripts to build a custom curl from pinned upstream Git
tags and a libunistring release archive, install it into a local prefix, and
optionally package that prefix into a Docker runtime image.

The resulting curl is built with OpenSSL 4, ECH/HTTPS RR, HTTP/2 via nghttp2,
HTTP/3 via ngtcp2/nghttp3, c-ares, zlib, Brotli, zstd, libidn2, libpsl,
libssh, OpenLDAP, and MIT Kerberos/GSS-API.

## Files

- `build-curl.sh` fetches and builds curl plus all pinned dependencies.
- `test-curl.sh` runs post-build smoke tests against the built curl.
- `build-docker-image.sh` packages the already-built prefix into a Docker image.
- `Dockerfile` defines the runtime image used by `build-docker-image.sh`.
- `.dockerignore` keeps the Docker context focused on `curl-build/prefix`.

## Prerequisites

On Ubuntu, the build script expects common build tooling such as:

```bash
sudo apt install autoconf automake autopoint bison build-essential cmake curl flex gettext \
  gengetopt git gperf libtool make perl pkg-config byacc
```

`curl` downloads the libunistring release archive; `wget` is also supported as
a fallback.

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

- `curl-build/src` contains Git checkouts and extracted release sources.
- `curl-build/build` contains out-of-tree build directories.
- `curl-build/downloads` caches the libunistring release archive.
- `curl-build/prefix` contains the final installed curl and dependencies.
- `curl-build/state` contains cache keys for successfully completed components.
- `curl-build/logs` contains one numbered log per fetch, patch, and build stage.

### Build progress and logs

The terminal reports the current numbered stage and, when attached to a
terminal, displays a spinner. Full command output is redirected to the
corresponding file in `curl-build/logs/`, keeping normal output concise while
preserving configure and compiler diagnostics. On failure, the script reports
the affected log and prints its final 40 lines.

For example, inspect the curl build log with:

```bash
less curl-build/logs/17-building-curl.log
```

### Repeat builds

Successful components are cached by their source identity, build flags,
dependency cache keys, installation prefix, and the contents of
`build-curl.sh`. An unchanged rerun reuses those components and avoids fetching
an already available requested Git ref or libunistring release archive.

Use these controls when a rebuild or source refresh is needed:

```bash
BUILD_CACHE=0 ./build-curl.sh       # rebuild every component
REFRESH_SOURCES=1 ./build-curl.sh  # refresh Git checkouts and the archive
```

The resulting binary is:

```bash
./curl-build/prefix/bin/curl
```

Check it with:

```bash
./curl-build/prefix/bin/curl --version
```

The `Features:` line should include `ECH`, `HTTPSRR`, `GSS-API`, `Kerberos`,
and `SPNEGO`.

## Test curl

After a build, run the smoke test suite:

```bash
./test-curl.sh
```

The script checks the compiled dependency versions against `build-curl.sh`,
enabled protocols and features, runtime library linkage, HTTP/1.1, HTTP/2,
HTTP/3, c-ares DNS server override support, gzip, Brotli, zstd negotiation,
ECH, HSTS, Alt-Svc, LDAPS, FTP, SFTP, SCP, and WSS.

For local-only checks without public network requests:

```bash
SKIP_NETWORK=1 ./test-curl.sh
```

The local-only mode reports each omitted network assertion as `SKIP`, so its
summary still shows exactly which coverage was not run.

Network checks are grouped by protocol area and run concurrently by default.
`NETWORK_JOBS` limits how many groups can run at once; the default is `4` and
`NETWORK_JOBS=1` runs them serially when diagnosing a service or constrained
network. `PASS`, `FAIL`, and `SKIP` use green, red, and yellow status labels in
an interactive terminal. Output redirected to a file remains plain text.

```bash
NETWORK_JOBS=1 ./test-curl.sh
```

The smoke test confirms MIT Kerberos/GSS-API support is present, reported by
curl, and linked from `curl-build/prefix`. It does not perform a live
Kerberos/SPNEGO authentication exchange because that requires a configured
Kerberos realm, credentials, and an HTTP/FTP/SOCKS/SSH service that accepts
GSS-API or Negotiate authentication. Validate that separately in the target
Kerberos environment.

FTP, SFTP, SCP, and WSS default to public test endpoints:

- `ftp://demo:password@test.rebex.net/`
- `sftp://demo:password@test.rebex.net/`
- `scp://demo:password@test.rebex.net/readme.txt`
- `wss://echo.websocket.org/`

Override them by providing URLs:

```bash
FTP_TEST_URL=ftp://example.test/path \
SFTP_TEST_URL=sftp://user@example.test/path \
SCP_TEST_URL=scp://user@example.test/path \
WS_TEST_URL=wss://example.test/socket \
./test-curl.sh
```

## Test ECH

Cloudflare's trace endpoint reports whether SNI was encrypted. This test uses
DNS-over-HTTPS so curl can retrieve the HTTPS resource record that carries the
ECHConfigList:

```bash
./curl-build/prefix/bin/curl -v \
  --tlsv1.3 \
  --ech hard \
  --doh-url https://cloudflare-dns.com/dns-query \
  https://crypto.cloudflare.com/cdn-cgi/trace
```

A successful run includes verbose output similar to:

```text
ECH: result: status is succeeded, inner is crypto.cloudflare.com, outer is cloudflare-ech.com
```

The response body should include:

```text
sni=encrypted
```

## Customization

Most versions and paths can be overridden with environment variables. Examples:

```bash
CURL_BUILD_SUFFIX=mybuild ./build-curl.sh
```

```bash
WORK_DIR="$PWD/out" PREFIX="$PWD/out/prefix" ./build-curl.sh
```

The default curl version stamp is `8.21.0-i81b4u`, and the release date defaults
to the build date. Override both like this:

```bash
CURL_BUILD_SUFFIX=i81b4u CURL_RELEASE_DATE=2026-06-08 ./build-curl.sh
```

## Docker image

For a ready-to-run image, use the [published Docker Hub image](https://hub.docker.com/r/i81b4u/byo-curl).

After `./build-curl.sh` has completed, build the runtime image:

```bash
./build-docker-image.sh
```

The helper tags the image with the curl version and `latest`, for example:

```text
byo-curl:8.21.0-i81b4u
byo-curl:latest
```

Run curl from the image:

```bash
docker run --rm byo-curl:latest --version
```

Run the installed smoke test (the image entrypoint normally runs `curl`):

```bash
docker run --rm --entrypoint /opt/byo-curl/bin/test-curl.sh byo-curl:latest
```

For an offline metadata and linkage-only run, add `-e SKIP_NETWORK=1`.

Run a MLKEM test on www.google.com:

```bash
docker run --rm byo-curl:latest \
  --silent --head --tlsv1.3 --curves MLKEM1024 \
  https://www.google.com
```

Run an HTTP/2 test on www.cloudflare.com:

```bash
docker run --rm byo-curl:latest \
  --silent --head --http2 \
  https://www.cloudflare.com
```

Run an HTTP/3 and MLKEM test on www.cloudflare.com:

```bash
docker run --rm byo-curl:latest \
  --silent --head --tlsv1.3 --curves X25519MLKEM768 --http3 \
  https://www.cloudflare.com
```

Run an ECH test on crypto.cloudflare.com:

```bash
docker run --rm byo-curl:latest \
  --verbose --tlsv1.3 --ech hard \
  --doh-url https://cloudflare-dns.com/dns-query \
  https://crypto.cloudflare.com/cdn-cgi/trace
```

Start a shell inside the runtime image:

```bash
docker run --rm -it --entrypoint /bin/bash byo-curl:latest
```

Start smoke test script inside the runtime image:

```bash
docker run --rm --entrypoint /opt/byo-curl/bin/test-curl.sh i81b4u/byo-curl:latest
```

To change the Docker image name:

```bash
IMAGE_NAME=my-curl ./build-docker-image.sh
```

## Notes

OpenLDAP `OPENLDAP_REL_ENG_2_6_13` needs a small source edit for OpenSSL 4
because it still dereferences opaque `ASN1_STRING` internals. The build script
applies that edit before building OpenLDAP.

libunistring is intentionally downloaded from the official GNU release archive
rather than cloned from Git. Its Git checkout requires a separate gnulib fetch,
which has caused timeouts and incomplete checkouts. The archive contains the
generated configure and gnulib files, so the build avoids that extra network
dependency and still builds only the library/header subtree; `texinfo` is not
required.

MIT Kerberos is built from the `krb5-1.22.2-final` git tag. curl is configured
with `--with-gssapi`, which enables GSS-API, Kerberos, and SPNEGO support.
The smoke test verifies the build artifacts and runtime linkage for this support
but leaves live realm authentication to the deployment environment.

c-ares is built from the `v1.34.8` git tag. curl is configured with
`--enable-ares`, so `AsynchDNS` comes from c-ares instead of the POSIX threaded
resolver. The smoke test exercises this at runtime with curl's `--dns-servers`
option against Cloudflare DNS by default.

RTMP/librtmp is intentionally not included. curl 8.20.0 removed RTMP support, so
building librtmp would not make this curl support RTMP.

## Verified output

A successful build should report features similar to:

```text
curl 8.21.0-i81b4u ... OpenSSL/4.0.1 ... c-ares/1.34.8 ... nghttp2/1.69.0 ngtcp2/1.24.0 nghttp3/1.17.0 ...
Features: alt-svc AsynchDNS brotli ECH GSS-API HSTS HTTP2 HTTP3 HTTPS-proxy HTTPSRR IDN IPv6 Kerberos Largefile libz PSL SPNEGO SSL threadsafe TLS-SRP UnixSockets zstd
```
