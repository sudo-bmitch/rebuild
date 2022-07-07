FROM alpine:latest

ARG REBUILD_CA
RUN if [ -n "${REBUILD_CA}" ]; then echo "${REBUILD_CA}" > /etc/ssl/certs/ca-certificates.crt; fi

RUN env; ip a; cat /etc/resolv.conf

RUN apk add \
      ca-certificates \
      curl \
      git \
      make
