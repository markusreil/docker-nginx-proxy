#!/bin/sh
# Shared helpers for the maxbody container (sourced by entrypoint.sh and
# on-change.sh). maxbody renders one /vhostd/<host> file per opted-in
# VIRTUAL_HOST containing `client_max_body_size <size>;`, and removes files
# whose host stopped opting in. Only manifest-tracked files are ever removed,
# so foreign vhost.d entries (manual files, <host>_location) are untouched.
set -eu

: "${VHOSTD_DIR:=/vhostd}"
: "${LOCK:=/tmp/maxbody.lock}"

RENDER_FILE="${RENDER_FILE:-/tmp/maxbody-desired.txt}"

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

# read_desired <file> - validate a docker-gen render and print the desired
# host/size pairs (one `host size` per line, sorted by host). Invalid entries
# are logged as warnings from their `# invalid` comment lines. Returns
# non-zero on a partial or empty render (missing sentinel, non-positive
# containers-seen count).
read_desired() {
  file="$1"
  [ -f "$file" ] || return 1

  first=$(sed -n '1p' "$file")
  [ "$first" = "# maxbody-desired v1" ] || return 1

  seen=$(sed -n 's/^# containers-seen \([0-9][0-9]*\)$/\1/p' "$file" | head -n 1)
  [ -n "$seen" ] || return 1
  [ "$seen" -gt 0 ] 2>/dev/null || return 1

  grep '^# invalid ' "$file" 2>/dev/null | while IFS= read -r line; do
    echo "WARNING: ignoring invalid entry ($line)" >&2
  done

  sed -e '/^#/d' -e '/^[[:space:]]*$/d' "$file" | sort -u
}

# reconcile <render_file> - bring vhost.d files in line with the desired
# host/size set. Writes a file only when its content changed; removes only
# manifest-tracked files whose host is no longer desired.
reconcile() {
  render_file="$1"
  manifest="$VHOSTD_DIR/.maxbody.manifest"
  ready="$VHOSTD_DIR/.maxbody.ready"

  if ! desired=$(read_desired "$render_file"); then
    echo "WARNING: invalid or empty render ($render_file); no changes" >&2
    return 0
  fi

  desired_file=$(mktemp)
  if [ -n "$desired" ]; then
    printf '%s\n' "$desired" > "$desired_file"
  else
    : > "$desired_file"
  fi

  changed=0
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    host=${line%% *}
    size=${line#* }
    [ -n "$host" ] && [ -n "$size" ] && [ "$size" != "$line" ] || continue
    want="client_max_body_size $size;"
    if [ -f "$VHOSTD_DIR/$host" ] && [ "$(cat "$VHOSTD_DIR/$host")" = "$want" ]; then
      continue
    fi
    printf '%s\n' "$want" > "$VHOSTD_DIR/$host"
    echo "Set upload limit for $host: $size"
    changed=$((changed + 1))
  done < "$desired_file"

  if [ -f "$manifest" ]; then
    manifest_hosts=$(cut -d' ' -f1 "$manifest" | sort -u)
    desired_hosts=$(cut -d' ' -f1 "$desired_file" | sed '/^[[:space:]]*$/d' | sort -u)
    stale_file=$(mktemp)
    if [ -n "$desired_hosts" ]; then
      tmp_desired=$(mktemp)
      printf '%s\n' "$desired_hosts" > "$tmp_desired"
      printf '%s\n' "$manifest_hosts" | grep -vxF -f "$tmp_desired" > "$stale_file" 2>/dev/null || true
      rm -f "$tmp_desired"
    else
      printf '%s\n' "$manifest_hosts" > "$stale_file"
    fi
    while IFS= read -r host; do
      [ -n "$host" ] || continue
      case "$host" in
        *[!A-Za-z0-9.-]* | "" ) continue ;;
      esac
      if [ -f "$VHOSTD_DIR/$host" ]; then
        rm -f "$VHOSTD_DIR/$host"
        echo "Removed upload limit for $host (no longer opted in)"
        changed=$((changed + 1))
      fi
    done < "$stale_file"
    rm -f "$stale_file"
  fi

  manifest_tmp="$manifest.tmp.$$"
  if [ -s "$desired_file" ]; then
    sort -u "$desired_file" > "$manifest_tmp"
  else
    : > "$manifest_tmp"
  fi
  mv -f "$manifest_tmp" "$manifest"

  touch "$ready"

  if [ "$changed" -gt 0 ]; then
    reload_nginx || echo "WARNING: nginx reload failed; files already updated" >&2
  fi

  rm -f "$desired_file"
  return 0
}
