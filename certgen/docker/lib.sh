#!/bin/sh
# Shared helpers for the certgen container (sourced by entrypoint.sh and
# on-change.sh).
set -eu

: "${BASE_DOMAIN:=localhost}"
: "${CERT_DAYS:=825}"
: "${CERTS_DIR:=/certs}"

# gen_cert <domain> - idempotently create a self-signed wildcard cert for
# <domain> as <CERTS_DIR>/<domain>.{crt,key} (CN=*.<domain>,
# SANs: <domain>, *.<domain>).
# Returns 0 if the cert was created, 1 if it already existed.
gen_cert() {
  domain="$1"
  key="$CERTS_DIR/$domain.key"
  crt="$CERTS_DIR/$domain.crt"

  if [ -f "$key" ] && [ -f "$crt" ]; then
    echo "Cert already exists, skipping: $crt"
    return 1
  fi

  echo "Generating wildcard cert for $domain ($CERT_DAYS days)..."
  CONFIG=$(mktemp)
  cat > "$CONFIG" <<EOF
[req]
distinguished_name = req_distinguished_name
req_extensions = v3_req
prompt = no

[req_distinguished_name]
CN = *.$domain

[v3_req]
basicConstraints = CA:FALSE
keyUsage = digitalSignature, keyEncipherment
extendedKeyUsage = serverAuth
subjectAltName = @alt_names

[alt_names]
DNS.1 = $domain
DNS.2 = *.$domain
EOF

  openssl req -x509 -newkey rsa:2048 \
    -sha256 -days "$CERT_DAYS" -nodes \
    -keyout "$key" -out "$crt" \
    -config "$CONFIG" -extensions v3_req

  rm -f "$CONFIG"
  chmod 600 "$key"
  chmod 644 "$crt"
  echo "Done: $crt (CN=*.$domain)"
  return 0
}

# ensure_default - make sure nginx-proxy's fallback cert exists
# (default.crt/.key) as a copy of the base DOMAIN cert.
# Returns 0 if the default cert was (re)created, 1 if it already existed.
ensure_default() {
  default_key="$CERTS_DIR/default.key"
  default_crt="$CERTS_DIR/default.crt"

  if [ -f "$default_key" ] && [ -f "$default_crt" ]; then
    echo "Default cert already exists, skipping"
    return 1
  fi

  gen_cert "$BASE_DOMAIN" || true
  cp "$CERTS_DIR/$BASE_DOMAIN.crt" "$default_crt"
  cp "$CERTS_DIR/$BASE_DOMAIN.key" "$default_key"
  chmod 600 "$default_key"
  chmod 644 "$default_crt"
  echo "Done default cert: $default_crt"
  return 0
}
