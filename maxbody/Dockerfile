# docker-gen comes from the hardened image (source rebuild on a current Go
# toolchain); override DOCKER_GEN_HARDENED_TAG to pin a `<upstream>-hardened.<n>` tag.
ARG DOCKER_GEN_HARDENED_TAG=latest
FROM mreil/docker-gen-hardened:${DOCKER_GEN_HARDENED_TAG} AS dockergen

FROM alpine:3.24

ARG BUILD_DATE=unknown
ENV BASE_IMAGE=alpine:3.24
ENV BUILD_DATE=${BUILD_DATE}

RUN apk add --no-cache docker-cli

COPY --from=dockergen /usr/local/bin/docker-gen /usr/local/bin/docker-gen

COPY docker/lib.sh docker/on-change.sh docker/entrypoint.sh /scripts/
COPY docker/maxbody.tmpl /etc/docker-gen/maxbody.tmpl
RUN chmod +x /scripts/entrypoint.sh /scripts/on-change.sh

ENTRYPOINT ["/scripts/entrypoint.sh"]
