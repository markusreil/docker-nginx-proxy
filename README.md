# docker-nginx-proxy

Local reverse proxy with automatic self-signed wildcard TLS. Spins up [`nginxproxy/nginx-proxy`](https://github.com/nginx-proxy/nginx-proxy) plus a one-shot `certgen` container that creates a wildcard cert for your local domain.

## How it works

1. `certgen` (built from `./certgen`, Alpine + OpenSSL + docker-gen) runs as a long-lived sidecar. On startup it generates a base cert for your local domain (`<BASE_DOMAIN>.crt`/`.key` valid for `<BASE_DOMAIN>` and `*.<BASE_DOMAIN>`), plus a `default.*` copy for nginx-proxy's fallback. Idempotent — skips if files already exist.
2. `nginx` mounts that volume at `/etc/nginx/certs:ro` and terminates TLS automatically (no per-host config needed).
3. Any container on the proxy network (default `web-proxy`, configurable via `NGINX_PROXY_NETWORK`) with `VIRTUAL_HOST` set gets routed + TLS.
4. `certgen` watches container events via docker-gen. When a `VIRTUAL_HOST` is 3+ labels deep (e.g. `app.sub1.localhost`), it generates a wildcard cert for the parent domain (`sub1.localhost` -> `sub1.localhost.crt`/`.key`, SANs `sub1.localhost` + `*.sub1.localhost`) on demand, then forces nginx to re-render and reload so the new cert is used immediately.

## Multi-level hosts (`app.sub1.localhost`)

nginx server names support wildcards at any depth, so routing works for `app.sub1.localhost` out of the box. TLS is the catch: a wildcard cert `*.localhost` only covers *one* label, so `app.sub1.localhost` needs its own cert. `certgen` handles this automatically:

- Start any container with `VIRTUAL_HOST=app.sub1.localhost` (3+ labels).
- `certgen` notices it, generates a wildcard cert for `sub1.localhost` (SANs `sub1.localhost` + `*.sub1.localhost`), and reloads nginx.
- All future hosts under `*.sub1.localhost` reuse that cert — no per-host config.

Single-label hosts (`app1.localhost`) and the bare domain keep using the base `*.<BASE_DOMAIN>` cert. Regexp (`~^...`), asterisk (`*.`) and port-bearing `VIRTUAL_HOST` values are ignored by the on-demand cert logic.

## Prerequisites

- Docker + Docker Compose v2
- OpenSSL (only needed for the standalone script, not for Compose)
- No `/etc/hosts` wildcard needed: `*.localhost` resolves to `127.0.0.1` automatically on modern systems/browsers. `/etc/hosts` does not support wildcards, which is why `localhost` is the default `BASE_DOMAIN`.

## Quickstart

```bash
# 1. Configure (defaults: BASE_DOMAIN=localhost, CERT_DAYS=825)
cp env.example .env  # edit BASE_DOMAIN / CERT_DAYS as needed

# 2. No host entries needed for *.localhost — it already points to 127.0.0.1.
# For a custom BASE_DOMAIN (e.g. local.test) add explicit entries, as /etc/hosts has no wildcards:
# 127.0.0.1 local.test app1.local.test app2.local.test

# 3. Start
docker compose up -d --build

# 4. Verify certs were created
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
    networks:
      - web-proxy

networks:
  web-proxy:
    name: ${NGINX_PROXY_NETWORK:-web-proxy}
    external: true
```

Visit `https://app1.localhost` (expect a self-signed warning until you trust the cert, see below).

## Configuration

`.env`:

| Var | Default | Description |
| --- | --- | --- |
| `BASE_DOMAIN` | `localhost` | Base domain; cert covers `BASE_DOMAIN` + `*.BASE_DOMAIN` |
| `CERT_DAYS` | `825` | Cert validity in days |
| `NGINX_PROXY_NETWORK` | `web-proxy` | Docker network name shared between the proxy and proxied containers |
| `NGINX_PROXY_VERSION` | `1.11` | Upstream nginx-proxy image tag (pinned per spec rule 1) |
| `ACME_COMPANION_VERSION` | `2.8` | Upstream acme-companion image tag (pinned per spec rule 1) |
| `LE_EMAIL` | *(empty)* | Optional contact email for Let's Encrypt (becomes the companion's `DEFAULT_EMAIL`). Leave empty for local-only use. |

