#!/usr/bin/env bash
# Generate a self-signed wildcard SSL certificate for a local domain.
# Compatible with nginx-proxy (expects ./certs/<domain>.crt + <domain>.key).
#
# Usage:
#   ./generate-wildcard-cert.sh [domain] [certs_dir] [days]
#
# Examples:
#   ./generate-wildcard-cert.sh myapp.test
#   ./generate-wildcard-cert.sh myapp.test ./certs 825
#
# Result:
#   ./certs/myapp.test.key  (private key)
#   ./certs/myapp.test.crt  (certificate valid for myapp.test + *.myapp.test)

set -euo pipefail

DOMAIN="${1:-local.test}"
CERTS_DIR="${2:-./certs}"
DAYS="${3:-825}"

if ! command -v openssl >/dev/null 2>&1; then
  echo "Error: openssl is not installed." >&2
  exit 1
fi

mkdir -p "$CERTS_DIR"

KEY_FILE="$CERTS_DIR/$DOMAIN.key"
CRT_FILE="$CERTS_DIR/$DOMAIN.crt"

if [[ -e "$KEY_FILE" || -e "$CRT_FILE" ]]; then
  echo "Error: $KEY_FILE or $CRT_FILE already exists. Remove them first to regenerate." >&2
  exit 1
fi

# Temp openssl config so SANs work on both OpenSSL and macOS LibreSSL
# (LibreSSL does not support `openssl req -addext`).
CONFIG=$(mktemp)
trap 'rm -f "$CONFIG"' EXIT

cat > "$CONFIG" <<EOF
[req]
distinguished_name = req_distinguished_name
req_extensions = v3_req
prompt = no

[req_distinguished_name]
CN = *.$DOMAIN

[v3_req]
basicConstraints = CA:FALSE
keyUsage = digitalSignature, keyEncipherment
extendedKeyUsage = serverAuth
subjectAltName = @alt_names

[alt_names]
DNS.1 = $DOMAIN
DNS.2 = *.$DOMAIN
EOF

openssl req -x509 -newkey rsa:2048 \
  -sha256 -days "$DAYS" -nodes \
  -keyout "$KEY_FILE" -out "$CRT_FILE" \
  -config "$CONFIG" -extensions v3_req

chmod 600 "$KEY_FILE"
chmod 644 "$CRT_FILE"

echo "Done:"
echo "  key:  $KEY_FILE"
echo "  cert: $CRT_FILE (CN=*.$DOMAIN, SANs: $DOMAIN, *.$DOMAIN, valid $DAYS days)"
echo ""
echo "nginx: mount this dir as /etc/nginx/certs (already done in docker-compose.yml)."
echo "Then restart: docker compose restart nginx"
echo ""
echo "Trust it locally (optional, removes browser warning):"
echo "  Linux:   sudo cp $CRT_FILE /usr/local/share/ca-certificates/$DOMAIN.crt && sudo update-ca-certificates"
echo "  macOS:   sudo security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain $CRT_FILE"
echo "  Windows: import $CRT_FILE into 'Trusted Root Certification Authorities' via certlm.msc"
