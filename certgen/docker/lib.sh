#!/bin/sh
# Shared helpers for the certgen container (sourced by entrypoint.sh and
# on-change.sh).
#
# certgen manages exactly the hosts that opt in via GEN_SELF_SIGNED_CERT: one
# <host>.crt/.key pair per exact VIRTUAL_HOST value (no wildcards, no
# parent-domain sharing), plus a manifest of the currently desired hosts so a
# cert can be removed once its host stops opting in.
set -eu

: "${CERT_DAYS:=825}"
: "${CERTS_DIR:=/certs}"
: "${GEN_REMOVAL_GRACE:=30}"
: "${LOCK:=/tmp/certgen.lock}"

MANIFEST="$CERTS_DIR/.certgen.manifest"
READY="$CERTS_DIR/.certgen.ready"
RENDER_FILE="${RENDER_FILE:-/tmp/certs-desired.txt}"
LEGACY_SWEPT="$CERTS_DIR/.certgen.legacy-swept"

# _write_list <file> <newline-separated list> - overwrite <file> with the
# non-empty lines of <list> (empty list -> empty file).
_write_list() {
  : > "$1"
  if [ -n "$2" ]; then
    printf '%s\n' "$2" > "$1"
  fi
  return 0
}

# find_nginx_container - print the nginx-proxy container name, if any.
# Honors $NGINX_CONTAINER when set/non-empty; otherwise looks up containers
# by compose labels via the Docker socket (own compose project first, then
# any project). Prints nothing and returns non-zero when none is found.
find_nginx_container() {
  if [ -n "${NGINX_CONTAINER:-}" ]; then
    printf '%s\n' "$NGINX_CONTAINER"
    return 0
  fi

  project=""
  if id=$(hostname 2>/dev/null); then
    project=$(docker inspect --format '{{ index .Config.Labels "com.docker.compose.project" }}' "$id" 2>/dev/null || true)
  fi

  name=""
  if [ -n "$project" ]; then
    name=$(docker ps --filter "label=com.docker.compose.project=$project" --filter "label=com.docker.compose.service=nginx" --format '{{.Names}}' 2>/dev/null | head -n 1 || true)
  fi

  if [ -z "$name" ]; then
    name=$(docker ps --filter "label=com.docker.compose.service=nginx" --format '{{.Names}}' 2>/dev/null | head -n 1 || true)
  fi

  if [ -z "$name" ]; then
    return 1
  fi

  printf '%s\n' "$name"
  return 0
}

# reload_nginx - force nginx-proxy to re-render its config and reload so it
# picks up newly generated (or staged-away) certs. Returns non-zero when the
# nginx container cannot be found or the re-render/reload fails.
reload_nginx() {
  target=$(find_nginx_container || true)
  if [ -z "$target" ]; then
    echo "WARNING: nginx container not found, skipping reload" >&2
    return 1
  fi
  if ! docker exec "$target" sh -c \
    '/app/docker-entrypoint.sh /usr/local/bin/docker-gen /app/nginx.tmpl /etc/nginx/conf.d/default.conf; nginx -s reload'; then
    echo "WARNING: failed to re-render/reload nginx-proxy" >&2
    return 1
  fi
  return 0
}

# gen_cert_host <host> - idempotently create an exact self-signed cert for
# <host> as <CERTS_DIR>/<host>.{crt,key} (CN=<host>, SAN DNS:<host>, no
# wildcard). Returns 0 if the cert was created, 1 if the pair already existed
# or generation failed. Failure is checked explicitly (not via `set -e`,
# which is suppressed when the caller invokes this from an `if`).
gen_cert_host() {
  host="$1"
  key="$CERTS_DIR/$host.key"
  crt="$CERTS_DIR/$host.crt"

  if [ -f "$key" ] && [ -f "$crt" ]; then
    return 1
  fi

  echo "Generating self-signed cert for $host ($CERT_DAYS days)..."
  if ! openssl req -x509 -newkey rsa:2048 -sha256 -days "$CERT_DAYS" -nodes \
       -keyout "$key" -out "$crt" -subj "/CN=$host" \
       -addext "subjectAltName=DNS:$host"; then
    echo "ERROR: openssl failed for $host" >&2
    rm -f "$key" "$crt"
    return 1
  fi
  chmod 600 "$key" || return 1
  chmod 644 "$crt" || return 1
  echo "Done: $crt"
  return 0
}

# read_desired <file> - validate a docker-gen render and print the desired
# host set (one per line, unique, sorted). Returns non-zero on a partial or
# empty render: missing sentinel, or a non-integer/non-positive
# containers-seen count. Nothing is printed when validation fails.
read_desired() {
  file="$1"
  [ -f "$file" ] || return 1

  first=$(sed -n '1p' "$file")
  [ "$first" = "# certgen-desired v1" ] || return 1

  seen=$(sed -n 's/^# containers-seen \([0-9][0-9]*\)$/\1/p' "$file" | head -n 1)
  [ -n "$seen" ] || return 1
  [ "$seen" -gt 0 ] 2>/dev/null || return 1

  sed -e '/^#/d' -e '/^[[:space:]]*$/d' "$file" | sort -u
}

# _is_desired <host> <newline-separated desired list> - internal helper.
# Uses grep -e so a leading-dash host is treated as a literal, not an option.
_is_desired() {
  [ -n "$2" ] || return 1
  printf '%s\n' "$2" | grep -qxF -e "$1"
}

