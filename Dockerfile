FROM ubuntu:26.04

# The runtime image only needs CA certificates from the distro. All curl-related
# libraries are copied from the local custom prefix below.
RUN apt-get update \
  && apt-get install -y --no-install-recommends ca-certificates \
  && rm -rf /var/lib/apt/lists/*

# build-curl.sh installs curl and every custom dependency here on the host.
COPY curl-build/prefix/ /opt/byo-curl/

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
