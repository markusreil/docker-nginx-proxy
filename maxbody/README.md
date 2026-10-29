# maxbody

Sidecar that keeps per-vhost nginx upload limits. It runs as a long-lived
container: it watches Docker events and writes one file per opted-in
proxied container into the shared `vhostd` volume, named after the exact
`VIRTUAL_HOST` value and containing `client_max_body_size <size>;`.
When a host stops opting in, its file is removed again and the global
default (`client_max_body_size 10m` from the nginx image) applies.

## Files

The `Dockerfile` sits at the top of `maxbody/` (the compose build context
is `./maxbody`); the scripts and template it copies into the image live in
the `docker/` subfolder.

| File                  | Purpose                                                      |
| --------------------- | ------------------------------------------------------------ |
| `Dockerfile`          | alpine:3.24 + docker-cli + docker-gen 0.17.2 binary          |
| `docker/entrypoint.sh`| One-shot render, reconcile, then docker-gen watch            |
| `docker/lib.sh`       | Shared helpers: `read_desired`, `reconcile`, `reload_nginx`   |
| `docker/on-change.sh` | Thin wrapper: `reconcile "$RENDER_FILE"`                     |
| `docker/maxbody.tmpl` | docker-gen template: desired host/size set + invalid lines   |

## Downstream contract

Set on the proxied container:

| Variable       | Required | Description                                              |
| -------------- | -------- | -------------------------------------------------------- |
| `MAX_BODY_SIZE`| no       | Upload limit in nginx size syntax (`50m`, `1g`, `512k`, or bare bytes). Must match `^[0-9]+[kKmMgG]?$`; anything else is ignored with a warning. Unset means the global `10m` default. |

`MAX_BODY_SIZE` applies to every `VIRTUAL_HOST` on that container.

## How it works

1. `entrypoint.sh` sources `lib.sh`, then runs a one-shot
   `docker-gen /etc/docker-gen/maxbody.tmpl "$RENDER_FILE"` so the first
   pass sees the currently running containers.
2. It runs `on-change.sh` under `flock`, then `exec`s
   `docker-gen -watch -interval 30 -wait 100ms:500ms -notify
   "flock $LOCK /scripts/on-change.sh" ...`. Reconciles run on every
   container start/stop/recreate and periodically as a drift backstop.
3. `maxbody.tmpl` renders the desired set: one `<host> <size>` line per
   opted-in `VIRTUAL_HOST`, preceded by a `# maxbody-desired v1` sentinel
   and a `# containers-seen <N>` line. Containers with an invalid
   `MAX_BODY_SIZE` render as `# invalid <host> <value>` comment lines so
   the reconciler can log them.
4. `reconcile` validates the render (`read_desired` rejects a missing
   sentinel or `containers-seen <= 0`), writes a `<host>` file only when
   its content changed, and removes manifest-tracked files whose host is
   no longer desired. It then forces nginx-proxy to re-render and reload.

Removal is prompt (no grace period): while the backend is down the vhost
briefly falls back to the global `10m` limit. Only files listed in
`/vhostd/.maxbody.manifest` are ever removed; manual `vhost.d` entries
and `<host>_location` files are untouched.

## State files (in the `vhostd` volume)

| File                  | Purpose                                              |
| --------------------- | ---------------------------------------------------- |
| `.maxbody.manifest`   | Tracked `host size` pairs                            |
| `.maxbody.ready`      | Marker touched after each successful reconcile       |
| `<host>`              | `client_max_body_size <size>;` for an opted-in host  |

## Requirements

- Docker socket mounted at `/var/run/docker.sock` (reads events, triggers
  the nginx reload).
- `vhostd` volume shared (writable) with the nginx-proxy container. The
  nginx container is located dynamically by compose labels
  (`com.docker.compose.service=nginx`, preferring the maxbody container's
  own compose project); set `$NGINX_CONTAINER` to override the lookup.

Runs in every variant (wired into the base `docker-compose.yml`); no
healthcheck gating, nginx never waits for it.
