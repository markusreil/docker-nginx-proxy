#!/bin/sh
# certgen: generates exact self-signed certs for proxied containers that opt
# in via GEN_SELF_SIGNED_CERT.
#
# Startup does a one-shot render, runs the marker-gated one-time legacy sweep,
# and runs an "initial" reconcile that only ever generates and grows the
# manifest. The initial pass must never delete: downstream containers may not
# have started yet, and an empty first render would otherwise wipe every cert.
# docker-gen -watch then re-runs a "full" reconcile whenever the desired host
# set changes (container start/stop/recreate) and at least every -interval
# seconds, handling generation and removals, gated by GEN_REMOVAL_GRACE and
# atomic .gone staging so nginx is reloaded before a cert is finally discarded.
set -eu

. /scripts/lib.sh

mkdir -p "$CERTS_DIR"

# One-shot render so the initial pass sees the currently running containers.
docker-gen /etc/docker-gen/certs.tmpl "$RENDER_FILE" 2>/dev/null || true

# One-time legacy sweep; self-guarded by the .certgen.legacy-swept marker.
legacy_sweep

# Generate-only first pass; never deletes.
flock "$LOCK" /scripts/on-change.sh initial || true
touch "$READY"

exec docker-gen -watch -interval 30 -wait 100ms:500ms \
  -notify "flock $LOCK /scripts/on-change.sh full" \
  /etc/docker-gen/certs.tmpl "$RENDER_FILE"
