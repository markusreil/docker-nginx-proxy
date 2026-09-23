# docker-nginx-proxy

Reverse proxy with automatic TLS, split into composable variants. Spins up [`nginxproxy/nginx-proxy`](https://github.com/nginx-proxy/nginx-proxy) plus, depending on the selected variant, a self-signed, opt-in `certgen` sidecar or [`nginxproxy/acme-companion`](https://github.com/nginx-proxy/acme-companion) for real Let's Encrypt certs.

## Variants

The stack is a base `docker-compose.yml` (variant-neutral: `nginx` on HTTP/80 only) plus per-variant override files. Which files are layered is chosen by `COMPOSE_FILE` in `.env`:

| Variant | `COMPOSE_FILE` | TLS | Services |
| --- | --- | --- | --- |
| LAN, self-signed TLS (default) | `docker-compose.yml:docker-compose.lan.yml` | self-signed, per-host opt-in (`certgen`, always on) | `nginx` + `certgen` |
| Internet, mandatory TLS | `docker-compose.yml:docker-compose.public.yml` | real certs (Let's Encrypt) | `nginx` + `acme-companion` |

The safe default is **LAN (self-signed TLS)**: it serves plain HTTP on port 80 and self-signed HTTPS on 443, and never attempts certificate issuance. Every variant follows the same commands — only the `COMPOSE_FILE` value changes:

```bash
# LAN (default, self-signed TLS)
cp env.example .env
# .env: COMPOSE_FILE=docker-compose.yml:docker-compose.lan.yml
docker compose config
docker compose up -d --build

# Public (mandatory TLS) — also set ACME_EMAIL=you@example.com in .env
cp env.example .env
# .env: COMPOSE_FILE=docker-compose.yml:docker-compose.public.yml
docker compose config
docker compose up -d --build
```

To switch variants, edit `COMPOSE_FILE` in `.env` and re-run `docker compose config` / `docker compose up -d --build`.

## How it works

The base `docker-compose.yml` builds `nginx` from `./nginx` (wrapping upstream `nginxproxy/nginx-proxy:${NGINX_PROXY_VERSION}`) and runs it on port 80, joining the proxy network (default `web-proxy`, configurable via `NGINX_PROXY_NETWORK`). The two `conf.d` snippets (global upload limit and `stub_status`) are baked into the image at build time; only the Docker socket remains a host bind mount, while `html` and the `vhostd` config volume are named volumes. Variant overrides add TLS:

1. **LAN (default)** — `docker-compose.lan.yml` publishes port 443, mounts a shared `certs` volume, sets `HTTPS_METHOD=noredirect` (HTTP requests are served as-is, no redirect to HTTPS) and `ENABLE_HTTP_ON_MISSING_CERT=true`, and runs `certgen` (built from `./certgen`, Alpine + OpenSSL + docker-gen), which is always on. `certgen` generates a self-signed cert **only** for proxied containers that opt in via `GEN_SELF_SIGNED_CERT` (truthy: `true`, `1`, `t`). The cert identity is the exact `VIRTUAL_HOST` value, written as `<host>.crt`/`.key` with `CN=<host>` and SAN `DNS:<host>` — nginx-proxy probes `/etc/nginx/certs/<host>.crt`, so one host maps to one cert pair. Hosts that don't opt in are served over HTTP only. To silence the browser warning, trust the cert via [Trust the cert locally](#trust-the-cert-locally-removes-browser-warning).
2. **Public** — `docker-compose.public.yml` publishes port 443, mounts the shared `certs` volume and runs `acme-companion`, which obtains real Let's Encrypt certs for containers that opt in via `ACME_HOST`. It deliberately omits `certgen`, so there is no trusted self-signed fallback.

Any container on the proxy network with `VIRTUAL_HOST` set gets routed. In the LAN variant:

- `nginx` mounts the `certs` volume at `/etc/nginx/certs:ro` and terminates TLS automatically for hosts that have a cert (no per-host config needed).
- `certgen` watches container events via docker-gen and reconciles the `certs` volume against the opted-in host set. When a host stops opting in (or its container goes away), its cert pair is deleted after a grace period (`GEN_REMOVAL_GRACE`, default 30s). nginx-proxy is forced to re-render and reload after any generate/remove so the change takes effect immediately.

## Multi-level hosts (`app.sub1.localhost`)

This section applies to the LAN variant (`certgen`). nginx server names support wildcards at any depth, so routing works for `app.sub1.localhost` out of the box. `certgen` does **not** collapse hosts into parent-domain wildcards: each opted-in `VIRTUAL_HOST` gets its own exact `<host>.crt`/`.key` (`CN=app.sub1.localhost`, SAN `DNS:app.sub1.localhost`). So `app.sub1.localhost` and `other.sub1.localhost` are independent certs — no sharing, and no special casing for multi-level names:

- Start any container with `VIRTUAL_HOST=app.sub1.localhost` and `GEN_SELF_SIGNED_CERT=true`.
- `certgen` creates `app.sub1.localhost.crt`/`.key` and reloads nginx.
- Regexp (`~^...`), asterisk (`*.`), port-bearing (`host:port`), path-bearing and `..`-containing `VIRTUAL_HOST` values are ignored by certgen (they can't be used as cert filenames).

## Prerequisites

- Docker + Docker Compose v2
- No `/etc/hosts` wildcard needed: `*.localhost` resolves to `127.0.0.1` automatically on modern systems/browsers, so `app1.localhost` works out of the box.

## Quickstart

The commands below use the default **LAN (self-signed TLS)** variant. To use another variant, set `COMPOSE_FILE` as shown in [Variants](#variants).

```bash
# 1. Configure (defaults: LAN variant, CERT_DAYS=825)
cp env.example .env  # COMPOSE_FILE defaults to the LAN variant

# 2. No host entries needed for *.localhost — it already points to 127.0.0.1.
# For custom domains (e.g. app1.local.test) add explicit entries, as /etc/hosts has no wildcards:
# 127.0.0.1 app1.local.test app2.local.test

# 3. Validate and start
docker compose config
docker compose up -d --build
```

For the LAN variant there is a convenience wrapper, `compose-lan.sh`, which bakes in the `-f` flags. With no arguments it rebuilds the images, **recreates the volumes** (`down -v`, so `certgen` regenerates fresh certs), and starts detached; pass any `docker compose` subcommand to delegate to it:

```bash
./compose-lan.sh                  # down -v + up -d --build (fresh build + certs)
KEEP_VOLUMES=1 ./compose-lan.sh   # rebuild/start but keep existing volumes (certs)
./compose-lan.sh ps               # delegate: docker compose -f ... ps
./compose-lan.sh logs -f certgen  # ... any compose subcommand
```

Verify certs were created (the default LAN variant runs `certgen`):

```bash
docker compose exec nginx ls /etc/nginx/certs
```

Then attach any app to the proxy:

```yaml
services:
  myapp:
    image: myapp:latest
    expose:
      - "3000"
    environment:
      VIRTUAL_HOST: app1.localhost
      VIRTUAL_PORT: "3000"
      # Declare BOTH TLS opt-ins so the same file works in every variant.
      ACME_HOST: app1.localhost        # real cert (public variant)
      GEN_SELF_SIGNED_CERT: "true"     # self-signed cert (LAN variant)
    networks:
      - web-proxy

networks:
  web-proxy:
    name: ${NGINX_PROXY_NETWORK:-web-proxy}   # must match the proxy cluster's value
    external: true                            # created by the proxy; start it first
```

With `GEN_SELF_SIGNED_CERT=true` the LAN variant serves both `http://app1.localhost` (plain) and `https://app1.localhost` (self-signed); expect a browser warning on HTTPS until you trust the cert, see below. Without the opt-in flag the host is served over HTTP only.

Declare the **complete** contract — every applicable variable, including **both** TLS opt-ins when HTTPS is wanted. The proxy fails silently on an omission (no routing, or HTTP-only / no certificate), and declaring only one opt-in pins the service to one variant. Use the `ACME_*` spelling for every ACME variable; the legacy `LETSENCRYPT_*` spellings are accepted upstream but should not be used (the only exception is `LETSENCRYPT_TEST`).

## Configuration

`.env`:

| Var | Default | Description |
| --- | --- | --- |
| `COMPOSE_FILE` | `docker-compose.yml:docker-compose.lan.yml` | Which compose files make up the stack (see [Variants](#variants)) |
| `NGINX_PROXY_NETWORK` | `web-proxy` | Docker network name shared between the proxy and proxied containers |
| `NGINX_PROXY_VERSION` | `1.11` | Base-image tag used to build the `nginx` image (build arg; pinned per spec rule 1) |
| `ACME_COMPANION_VERSION` | `2.8` | Upstream acme-companion image tag (pinned per spec rule 1) |
| `ACME_EMAIL` | *(empty)* | ACME contact email for Let's Encrypt (becomes the companion's `DEFAULT_EMAIL`). **Required** when `COMPOSE_FILE` selects the public variant; config fails fast if empty. |
| `CERT_DAYS` | `825` | Self-signed cert validity in days. **Required** by the LAN variant. |
| `GEN_REMOVAL_GRACE` | `30` | Seconds to wait before deleting a cert whose host stopped opting in (LAN variant) |

`ACME_EMAIL` is required by `docker-compose.public.yml`, and `CERT_DAYS` by `docker-compose.lan.yml` (`${VAR:?…}` fails fast if missing). `GEN_REMOVAL_GRACE` is optional (`${VAR:-default}`). The base variant needs none of them.

Downstream containers opt in to a self-signed cert with `GEN_SELF_SIGNED_CERT=true` (truthy: `true`, `1`, `t`, case-insensitive). It is set on the proxied container, not in this `.env`.

## Real certs (Let's Encrypt)

ACME issuance belongs to the **public** variant (`COMPOSE_FILE=docker-compose.yml:docker-compose.public.yml`), which runs `acme-companion`. In the LAN variant no ACME cert is issued; containers that opt in via `GEN_SELF_SIGNED_CERT` are served with their exact self-signed `<host>.crt`, and everyone else is served over HTTP only. To get a real, publicly trusted cert instead, add `ACME_HOST` to the same container and select the public variant:

```yaml
services:
  myapp:
    image: myapp:latest
    expose:
      - "3000"
    environment:
      VIRTUAL_HOST: app1.example.com     # routes + serves TLS
      VIRTUAL_PORT: "3000"
      ACME_HOST: app1.example.com        # signals acme-companion: issue a real cert
      GEN_SELF_SIGNED_CERT: "true"       # inert here, keeps the service variant-agnostic
      ACME_EMAIL: you@example.com        # optional per-container contact (fallback: cluster ACME_EMAIL)
      LETSENCRYPT_TEST: "true"           # optional: use Let's Encrypt staging first
    networks:
      - web-proxy

networks:
  web-proxy:
    name: ${NGINX_PROXY_NETWORK:-web-proxy}
    external: true
```

- `ACME_HOST` must match `VIRTUAL_HOST`. Set it on every HTTPS service (alongside `GEN_SELF_SIGNED_CERT`); leave it unset only for a deliberately HTTP-only service, which then gets no real cert.
- The public variant deliberately omits `certgen`, so there is **no trusted self-signed fallback**: until a real cert is issued, nginx serves only HTTP (`ENABLE_HTTP_ON_MISSING_CERT=false`). Make sure port 80 stays reachable so the HTTP-01 challenge can complete.
- An empty `ACME_HOST=` placeholder is harmless: acme-companion treats it exactly like the variable being absent (the container is skipped, no cert is issued). This is fine as a template placeholder for services that may later opt in.
- Requires HTTP port 80 to be reachable from the internet (HTTP-01 challenge). Try `LETSENCRYPT_TEST: "true"` (staging) before going live, then remove it.
- Wildcard certs (`*.example.com`) are possible via DNS-01 challenges, but need a DNS provider setup — see the [acme-companion docs](https://github.com/nginx-proxy/acme-companion). Use distinct public hostnames for Let's Encrypt.

## Per-host upload limits

nginx-proxy's default body-size limit is 1 MB. The **global** default lives in
`nginx/docker/conf.d/global-upload-limit.conf` (currently `10m`) and is baked
into the `nginx` image — edit it and rebuild to change it everywhere:

```bash
# edit nginx/docker/conf.d/global-upload-limit.conf, then:
docker compose -f docker-compose.yml -f docker-compose.lan.yml build nginx
docker compose -f docker-compose.yml -f docker-compose.lan.yml up -d nginx
```

To raise the limit **per host**, write a file named after the `VIRTUAL_HOST`
into the `vhostd` named volume (mounted at `/etc/nginx/vhost.d`) and reload:

```bash
docker compose exec nginx sh -c 'printf "client_max_body_size 50m;\n" > /etc/nginx/vhost.d/app1.localhost'
docker compose exec nginx nginx -s reload   # re-reads vhost.d (no container restart needed)
```

Only that host is affected; other vhosts keep the global default. Notes:

- Use `<host>_location` as the filename (e.g. `/etc/nginx/vhost.d/app1.localhost_location`) to apply the limit to the `location` block instead of the whole server block.
- `/etc/nginx/vhost.d/default` applies to any vhost without its own file.
- Per-host files override the global limit. `CLIENT_MAX_BODY_SIZE` is not supported by this image (see nginx-proxy's [custom nginx configuration](https://github.com/nginx-proxy/nginx-proxy/tree/main/docs#custom-nginx-configuration)).
- `vhostd` is a named volume, so per-host files survive restarts and live inside the volume rather than on the host filesystem.

## Homepage status card (nginx stub_status)

The `nginx` service carries `homepage.*` labels so Homepage (https://gethomepage.dev) auto-discovers it as a card showing the proxy's Docker status and, when clicked, CPU/memory/network stats. `certgen` (LAN variant) and `acme-companion` (public variant) carry the same group (`Infrastructure`) with `homepage.icon` and `homepage.weight` labels, so every component in the selected variant appears as a status/stats card. It also sets:

```
homepage.siteMonitor: http://nginx:8080/stub_status
```

which probes nginx for UP/DOWN + response time. `stub_status.conf` is **baked into the built `nginx` image** (`nginx/docker/conf.d/stub_status.conf`) and enabled out of the box, so the card works with no manual step. To view the endpoint:

```bash
docker compose exec nginx sh -c 'wget -qO- http://127.0.0.1:8080/stub_status'
```

To disable or change it, edit `nginx/docker/conf.d/stub_status.conf` and rebuild the `nginx` image (`docker compose -f docker-compose.yml -f docker-compose.lan.yml build nginx` + `up -d nginx`); the snippet is baked at build time, not bind-mounted.

Notes:

- The endpoint is internal-only (no host port mapping) and restricted to Docker/LAN subnets by the `allow`/`deny` rules in the snippet.
- The monitor URL assumes Homepage reaches the proxy over the proxy network (default `web-proxy`, hostname `nginx`). If your Homepage container isn't on that network, change `homepage.siteMonitor` to a host-reachable URL (e.g. `http://<host-ip>:8080/stub_status`).

## Trust the cert locally (removes browser warning)

Applies to the LAN variant (`certgen`). The CA is self-signed, so browsers warn until you trust the cert from the `certs` volume. Each opted-in host has its own cert, named after its exact `VIRTUAL_HOST`, so extract the one you need first:

```bash
docker compose cp certgen:/certs/app1.localhost.crt ./app1.localhost.crt
# replace app1.localhost with the host you opted in via GEN_SELF_SIGNED_CERT
```

Then trust:

```bash
# Linux
sudo cp app1.localhost.crt /usr/local/share/ca-certificates/app1.localhost.crt && sudo update-ca-certificates

# macOS
sudo security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain ./app1.localhost.crt

# Windows
# import ./app1.localhost.crt into 'Trusted Root Certification Authorities' via certlm.msc
```

## Regenerate certs

Applies to the LAN variant (`certgen`).

```bash
docker compose down -v  # drops the certs volume; omit -v to keep certs
# or: docker volume rm web-proxy_certs
docker compose up -d --build
```

To regenerate a single host's cert, delete its files from the `certs` volume (e.g. `app1.localhost.crt`/`.key`) — `certgen` recreates it on the next reconcile or container event.

## Cert removal and the legacy sweep

`certgen` keeps a manifest of the currently desired hosts (`/certs/.certgen.manifest`). When a host stops opting in (`GEN_SELF_SIGNED_CERT` removed/falsy) or its container goes away, its cert pair is removed after `GEN_REMOVAL_GRACE` seconds. Removal is staged: the files are first renamed to `*.gone`, nginx-proxy is re-rendered/reloaded, and only then are the `.gone` files deleted. If the reload fails the `.gone` files are kept, so nginx is never left pointing at a cert that has already been deleted.

On first run with an existing `certs` volume, `certgen` performs a one-time **legacy sweep**: it deletes the old `default.crt`/`default.key` fallback and any old self-signed wildcard certs (CN `*.…`, self-issued) that are no longer desired. Let's Encrypt (CA-signed) certs and exact per-host certs are never touched.

## Project structure

```
.
├── docker-compose.yml          # base: nginx build + HTTP/80, shared volumes/network (variant-neutral)
├── docker-compose.lan.yml      # override: HTTP + self-signed TLS, certgen (default)
├── docker-compose.public.yml   # override: port 443 + acme-companion, mandatory Let's Encrypt TLS
├── compose-lan.sh              # convenience wrapper: LAN variant, rebuild + recreate volumes by default
├── env.example                 # template for .env (COMPOSE_FILE, versions, CERT_DAYS, ACME_EMAIL)
├── .env                        # local config (gitignored)
├── nginx/
│   ├── Dockerfile              # wraps upstream nginx-proxy; bakes in the conf.d snippets
│   ├── README.md               # nginx image docs
│   └── docker/conf.d/
│       ├── global-upload-limit.conf # global client_max_body_size (default 10m), baked at build time
│       └── stub_status.conf         # internal stub_status endpoint on :8080, baked at build time
└── certgen/
    ├── Dockerfile              # alpine + openssl + docker-cli + docker-gen
    ├── README.md               # certgen docs
    └── docker/                 # build files copied into the image
        ├── entrypoint.sh       # one-shot render + legacy sweep + generate-only pass, then docker-gen watch
        ├── lib.sh              # shared helpers (reconcile, gen_cert_host, legacy_sweep)
        ├── on-change.sh        # thin reconcile wrapper called by docker-gen
        └── certs.tmpl          # docker-gen template: desired opt-in host set
```

Named volumes: `html`, `vhostd` (per-host nginx config at `/etc/nginx/vhost.d`), and `certs` (LAN/public TLS). The Docker socket is the only bind mount.

## Security notes

- The public variant uses `HTTPS_METHOD=redirect` (HTTP redirects to HTTPS). It is deliberately **not** `nohttp`: the ACME HTTP-01 challenge needs port 80 reachable, so blocking HTTP would break issuance.
- `ENABLE_HTTP_ON_MISSING_CERT=false` means nginx never falls back to a self-signed cert in the public variant — a host without a valid cert is served over HTTP only. Combined with the omission of `certgen`, there is no trusted self-signed fallback.
- HSTS is on by default in the public variant (`HSTS: max-age=31536000`) and is **sticky**: after the first HTTPS response, browsers refuse plain HTTP to the domain for a year. Get certs working before exposing a host publicly, and test with `LETSENCRYPT_TEST: "true"` (Let's Encrypt staging) first.
- Downstream containers can override `HTTPS_METHOD` and `HSTS` per-vhost (nginx-proxy reads them from the proxied container's environment). A downstream service that sets e.g. `HTTPS_METHOD=nohttps` bypasses the public variant's TLS enforcement — review proxied containers before trusting the redirect/HSTS guarantees.

## Notes

- No `x-hosts` anchors in `docker-compose.yml`: this file is an infra-only proxy and defines zero `VIRTUAL_HOST`/`ACME_HOST` values — hostnames live in downstream clusters, so anchors would deduplicate nothing.
- `nginx` wraps the upstream `nginxproxy/nginx-proxy` image with a small build that bakes in the `conf.d` snippets (no custom entrypoint, no first-run seeding); `acme-companion` still uses the upstream image unchanged — per spec rule 6, the upstream image *is* the service.
- The default LAN variant serves plain HTTP and self-signed HTTPS; the public variant adds real Let's Encrypt certs for any container that opts in via `ACME_HOST`.
- Cert: RSA 2048, SHA-256, self-signed, `CN=<host>`, SAN `DNS:<host>` (the exact opted-in `VIRTUAL_HOST`, no wildcard).
- `certgen` (LAN variant) needs the docker socket to watch events and to trigger nginx reloads. It locates the nginx container dynamically by compose labels (`com.docker.compose.service=nginx`, preferring its own compose project); set `$NGINX_CONTAINER` to override.
