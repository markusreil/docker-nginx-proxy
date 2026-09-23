#!/bin/sh
# compose-lan.sh — convenience wrapper for the LAN variant of this proxy cluster.
#
# Always uses the variant-neutral base plus the LAN override, so you don't have
# to remember the -f flags or the COMPOSE_FILE setting.
#
# Default (no arguments): rebuild images and recreate volumes, then start.
#   down -v drops the named volumes, so certgen regenerates the self-signed
#   certs from scratch (browser trust must be re-established).
#
# With arguments: passed straight through to docker compose, e.g.
#   ./compose-lan.sh ps
#   ./compose-lan.sh logs -f certgen
#   ./compose-lan.sh exec nginx ls /etc/nginx/certs
#   ./compose-lan.sh config
#
# Environment:
#   KEEP_VOLUMES=1   skip the volume reset on the default bring-up (keeps certs)
set -eu

cd "$(dirname "$0")"

compose() {
  docker compose -f docker-compose.yml -f docker-compose.lan.yml "$@"
}

if [ "$#" -gt 0 ]; then
  compose "$@"
  exit 0
fi

if [ "${KEEP_VOLUMES:-0}" = "1" ]; then
  compose up -d --build
else
  compose down -v --remove-orphans
  compose up -d --build
fi
