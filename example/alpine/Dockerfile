FROM alpine:latest

# ARG REBUILD_CA
# RUN if [ -n "${REBUILD_CA}" ]; then echo "${REBUILD_CA}" > /etc/ssl/certs/ca-certificates.crt; fi
COPY --from=rebuilder/rebuilder ./ca.pem /etc/ssl/certs/ca-certificates.crt

RUN apk add \
      ca-certificates \
      curl \
      git \
      make \
 && rm -rf /var/log/* /var/cache/*
