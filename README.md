# BYO curl build with OpenSSL 4.1, HTTP/2, and HTTP/3

This directory contains scripts to build a custom curl from pinned upstream Git
tags and a libunistring release archive, install it into a local prefix, and
optionally package that prefix into a Docker runtime image.

The resulting curl is built with OpenSSL 4.1, ECH/HTTPS RR, HTTP/2 via nghttp2,
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
  gengetopt git gperf libtool make perl pkg-config python3 byacc
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
dependency cache keys, installation prefix, curl version stamp/date, and the
contents of `build-curl.sh` (including comments). An unchanged rerun reuses
those components and avoids fetching an already available requested Git ref
or libunistring release archive. The
default release date changes daily, so curl itself rebuilds on a later date.
Set a fixed `CURL_RELEASE_DATE` to keep that metadata stable. Compiler/tool
versions and arbitrary source edits are not tracked; use a fresh `WORK_DIR`
and prefix when changing toolchains or diagnosing an upgrade with stale
generated files.

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

The script checks the exact curl and libcurl version stamps, reported dependency
versions, and runtime library linkage. Required features and protocols are
checked separately as complete entries in both `curl-config` and `curl --version`.
Network checks cover HTTP/1.1, HTTP/2, HTTP/3, the c-ares DNS server override,
gzip/Brotli negotiation, each of the deflate/gzip/br/zstd Accept-Encoding tokens,
ECH and TLS 1.3 handshake diagnostics, HSTS, Alt-Svc, LDAPS, FTP, SFTP, SCP, and WSS.
The compression advertisement check does not test zstd response decompression.

For local-only checks without public network requests:

```bash
SKIP_NETWORK=1 ./test-curl.sh
```

Version expectations come from `$PREFIX_DIR/share/byo-curl/build-manifest`
when that file exists; `BUILD_MANIFEST` can select another manifest. The build
script in this repository does not generate one, so the test normally reads
defaults from `build-curl.sh` (or the file selected by `BUILD_CONFIG`). A manifest
uses plain `NAME=value` lines for `CURL_VERSION`, `CURL_BUILD_SUFFIX`, and the
checked dependency versions, using the same names and tag formats as the build
script. An incomplete manifest fails the version check.

When building with version or suffix overrides and no matching manifest, use
`CHECK_PINNED_VERSIONS=0 ./test-curl.sh` to skip version comparisons. Other
checks still run. Environment overrides used for the build are not recorded
by this repository's build script.

For a custom install prefix, supply all three paths; `--prefix` alone changes
linkage and manifest expectations, not the selected executables:

```bash
./test-curl.sh --curl-bin "$PWD/out/prefix/bin/curl" \
  --curl-config "$PWD/out/prefix/bin/curl-config" --prefix "$PWD/out/prefix"
```

Run `./test-curl.sh --help` for command-line options and common environment
controls. `TIMEOUT` defaults to 20 seconds per request; the WebSocket check
uses a fixed five-second timeout. `SKIP_LDAP=1` skips just the LDAPS query.

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

Set an optional endpoint to an empty string (for example, `WS_TEST_URL=`) to
skip that protocol check. SSH smoke tests use `--insecure` and therefore do
not verify the server host key.

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
* ECH: result 'succeeded' (...
* SSL connection using TLSv1.3 / ...
```

The automated suite checks these verbose handshake markers and discards the
response body. In this manual trace request, the body can also report:

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

The default curl version stamp is `8.23.0-i81b4u`, and the release date defaults
to the build date. The numeric version comes from the selected curl source.
Override the suffix and date like this:

```bash
CURL_BUILD_SUFFIX=i81b4u CURL_RELEASE_DATE=2026-10-23 ./build-curl.sh
```

## Docker image

The Docker build context always packages `curl-build/prefix/`. If you override
`WORK_DIR` or `PREFIX`, copy the completed prefix there before packaging;
`CURL_BIN` only selects the binary used to derive the image tag. Build on a
host whose architecture and system libraries are compatible with Ubuntu 26.04.
Run `build-docker-image.sh` from this repository directory.

The image relocates the prefix to `/opt/byo-curl` and sets `LD_LIBRARY_PATH`
and `OPENSSL_MODULES` for that location. It installs the smoke test and a copy
of `build-curl.sh` for default-version metadata; it does not execute the build
script. The linkage test accepts the image's library-path setting when the
binary still contains the original host RUNPATH.

For a ready-to-run image, use the [published Docker Hub image](https://hub.docker.com/r/i81b4u/byo-curl).

After `./build-curl.sh` has completed, build the runtime image:

```bash
./build-docker-image.sh
```

The helper tags the image with the curl version and `latest`, for example:

```text
byo-curl:8.23.0-i81b4u
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

Try a TLS 1.3 connection with the MLKEM1024 group on www.google.com
(requires the endpoint to support that group):

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
  --silent --head --tlsv1.3 --curves X25519MLKEM768 --http3-only \
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

To change the Docker image name:

```bash
IMAGE_NAME=my-curl ./build-docker-image.sh
```

## Notes

- OpenLDAP `OPENLDAP_REL_ENG_2_7_2` already uses public ASN.1 accessors. For
older version overrides such as 2.6.13, the build script replaces direct CN
structure access with `ASN1_STRING_get0_data()` and `ASN1_STRING_length()`.
These callers only read the certificate data; the patch also upgrades sources
previously patched with `ASN1_STRING_data()`.

- libunistring is intentionally downloaded from the official GNU release archive
rather than cloned from Git. Its Git checkout requires a separate gnulib fetch,
which has caused timeouts and incomplete checkouts. The archive contains the
generated configure and gnulib files, so the build avoids that extra network
dependency and still builds only the library/header subtree; `texinfo` is not
required.

- MIT Kerberos is built from the `krb5-1.22.2-final` git tag. curl is configured
with `--with-gssapi`, which enables GSS-API, Kerberos, and SPNEGO support.
The smoke test verifies the build artifacts and runtime linkage for this support
but leaves live realm authentication to the deployment environment.

- c-ares is built from the `v1.34.9` git tag. curl is configured with
`--enable-ares`, so `AsynchDNS` comes from c-ares instead of the POSIX threaded
resolver. The smoke test exercises this at runtime with curl's `--dns-servers`
option against Cloudflare DNS by default.

- RTMP/librtmp is intentionally not included. curl 8.20.0 removed RTMP support, so
building librtmp would not make this curl support RTMP.

## Expected output

A successful build should report features similar to:

```text
curl 8.23.0-i81b4u ... OpenSSL/4.1.0 ... c-ares/1.34.9 ... nghttp2/1.70.0 ngtcp2/1.25.0 nghttp3/1.18.0 ...
Features: alt-svc AsynchDNS brotli ECH GSS-API HSTS HTTP2 HTTP3 HTTPS-proxy HTTPSRR IDN IPv6 Kerberos Largefile libz PSL SPNEGO SSL threadsafe UnixSockets zstd
```
