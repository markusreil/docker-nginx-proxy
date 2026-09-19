#!/bin/sh
# Invoked by docker-gen whenever the rendered output of
# /etc/docker-gen/certs.tmpl changes (i.e. the set of missing parent-domain
# certs changed). Ensures every listed cert exists, then forces nginx-proxy
# to re-render its config so it picks up the new certs (nginx-proxy only
# re-renders on container network connect/disconnect events, not on cert
# file changes).
set -eu

. /scripts/lib.sh

generated=0

# Base domain + default cert always ensured (idempotent).
gen_cert "$BASE_DOMAIN" && generated=1
ensure_default && generated=1

# Every parent domain without a cert, as rendered by docker-gen.
while IFS= read -r domain; do
  [ -n "$domain" ] || continue
  gen_cert "$domain" && generated=1
done < /tmp/certs-needed.txt

if [ "$generated" -eq 1 ]; then
  echo "Cert(s) generated; re-rendering nginx-proxy config..."
  docker exec "web-proxy-nginx-1" sh -c \
    '/app/docker-entrypoint.sh /usr/local/bin/docker-gen /app/nginx.tmpl /etc/nginx/conf.d/default.conf; nginx -s reload' \
    || echo "WARNING: failed to re-render/reload nginx-proxy" >&2
else
  echo "No new certs generated"
fi
