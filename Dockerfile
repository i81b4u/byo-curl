FROM ubuntu:26.04

# Refresh the base image packages before installing runtime data. This keeps the
# image from carrying fixable CVEs that were patched after the published Ubuntu
# base layer was built.
RUN apt-get update \
  && DEBIAN_FRONTEND=noninteractive apt-get upgrade -y \
  # MIT Kerberos built on Arch links libkrb5support against libkeyutils.
  && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends bash binutils ca-certificates libkeyutils1 \
  # ubuntu:26.04 currently includes /usr/bin/pebble as an unowned Go binary.
  # This curl runtime image does not use it, and scanners report vulnerabilities
  # against it independently from the OS packages, so remove the extra surface.
  && rm -f /usr/bin/pebble \
  && rm -rf /var/lib/pebble \
  && rm -rf /var/lib/apt/lists/*

# build-curl.sh installs curl and every custom dependency here on the host.
COPY curl-build/prefix/ /opt/byo-curl/
# Keep the installed smoke test self-contained.  build-curl.sh is copied only
# as version metadata for the test; it is not run in this runtime image.
COPY test-curl.sh /opt/byo-curl/bin/test-curl.sh
COPY build-curl.sh /opt/byo-curl/share/byo-curl/build-curl.sh
RUN chmod 0755 /opt/byo-curl/bin/test-curl.sh

# Prefer the custom curl and libraries. OPENSSL_MODULES is important because
# OpenSSL was built under the host prefix, then copied into /opt/byo-curl.
ENV PATH="/opt/byo-curl/bin:${PATH}"
ENV LD_LIBRARY_PATH="/opt/byo-curl/lib:/opt/byo-curl/lib64"
ENV OPENSSL_MODULES="/opt/byo-curl/lib64/ossl-modules"
ENV SSL_CERT_FILE="/etc/ssl/certs/ca-certificates.crt"
ENV SSL_CERT_DIR="/etc/ssl/certs"

# Run curl by default, while still allowing:
#   docker run --rm -it --entrypoint /bin/bash byo-curl:latest
ENTRYPOINT ["curl"]
CMD ["--version"]
