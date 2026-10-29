#!/bin/sh
# Invoked by docker-gen on every rendered-set change and at least every
# -interval seconds, and once by the entrypoint for the first pass.
set -eu

. /scripts/lib.sh

reconcile "$RENDER_FILE"
