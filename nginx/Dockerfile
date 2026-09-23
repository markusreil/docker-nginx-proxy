# Wraps the upstream nginx-proxy image to bake in this project's conf.d snippets.
# No custom entrypoint: the upstream entrypoint is preserved (it generates
# /etc/nginx/conf.d/default.conf at runtime; the files copied below sit
# alongside it). See README.md for the reasoning.
ARG NGINX_PROXY_VERSION
FROM nginxproxy/nginx-proxy:${NGINX_PROXY_VERSION}

ARG NGINX_PROXY_VERSION
ARG BUILD_DATE=unknown
ENV BASE_IMAGE=nginxproxy/nginx-proxy
ENV NGINX_PROXY_VERSION=${NGINX_PROXY_VERSION}
ENV BUILD_DATE=${BUILD_DATE}

COPY docker/conf.d/global-upload-limit.conf /etc/nginx/conf.d/global-upload-limit.conf
COPY docker/conf.d/stub_status.conf /etc/nginx/conf.d/stub_status.conf
