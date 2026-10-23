FROM ubuntu:26.04

# Refresh base packages to pick up available updates before installing runtime
# tools, CA certificates, and the host-built Kerberos library dependency.
RUN apt-get update \
  && DEBIAN_FRONTEND=noninteractive apt-get upgrade -y \
  # Host-built MIT Kerberos may link libkrb5support against libkeyutils.
  && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends bash binutils ca-certificates libkeyutils1 \
  # Remove Pebble and its data if present in the base image; this curl runtime
  # does not use them.
  && rm -f /usr/bin/pebble \
  && rm -rf /var/lib/pebble \
  && rm -rf /var/lib/apt/lists/*

# build-curl.sh installs curl and every custom dependency here on the host.
COPY curl-build/prefix/ /opt/byo-curl/
# Keep the installed smoke test self-contained.  build-curl.sh is copied only
# as fallback version metadata when no build manifest is present; it is not run.
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
