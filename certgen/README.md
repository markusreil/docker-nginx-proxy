# certgen

Sidecar that keeps exact self-signed TLS certs for the local reverse proxy. It
runs as a long-lived container: it watches Docker events and generates a cert
for each proxied container that opts in via `GEN_SELF_SIGNED_CERT`, named after
the exact `VIRTUAL_HOST` value (`app1.localhost` -> `app1.localhost.crt`/`.key`,
`CN=app1.localhost`, SAN `DNS:app1.localhost`). When a host stops opting in, its
cert is removed again after a grace period. No wildcards, no `default.crt`
fallback.

## Files

The `Dockerfile` sits at the top of `certgen/` (the compose build context is
`./certgen`); the scripts and template it copies into the image live in the
`docker/` subfolder.

| File              | Purpose                                                        |
| ----------------- | -------------------------------------------------------------- |
| `Dockerfile`      | alpine:3.24 + openssl + docker-cli + docker-gen 0.17.2 binary  |
| `docker/entrypoint.sh`   | One-shot render, legacy sweep, generate-only pass, then docker-gen watch |
| `docker/lib.sh`          | Shared helpers: `gen_cert_host`, `read_desired`, `legacy_sweep`, `reconcile`, `reload_nginx` |
| `docker/on-change.sh`    | Thin wrapper: `reconcile "$RENDER_FILE" "${1:-full}"`          |
| `docker/certs.tmpl`      | docker-gen template: desired opt-in host set + guard lines     |

## Environment variables

| Variable               | Default                  | Description                                                     |
| ---------------------- | ------------------------ | --------------------------------------------------------------- |
| `GEN_SELF_SIGNED_CERT` | *(unset)*                | **Downstream contract:** set on a proxied container to opt in. Truthy (case-insensitive): `true`, `1`, `t`. Anything else is off. |
| `CERT_DAYS`            | `825`                    | Validity of generated certs                                     |
| `GEN_REMOVAL_GRACE`    | `30`                     | Seconds to wait before deleting a cert whose host stopped opting in |
| `CERTS_DIR`            | `/certs`                 | Where certs are written (shared volume with nginx-proxy)        |
| `RENDER_FILE`          | `/tmp/certs-desired.txt` | Where docker-gen writes the desired host set                    |
| `LOCK`                 | `/tmp/certgen.lock`      | flock file serialising reconciles                               |
| `NGINX_CONTAINER`      | *(auto)*                 | Override the nginx container lookup for reloads                 |

## How it works

1. `entrypoint.sh` sources `lib.sh`, then runs a one-shot
   `docker-gen /etc/docker-gen/certs.tmpl "$RENDER_FILE"` so the initial pass
   sees the currently running containers.
2. It runs `legacy_sweep` once. The sweep is gated by the
   `/certs/.certgen.legacy-swept` marker and independent of the render: it
   deletes `default.crt`/`default.key` and every old self-signed wildcard cert
   (CN `*.…`, self-issued). CA-signed and exact per-host certs are never
   touched.
3. It runs `on-change.sh initial` under `flock`. The **initial** pass only ever
   generates, never deletes: downstream containers may not have started yet, and
   an empty first render would otherwise wipe every cert. It also merges the
   desired set into the existing manifest (union) instead of shrinking it, so a
   startup-generated cert can never become an untracked orphan. It then touches
   `/certs/.certgen.ready` (the healthcheck marker).
4. It `exec`s `docker-gen -watch -interval 30 -wait 100ms:500ms -notify
   "flock $LOCK /scripts/on-change.sh full" /etc/docker-gen/certs.tmpl
   "$RENDER_FILE"`. `docker-gen` invokes the notify command when the rendered
   set changes and also at least every `-interval` seconds (30s), so `full`
   reconciles run on every container start/stop/recreate and periodically as a
   drift backstop. There is deliberately no second, self-scheduled timer in
   certgen.
5. `certs.tmpl` renders the desired host set: one exact `VIRTUAL_HOST` per line
   for every container whose `GEN_SELF_SIGNED_CERT` is truthy, preceded by a
   `# certgen-desired v1` sentinel and a `# containers-seen <N>` line.
6. `on-change.sh` -> `reconcile` validates the render (`read_desired` rejects a
   missing sentinel or `containers-seen <= 0`, guarding against partial/empty
   renders), generates any missing `<host>.crt`/`.key` pair, and — in `full`
   mode — removes certs whose host is no longer desired. It then forces
   nginx-proxy to re-render and reload so changes take effect immediately.

## Removal semantics

`reconcile` keeps a manifest at `/certs/.certgen.manifest` listing the desired
hosts. In `full` mode a host that disappeared from the desired set is removed
after `GEN_REMOVAL_GRACE` seconds (re-checked against a fresh render, so a host
that re-opts in during the grace period is kept). Removal is staged atomically:
the pair is renamed to `<host>.crt.gone`/`<host>.key.gone`, nginx-proxy is
re-rendered and reloaded, and only then are the `.gone` files deleted. If the
reload fails, the `.gone` files are left in place and a warning is printed, so
nginx is never left referencing a cert that has already been deleted.

## State files (in `$CERTS_DIR`)

| File                    | Purpose                                                       |
| ----------------------- | ------------------------------------------------------------- |
| `.certgen.manifest`     | Tracked host set: `full` prunes it to the desired set, `initial` unions it (never shrinks) |
| `.certgen.ready`        | Healthcheck marker; touched after each successful reconcile   |
| `.certgen.legacy-swept` | Marks that the one-time legacy sweep has run                  |
| `<host>.crt` / `.key`   | Exact self-signed cert pair for an opted-in host              |
| `*.gone`                | Staged-for-removal files awaiting a successful nginx reload   |

## Requirements

- Docker socket mounted at `/var/run/docker.sock` (reads events, triggers the
  nginx reload).
- `/certs` volume shared (read-only) with the nginx-proxy container. The nginx
  container is located dynamically by compose labels
  (`com.docker.compose.service=nginx`, preferring the certgen container's own
  compose project); set `$NGINX_CONTAINER` to override the lookup.

Run it via the compose file in the repository root; a healthcheck waits for
`/certs/.certgen.ready` before nginx starts.

## Why no PUID/PGID privilege drop

`certgen` runs as root under `network_mode: none` and only writes tiny cert
files to the shared `certs` volume, which nginx reads as root — there are no
large data dirs and no persistent ownership issue. Upstream images
(`nginx-proxy`, `acme-companion`) manage their own users.
