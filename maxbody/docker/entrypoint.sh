#!/bin/sh
# maxbody: writes one /vhostd/<host> file per downstream container that sets
# NGINX_MAX_BODY_SIZE, containing `client_max_body_size <size>;`. Only
# manifest-tracked files are managed, so manual vhost.d entries are safe.
set -eu

. /scripts/lib.sh

mkdir -p "$VHOSTD_DIR"

docker-gen /etc/docker-gen/maxbody.tmpl "$RENDER_FILE" 2>/dev/null || true

flock "$LOCK" /scripts/on-change.sh || true
touch "$VHOSTD_DIR/.maxbody.ready"

exec docker-gen -watch -interval 30 -wait 100ms:500ms \
  -notify "flock $LOCK /scripts/on-change.sh" \
  /etc/docker-gen/maxbody.tmpl "$RENDER_FILE"