`BASE_DOMAIN` and `CERT_DAYS` are required by `docker-compose.yml` (`${VAR:?…}` fails fast if missing); `LE_EMAIL` is optional.

## Real certs (Let's Encrypt)

Local-only containers just set `VIRTUAL_HOST` — they're proxied and served with the self-signed wildcard (`default.*`). To get a real, publicly trusted cert instead, add `ACME_HOST` to the same container:

```yaml
services:
  myapp:
    image: myapp:latest
    expose:
      - "443"
    environment:
      VIRTUAL_HOST: app1.example.com     # routes + serves TLS
      VIRTUAL_PORT: "443"
      ACME_HOST: app1.example.com        # signals acme-companion: issue a real cert
      ACME_EMAIL: you@example.com        # optional per-container contact (fallback: LE_EMAIL)
      LETSENCRYPT_TEST: "true"           # optional: use Let's Encrypt staging first
    networks:
      - web-proxy

networks:
  web-proxy:
    name: ${NGINX_PROXY_NETWORK:-web-proxy}
    external: true
```

- `ACME_HOST` must match `VIRTUAL_HOST`. Omit `ACME_HOST` to keep the self-signed fallback.
- An empty `ACME_HOST=` placeholder is harmless: acme-companion treats it exactly like the variable being absent (the container is skipped, no cert is issued, self-signed fallback stays). This is fine as a template placeholder for services that may later opt in.
- Requires HTTP port 80 to be reachable from the internet (HTTP-01 challenge). Try `LETSENCRYPT_TEST: "true"` (staging) before going live, then remove it.
- Wildcard certs (`*.example.com`) are possible via DNS-01 challenges, but need a DNS provider setup — see the [acme-companion docs](https://github.com/nginx-proxy/acme-companion). Keep `BASE_DOMAIN` for the internal wildcard and use distinct public hostnames for Let's Encrypt.

## Per-host upload limits

nginx-proxy's default body-size limit is 1 MB. To raise it per host, drop a file named after the `VIRTUAL_HOST` into `./vhost.d` (mounted at `/etc/nginx/vhost.d`):

```bash
echo 'client_max_body_size 50m;' > vhost.d/app1.localhost
docker compose exec nginx nginx -s reload   # re-reads vhost.d (no container restart needed)
```

Only that host is affected; other vhosts keep the global default. Notes:

- The global upload limit for all hosts is set in `conf.d/global-upload-limit.conf` (default `10m`). Edit it and reload to change it everywhere.
- Use `<host>_location` as the filename (e.g. `vhost.d/app1.localhost_location`) to apply the limit to the `location` block instead of the whole server block.
- `vhost.d/default` applies to any vhost without its own file.
- Per-host files override the global limit. `CLIENT_MAX_BODY_SIZE` is not supported by this image (see nginx-proxy's [custom nginx configuration](https://github.com/nginx-proxy/nginx-proxy/tree/main/docs#custom-nginx-configuration)).

## Homepage status card (nginx stub_status)

The `nginx` service carries `homepage.*` labels so Homepage (https://gethomepage.dev) auto-discovers it as a card showing the proxy's Docker status and, when clicked, CPU/memory/network stats. `certgen` and `acme-companion` carry the same group (`Infrastructure`) with `homepage.icon` and `homepage.weight` labels, so all three proxy components appear as status/stats cards. It also sets:

```
homepage.siteMonitor: http://nginx:8080/stub_status
```

which probes nginx for UP/DOWN + response time. That endpoint is **not enabled by default** — enable it like this:

1. Create `conf.d/stub_status.conf`:

   ```nginx
   server {
       listen 8080;
       location = /stub_status {
           stub_status;
           allow 172.16.0.0/12;   # Docker networks (incl. web-proxy)
           allow 192.168.0.0/16;  # LAN
           deny all;
           access_log off;
       }
   }
   ```

2. Mount it into the `nginx` service in `docker-compose.yml` and expose the internal port:

   ```yaml
   volumes:
     - ./conf.d/stub_status.conf:/etc/nginx/conf.d/stub_status.conf:ro
   expose:
     - "8080"
   ```

3. Apply:

   ```bash
   docker compose up -d
   ```

Notes:

- The endpoint is internal-only (no host port mapping) and restricted to Docker/LAN subnets.
- The monitor URL assumes Homepage reaches the proxy over the proxy network (default `web-proxy`, hostname `nginx`). If your Homepage container isn't on that network, change `homepage.siteMonitor` to a host-reachable URL (e.g. `http://<host-ip>:8080/stub_status`).
- Until the endpoint is enabled, the card shows the site monitor as DOWN; the Docker status and stats still work.

## Trust the cert locally (removes browser warning)

The CA is self-signed, so browsers warn until you trust `./certs`-equivalent from the volume. Extract it first:

```bash
docker compose cp certgen:/certs/localhost.crt ./localhost.crt
# replace localhost with your $BASE_DOMAIN
```

Then trust:

```bash
# Linux
sudo cp localhost.crt /usr/local/share/ca-certificates/localhost.crt && sudo update-ca-certificates

# macOS
sudo security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain ./localhost.crt

# Windows
# import ./localhost.crt into 'Trusted Root Certification Authorities' via certlm.msc
```

## Regenerate certs

```bash
docker compose down -v  # drops the certs volume; omit -v to keep certs
# or: docker volume rm web-proxy_certs
docker compose up -d --build
```

Changing `BASE_DOMAIN` generates a separate `<new-domain>.crt`/`.key` pair; old files remain in the volume.

To regenerate a single host's cert, delete its files from the `certs` volume (e.g. `sub1.localhost.crt`/`.key`) — `certgen` will recreate it within ~30s or on the next container event.

## Standalone script (no Docker)

`generate-wildcard-cert.sh` does the same thing on the host and writes nginx-proxy-compatible files (`<domain>.crt` + `<domain>.key`):

```bash
./generate-wildcard-cert.sh myapp.test
./generate-wildcard-cert.sh myapp.test ./certs 825
# usage: ./generate-wildcard-cert.sh [domain] [certs_dir] [days]
```

Refuses to overwrite existing files — delete them first to regenerate.

## Project structure

```
.
├── docker-compose.yml          # certgen (docker-gen sidecar) + nginx, shared certs volume, configurable proxy network (`NGINX_PROXY_NETWORK`, default `web-proxy`)
├── .env                        # BASE_DOMAIN, CERT_DAYS, NGINX_PROXY_NETWORK
├── vhost.d/                    # per-host nginx config (e.g. upload limits), mounted into nginx
├── conf.d/
│   └── global-upload-limit.conf # global client_max_body_size (default 10m)
├── certgen/
│   ├── Dockerfile              # alpine + openssl + docker-cli + docker-gen
│   ├── README.md               # certgen docs
│   └── docker/                 # build files copied into the image
│       ├── entrypoint.sh       # bootstrap base cert, then run docker-gen (watch)
│       ├── lib.sh              # shared cert helpers (gen_cert, ensure_default)
│       ├── on-change.sh        # generate missing parent-domain certs + reload nginx
│       └── certs.tmpl          # docker-gen template: hosts needing parent certs
└── generate-wildcard-cert.sh   # host-side equivalent (Linux/macOS/WSL)
```

## Notes

- No `x-hosts` anchors in `docker-compose.yml`: this file is an infra-only proxy and defines zero `VIRTUAL_HOST`/`LETSENCRYPT_HOST` values — hostnames live in downstream clusters, so anchors would deduplicate nothing.
- `nginx-proxy` and `acme-companion` use upstream images (no custom build) per spec rule 6: the image *is* the service here, no first-run seeding or config generation is needed.
- Out of the box this is a self-signed local setup; the bundled `acme-companion` adds real Let's Encrypt certs for any container that opts in via `ACME_HOST`.
- Cert: RSA 2048, SHA-256, `CN=*.BASE_DOMAIN`, SANs `BASE_DOMAIN` + `*.BASE_DOMAIN`, `serverAuth` EKU.
- `certgen` needs the docker socket to watch events and to trigger nginx reloads. It locates the nginx container dynamically by compose labels (`com.docker.compose.service=nginx`, preferring its own compose project); set `$NGINX_CONTAINER` to override.
