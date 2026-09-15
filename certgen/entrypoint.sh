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
DEFAULT_KEY="$CERTS_DIR/default.key"
DEFAULT_CRT="$CERTS_DIR/default.crt"

gen_wildcard() {
  if [ -f "$KEY_FILE" ] && [ -f "$CRT_FILE" ]; then
    echo "Cert already exists, skipping: $CRT_FILE $KEY_FILE"
    return 0
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
}

copy_if_missing() {
  src="$1"
  dst="$2"
  mode="$3"
  label="$4"
  if [ ! -f "$dst" ]; then
    cp "$src" "$dst"
    chmod "$mode" "$dst"
    echo "Copied $label: $src -> $dst"
  else
    echo "$label already exists, skipping: $dst"
  fi
}

# Ensure default cert exists as copy of $DOMAIN files (nginx-proxy fallback).
# Do not overwrite existing default.* files. Preserve perms (600 key, 644 crt).
ensure_default() {
  if [ -f "$DEFAULT_KEY" ] && [ -f "$DEFAULT_CRT" ]; then
    echo "Default cert already exists, skipping: $DEFAULT_CRT $DEFAULT_KEY"
    return 0
  fi
  copy_if_missing "$CRT_FILE" "$DEFAULT_CRT" 644 "Default crt"
  copy_if_missing "$KEY_FILE" "$DEFAULT_KEY" 600 "Default key"
  echo "Done default cert: $DEFAULT_CRT $DEFAULT_KEY"
}

main() {
  gen_wildcard
  ensure_default
}

main
