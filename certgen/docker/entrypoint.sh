#!/bin/sh
# certgen: generates self-signed wildcard certs for the local proxy.
#
# On startup it bootstraps the base DOMAIN cert + the nginx-proxy default
# cert, then runs docker-gen to watch for containers whose VIRTUAL_HOST is
# 3+ labels deep (e.g. app.sub1.localhost). For each such host it ensures a
# wildcard cert for the parent domain (sub1.localhost) exists, generating it
# on demand and triggering an nginx-proxy re-render + reload.
set -eu

. /scripts/lib.sh

# (BASE_DOMAIN, CERT_DAYS, CERTS_DIR are provided by lib.sh defaults)

# nginx-proxy container name is fixed by the compose project (name: web-proxy, service: nginx).
NGINX_CONTAINER="web-proxy-nginx-1"
export NGINX_CONTAINER

echo "Certgen starting (BASE_DOMAIN=$BASE_DOMAIN, CERT_DAYS=$CERT_DAYS)"
gen_cert "$BASE_DOMAIN" || true
ensure_default || true

echo "Watching Docker container events for multi-level VIRTUAL_HOSTs..."
exec docker-gen -watch -interval 30 -wait 100ms:500ms \
  -notify "/scripts/on-change.sh" \
  /etc/docker-gen/certs.tmpl /tmp/certs-needed.txt
