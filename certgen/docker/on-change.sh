#!/bin/sh
# Invoked by docker-gen on every rendered-set change and at least every
# -interval seconds, and once by the entrypoint for the initial generate-only
# pass. Thin wrapper around lib.sh:reconcile. Accepts an optional mode argument
# ("initial" or "full", default "full").
set -eu

. /scripts/lib.sh

reconcile "$RENDER_FILE" "${1:-full}"
