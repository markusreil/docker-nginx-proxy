# Wraps the upstream acme-companion image to patch what the pinned tag lags.
# No custom entrypoint: the upstream entrypoint is preserved.
# docker-gen is replaced with the hardened image (source rebuild on a current
# Go toolchain); override DOCKER_GEN_HARDENED_TAG to pin a `<upstream>-hardened.<n>` tag.
ARG ACME_COMPANION_VERSION
ARG DOCKER_GEN_HARDENED_TAG=latest
FROM mreil/docker-gen-hardened:${DOCKER_GEN_HARDENED_TAG} AS dockergen

FROM nginxproxy/acme-companion:${ACME_COMPANION_VERSION}

ARG ACME_COMPANION_VERSION
ARG BUILD_DATE=unknown
ENV BASE_IMAGE=nginxproxy/acme-companion
ENV ACME_COMPANION_VERSION=${ACME_COMPANION_VERSION}
ENV BUILD_DATE=${BUILD_DATE}

# Patch Alpine CVEs in the upstream image at build time (e.g. brotli-libs,
# curl, openssl, openssh, bind-libs). Upstream rebuilds lag security updates.
RUN apk update && apk upgrade --no-cache && rm -rf /var/cache/apk/*

COPY --from=dockergen /usr/local/bin/docker-gen /usr/local/bin/docker-gen