# legacy_sweep - one-time migration away from the old wildcard/default certs.
# Self-guarded by the $LEGACY_SWEPT marker and independent of the render: it
# always drops default.crt/.key, then removes every self-signed wildcard cert
# (subject CN `*.…` AND issuer == subject) together with its .key. Under the
# exact-only design no wildcard is ever desired, so this is safe. CA-signed
# (Let's Encrypt) and non-wildcard certs are never touched.
legacy_sweep() {
  [ -f "$LEGACY_SWEPT" ] && return 0

  rm -f "$CERTS_DIR/default.crt" "$CERTS_DIR/default.key"

  for crt in "$CERTS_DIR"/*.crt; do
    [ -f "$crt" ] || continue
    base=$(basename "$crt" .crt)

    subj_full=$(openssl x509 -in "$crt" -noout -subject 2>/dev/null | sed 's/^subject=//') || continue
    iss_full=$(openssl x509 -in "$crt" -noout -issuer 2>/dev/null | sed 's/^issuer=//') || continue
    [ "$subj_full" = "$iss_full" ] || continue

    cn=$(printf '%s\n' "$subj_full" | sed -n 's/.*CN[[:space:]]*=[[:space:]]*//p')
    case "$cn" in
      \*.*) ;;
      *) continue ;;
    esac

    echo "Sweeping legacy wildcard cert: $base"
    rm -f "$CERTS_DIR/$base.crt" "$CERTS_DIR/$base.key"
  done

  touch "$LEGACY_SWEPT"
  return 0
}

# reconcile <render_file> <mode> - bring certs in line with the desired host
# set. mode=initial only ever generates and merges the manifest (never shrinks
# it), so a restart cannot wipe certs before downstream containers have
# started. mode=full also handles removals, gated by GEN_REMOVAL_GRACE and
# atomic staging so nginx is reloaded before the staged files are discarded.
reconcile() {
  render_file="$1"
  mode="$2"

  if ! desired=$(read_desired "$render_file"); then
    echo "WARNING: invalid or empty render ($render_file); no changes" >&2
    return 0
  fi

  desired_file=$(mktemp)
  _write_list "$desired_file" "$desired"

  generated=0
  while IFS= read -r host; do
    [ -n "$host" ] || continue
    if gen_cert_host "$host"; then
      generated=$((generated + 1))
    fi
  done < "$desired_file"

  staged=0
  if [ "$mode" = "full" ] && [ -f "$MANIFEST" ]; then
    stale_file=$(mktemp)
    # Subtract the desired set from the manifest. grep -f with an empty pattern
    # file matches every line, so an empty desired set is handled explicitly.
    if [ -s "$desired_file" ]; then
      grep -vxF -f "$desired_file" "$MANIFEST" > "$stale_file" 2>/dev/null || true
    else
      cp "$MANIFEST" "$stale_file"
    fi

    if [ -s "$stale_file" ]; then
      sleep "$GEN_REMOVAL_GRACE"
      if desired2=$(read_desired "$render_file"); then
        desired="$desired2"
        _write_list "$desired_file" "$desired"
        if [ -s "$desired_file" ]; then
          remaining=$(mktemp)
          grep -vxF -f "$desired_file" "$stale_file" > "$remaining" 2>/dev/null || true
          mv -f "$remaining" "$stale_file"
        fi

        # Re-admitted during the grace window: generate any newly-desired host
        # that still lacks a pair so it is served promptly.
        while IFS= read -r host; do
          [ -n "$host" ] || continue
          if gen_cert_host "$host"; then
            generated=$((generated + 1))
          fi
        done < "$desired_file"

        # Line-by-line staging so a host with spaces/globs is never word-split
        # or glob-expanded, and `staged` survives the loop.
        while IFS= read -r host; do
          [ -n "$host" ] || continue
          moved=0
          if [ -f "$CERTS_DIR/$host.crt" ]; then
            if mv -f "$CERTS_DIR/$host.crt" "$CERTS_DIR/$host.crt.gone" 2>/dev/null; then
              moved=1
            fi
          fi
          if [ -f "$CERTS_DIR/$host.key" ]; then
            if mv -f "$CERTS_DIR/$host.key" "$CERTS_DIR/$host.key.gone" 2>/dev/null; then
              moved=1
            fi
          fi
          if [ "$moved" -eq 1 ]; then
            echo "Staging removal of cert for $host (no longer opted in)"
            staged=$((staged + 1))
          fi
        done < "$stale_file"
      else
        echo "WARNING: render became invalid during grace period; skipping removals" >&2
      fi
    fi
    rm -f "$stale_file"
  fi

  # Manifest: full prunes to the desired set; initial only ever grows (union
  # with the previous manifest) so startup-generated certs stay tracked.
  manifest_tmp="$MANIFEST.tmp.$$"
  if [ "$mode" = "full" ]; then
    _write_list "$manifest_tmp" "$desired"
  elif [ -f "$MANIFEST" ]; then
    cat "$MANIFEST" "$desired_file" | sort -u | sed '/^[[:space:]]*$/d' > "$manifest_tmp"
  else
    _write_list "$manifest_tmp" "$desired"
  fi
  mv -f "$manifest_tmp" "$MANIFEST"

  touch "$READY"

  had_gone=0
  if ls "$CERTS_DIR"/*.gone >/dev/null 2>&1; then
    had_gone=1
  fi
  if [ "$generated" -gt 0 ] || [ "$staged" -gt 0 ] || [ "$had_gone" -eq 1 ]; then
    if reload_nginx; then
      rm -f "$CERTS_DIR"/*.gone
    else
      echo "WARNING: nginx reload failed; leaving staged .gone certs in place" >&2
    fi
  fi

  rm -f "$desired_file"
  return 0
}
