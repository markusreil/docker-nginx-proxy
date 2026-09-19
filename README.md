# docker-nginx-proxy

Local reverse proxy with automatic self-signed wildcard TLS. Spins up [`nginxproxy/nginx-proxy`](https://github.com/nginx-proxy/nginx-proxy) plus a one-shot `certgen` container that creates a wildcard cert for your local domain.

## How it works

1. `certgen` (built from `./certgen`, Alpine + OpenSSL) generates `<DOMAIN>.crt` / `<DOMAIN>.key` valid for `<DOMAIN>` and `*.<DOMAIN>` into a shared `certs` volume. Idempotent — skips if both files already exist.
2. `nginx` mounts that volume at `/etc/nginx/certs:ro` and terminates TLS automatically (no per-host config needed).
3. Any container on the `web-proxy` network with `VIRTUAL_HOST` set gets routed + TLS.

## Prerequisites

- Docker + Docker Compose v2
- OpenSSL (only needed for the standalone script, not for Compose)
- No `/etc/hosts` wildcard needed: `*.localhost` resolves to `127.0.0.1` automatically on modern systems/browsers. `/etc/hosts` does not support wildcards, which is why `localhost` is the default `DOMAIN`.

## Quickstart

```bash
# 1. Configure (defaults: DOMAIN=localhost, CERT_DAYS=825)
cp .env .env  # edit DOMAIN / CERT_DAYS as needed

# 2. No host entries needed for *.localhost — it already points to 127.0.0.1.
# For a custom DOMAIN (e.g. local.test) add explicit entries, as /etc/hosts has no wildcards:
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
    external: true
```

Visit `https://app1.localhost` (expect a self-signed warning until you trust the cert, see below).

## Configuration

`.env`:

| Var | Default | Description |
| --- | --- | --- |
| `DOMAIN` | `localhost` | Base domain; cert covers `DOMAIN` + `*.DOMAIN` |
| `CERT_DAYS` | `825` | Cert validity in days |

Both are required by `docker-compose.yml` (`${VAR:?…}` fails fast if missing).

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

## Trust the cert locally (removes browser warning)

The CA is self-signed, so browsers warn until you trust `./certs`-equivalent from the volume. Extract it first:

```bash
docker compose cp certgen:/certs/localhost.crt ./localhost.crt
# replace localhost with your $DOMAIN
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

Changing `DOMAIN` generates a separate `<new-domain>.crt`/`.key` pair; old files remain in the volume.

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
├── docker-compose.yml          # certgen + nginx, shared certs volume, web-proxy network
├── .env                        # DOMAIN, CERT_DAYS
├── vhost.d/                    # per-host nginx config (e.g. upload limits), mounted into nginx
├── conf.d/
│   └── global-upload-limit.conf # global client_max_body_size (default 10m)
├── certgen/
│   ├── Dockerfile              # alpine + openssl
│   └── entrypoint.sh           # idempotent wildcard cert generation (/certs)
└── generate-wildcard-cert.sh   # host-side equivalent (Linux/macOS/WSL)
```

## Notes

- Self-signed only — for local dev, not production. For public hosts use `nginx-proxy` + `acme-companion` instead.
- Cert: RSA 2048, SHA-256, `CN=*.DOMAIN`, SANs `DOMAIN` + `*.DOMAIN`, `serverAuth` EKU.
