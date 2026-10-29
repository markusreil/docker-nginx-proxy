FROM alpine:3.24

ARG BUILD_DATE=unknown
ENV BASE_IMAGE=alpine:3.24
ENV BUILD_DATE=${BUILD_DATE}

RUN apk add --no-cache docker-cli

ARG DOCKER_GEN_VERSION=0.17.2
ARG TARGETARCH=amd64
ADD https://github.com/nginx-proxy/docker-gen/releases/download/${DOCKER_GEN_VERSION}/docker-gen-alpine-linux-${TARGETARCH}-${DOCKER_GEN_VERSION}.tar.gz /tmp/dg.tgz
RUN tar -xzf /tmp/dg.tgz -C /usr/local/bin/ && rm /tmp/dg.tgz

COPY docker/lib.sh docker/on-change.sh docker/entrypoint.sh /scripts/
COPY docker/maxbody.tmpl /etc/docker-gen/maxbody.tmpl
RUN chmod +x /scripts/entrypoint.sh /scripts/on-change.sh

ENTRYPOINT ["/scripts/entrypoint.sh"]
