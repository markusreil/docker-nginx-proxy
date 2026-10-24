#!/bin/sh
# bin/create-ca.sh - generate a new local CA and install it into the certs volume.
#
# Usage: bin/create-ca.sh [--cn NAME] [--days N] [--force] [--out PATH] [--out PATH]
#
# Generates a CA key/cert *inside* the certgen image (no local openssl needed)
# and writes ca.crt/ca.key into the `certs` named volume, where certgen picks
# them up to sign host certs (see certgen/README.md "Optional CA signing").
# Refuses to overwrite an existing CA unless --force is given. Nothing is ever
# written into the repo checkout: the CA public cert goes to stdout (or --out)
# so you can save it wherever your clients need it.
#
# After creating the CA, existing host certs stay as-is (self-signed) until
# their pairs are deleted from the volume; certgen then recreates them
# CA-signed on the next reconcile. New hosts are signed immediately.
#
# Environment defaults (CLI flags win):
#   CA_CN    CA subject CN (default: lan-ca)
#   CA_DAYS  CA validity in days (default: 3650)
set -eu

cd "$(dirname "$0")/.."

CN="${CA_CN:-lan-ca}"
DAYS="${CA_DAYS:-3650}"
FORCE=0
OUT=""

usage() {
  echo "Usage: $(basename "$0") [--cn NAME] [--days N] [--force] [--out PATH]" >&2
  echo "  --cn NAME   CA subject CN (default: ${CA_CN:-lan-ca})" >&2
  echo "  --days N    CA validity in days (default: ${CA_DAYS:-3650})" >&2
  echo "  --force     overwrite an existing CA in the certs volume" >&2
  echo "  --out PATH  write the CA public cert to PATH (default: stdout)" >&2
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --cn) CN="${2:?--cn needs a value}"; shift 2 ;;
    --days) DAYS="${2:?--days needs a value}"; shift 2 ;;
    --force|-f) FORCE=1; shift ;;
    --out) OUT="${2:---out needs a value}"; shift 2 ;;
    --help|-h) usage; exit 0 ;;
    *) echo "ERROR: unknown argument: $1" >&2; usage; exit 1 ;;
  esac
done

case "$CN" in
  *[!A-Za-z0-9._-]*|"") echo "ERROR: --cn must match [A-Za-z0-9._-]+" >&2; exit 1 ;;
esac
case "$DAYS" in
  *[!0-9]*|"0"*) echo "ERROR: --days must be a positive integer" >&2; exit 1 ;;
esac

compose() {
  docker compose -f docker-compose.yml -f docker-compose.lan.yml "$@"
}

if [ "$FORCE" -ne 1 ] && compose run --rm --no-deps --no-TTY --entrypoint sh certgen \
    -c 'test -e /certs/ca.crt || test -e /certs/ca.key' >/dev/null 2>&1; then
  echo "ERROR: a CA already exists in the certs volume (use --force to overwrite)" >&2
  exit 1
fi

compose run --rm --no-deps --no-TTY --build --entrypoint sh certgen -c \
  "openssl req -x509 -newkey rsa:4096 -sha256 -days '$DAYS' -nodes \
     -keyout /certs/ca.key -out /certs/ca.crt -subj '/CN=$CN' \
     -addext 'basicConstraints=critical,CA:TRUE' \
   && chmod 600 /certs/ca.key && chmod 644 /certs/ca.crt \
   && openssl x509 -in /certs/ca.crt -noout -subject -issuer -fingerprint -sha256"

# Print the CA public cert for trusting on clients (phones, browsers,
# curl --cacert). Goes to stdout unless --out PATH was given.
if [ -n "$OUT" ]; then
  compose run --rm --no-deps --no-TTY --entrypoint cat certgen /certs/ca.crt > "$OUT"
  echo "Wrote $OUT - install it as a trusted CA on your clients."
else
  compose run --rm --no-deps --no-TTY --entrypoint cat certgen /certs/ca.crt
fi

if [ "$FORCE" -eq 1 ]; then
  echo "CA replaced. Delete existing <host>.crt/.key pairs from the certs volume"
else
  echo "Delete existing <host>.crt/.key pairs from the certs volume"
fi
echo "to have them re-issued CA-signed (certgen recreates them on next reconcile)."
