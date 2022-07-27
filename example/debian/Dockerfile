FROM debian:latest

# ARG REBUILD_CA
# RUN if [ -n "${REBUILD_CA}" ]; then echo "${REBUILD_CA}" > /etc/ssl/certs/ca-certificates.crt; fi
COPY --from=rebuilder/rebuilder ./ca.pem /etc/ssl/certs/ca-certificates.crt

ARG SOURCE_DATE_EPOC
ARG DEBIAN_FRONTEND=noninteractive
RUN apt-get update -o Acquire::Check-Valid-Until=false \
 && apt-get install -y \
      ca-certificates \
      curl \
      git \
      make \
 && rm -rf /var/log/* /var/cache/* /var/lib/apt/lists/*
