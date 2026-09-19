FROM alpine:3.20

# openssl for cert generation, docker-cli to trigger nginx-proxy re-render
RUN apk add --no-cache openssl docker-cli

ARG DOCKER_GEN_VERSION=0.17.2
ARG TARGETARCH=amd64
ADD https://github.com/nginx-proxy/docker-gen/releases/download/${DOCKER_GEN_VERSION}/docker-gen-alpine-linux-${TARGETARCH}-${DOCKER_GEN_VERSION}.tar.gz /tmp/dg.tgz
RUN tar -xzf /tmp/dg.tgz -C /usr/local/bin/ && rm /tmp/dg.tgz

COPY docker/lib.sh docker/on-change.sh docker/entrypoint.sh /scripts/
COPY docker/certs.tmpl /etc/docker-gen/certs.tmpl
RUN chmod +x /scripts/entrypoint.sh /scripts/on-change.sh

ENTRYPOINT ["/scripts/entrypoint.sh"]
