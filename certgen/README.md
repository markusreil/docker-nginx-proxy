# certgen

Sidecar that keeps valid TLS certs for the local reverse proxy. It runs as a
long-lived container: on startup it ensures the base wildcard cert for your
`BASE_DOMAIN` plus the nginx-proxy `default.crt` fallback, then watches Docker
events and generates parent-domain wildcard certs on demand whenever a
container appears with a multi-level `VIRTUAL_HOST` (e.g. `app.sub1.localhost`
-> generates a `sub1.localhost` cert valid for `sub1.localhost` and
`*.sub1.localhost`).

## Files

The `Dockerfile` sits at the top of `certgen/` (the compose build context is
`./certgen`); the scripts and template it copies into the image live in the
`docker/` subfolder.

| File              | Purpose                                                        |
| ----------------- | -------------------------------------------------------------- |
| `Dockerfile`      | alpine:3.20 + openssl + docker-cli + docker-gen 0.17.2 binary  |
| `docker/entrypoint.sh`   | Bootstrap base/default cert, then run docker-gen in watch mode |
| `docker/lib.sh`          | Shared helpers: `gen_cert`, `ensure_default` (idempotent)      |
| `docker/on-change.sh`    | Create missing certs, then force nginx-proxy re-render/reload  |
| `docker/certs.tmpl`      | docker-gen template: which parent-domain certs are missing     |

## Environment variables

| Variable           | Default      | Description                                                     |
| ------------------ | ------------ | --------------------------------------------------------------- |
| `BASE_DOMAIN`      | `localhost`  | Base domain for the top-level wildcard cert (`*.BASE_DOMAIN`)   |
| `CERT_DAYS`        | `825`        | Validity of generated certs                                     |
| `CERTS_DIR`        | `/certs`     | Where certs are written (shared volume with nginx-proxy)        |

## How it works

1. `entrypoint.sh` sources `lib.sh`, generates/verifies the base `$BASE_DOMAIN`
   cert (SANs: `$BASE_DOMAIN`, `*.$BASE_DOMAIN`) and the nginx-proxy `default` copy,
   then `exec`s `docker-gen -watch -interval 30 -wait 100ms:500ms -notify
   /scripts/on-change.sh /etc/docker-gen/certs.tmpl /tmp/certs-needed.txt`.
2. `certs.tmpl` renders the list of parent domains (one level up from each
   3+-label `VIRTUAL_HOST`) whose cert does not exist yet; docker-gen only
   runs the notify command when that list changes.
3. `on-change.sh` generates each missing cert and, when anything was created,
   forces nginx-proxy to re-render its config and reload (target resolved
   dynamically by compose labels, see below).

## Requirements

- Docker socket mounted at `/var/run/docker.sock` (reads events, triggers the
  nginx reload).
- `/certs` volume shared (read-only) with the nginx-proxy container. The nginx
  container is located dynamically by compose labels
  (`com.docker.compose.service=nginx`, preferring the certgen container's own
  compose project); set `$NGINX_CONTAINER` to override the lookup.

Run it via the compose file in the repository root; a healthcheck verifies
`default.crt`/`default.key` exist before nginx starts.