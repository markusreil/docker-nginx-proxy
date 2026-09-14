#!/usr/bin/env sh
# Container entrypoint: idempotently generate self-signed wildcard cert.
# Env: DOMAIN (default local.test), CERT_DAYS (default 825). Output dir: /certs.
set -eu

DOMAIN="${DOMAIN:-local.test}"
CERT_DAYS="${CERT_DAYS:-825}"
CERTS_DIR="/certs"

mkdir -p "$CERTS_DIR"
KEY_FILE="$CERTS_DIR/$DOMAIN.key"
CRT_FILE="$CERTS_DIR/$DOMAIN.crt"

if [ -f "$KEY_FILE" ] && [ -f "$CRT_FILE" ]; then
  echo "Cert already exists, skipping: $CRT_FILE $KEY_FILE"
  exit 0
fi

# Temp openssl config so SANs work on both OpenSSL and LibreSSL (no -addext).
CONFIG=$(mktemp)
trap 'rm -f "$CONFIG"' EXIT INT TERM

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
  -sha256 -days "$CERT_DAYS" -nodes \
  -keyout "$KEY_FILE" -out "$CRT_FILE" \
  -config "$CONFIG" -extensions v3_req

chmod 600 "$KEY_FILE"
chmod 644 "$CRT_FILE"

echo "Done: $CRT_FILE (CN=*.$DOMAIN, SANs: $DOMAIN, *.$DOMAIN, $CERT_DAYS days)"
