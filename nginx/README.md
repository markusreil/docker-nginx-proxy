# nginx

The reverse proxy. A thin build wrapping the upstream
[`nginxproxy/nginx-proxy`](https://github.com/nginx-proxy/nginx-proxy) image,
with this project's `conf.d` snippets baked in at build time.

## Files

| File                                      | Purpose                                                   |
| ----------------------------------------- | --------------------------------------------------------- |
| `Dockerfile`                              | Wraps the upstream nginx-proxy image and copies the snippets |
| `docker/conf.d/global-upload-limit.conf`  | Global `client_max_body_size` (default `10m`)             |
| `docker/conf.d/stub_status.conf`          | Internal `stub_status` endpoint on `:8080` for Homepage   |

## Why wrap the upstream image

The upstream image *is* the service (spec rule 6), so most of it is used as-is.
Wrapping it only exists so the `conf.d` snippets live in the image instead of
being bind-mounted from the host: config stays portable and immutable, and the
container filesystem is self-contained. `BASE_IMAGE` is therefore hardcoded
(with no tag) per spec rule 1 — the pinned tag is recorded separately in the
`NGINX_PROXY_VERSION` build arg and `ENV NGINX_PROXY_VERSION`.

## No custom entrypoint

There is **no** custom `entrypoint.sh`. The upstream entrypoint is preserved
(and generates `/etc/nginx/conf.d/default.conf` at runtime); the baked snippets
sit alongside that generated file. Nothing needs first-run seeding, so the
entrypoint requirements of spec rules 8–9 do not apply — no seeding and no
`PUID`/`PGID` privilege drop; the upstream image manages its own user.

## Build args

| Arg                   | Required | Purpose                                                        |
| --------------------- | -------- | -------------------------------------------------------------- |
| `NGINX_PROXY_VERSION` | yes      | Upstream base-image tag (`nginxproxy/nginx-proxy:<tag>`)       |
| `BUILD_DATE`          | no       | Build timestamp recorded as `ENV BUILD_DATE` (default `unknown`) |

`BASE_IMAGE` is not a build arg — it is a hardcoded `ENV` (spec rule 1).

Build (via compose):

```sh
docker compose -f docker-compose.yml -f docker-compose.lan.yml build nginx
```

## Editing the configuration

The `conf.d` snippets are copied into the image, so **editing them requires a
rebuild** (`docker compose ... build nginx` + `up -d`). To change or disable the
`stub_status` endpoint, edit `docker/conf.d/stub_status.conf` and rebuild.

## Per-host config (`vhostd`)

Per-host nginx snippets live in the `vhostd` **named volume**, mounted at
`/etc/nginx/vhost.d`. Drop a file named after the `VIRTUAL_HOST` (e.g.
`app1.localhost`) into it and reload:

```sh
docker compose exec nginx sh -c 'printf "client_max_body_size 50m;\n" > /etc/nginx/vhost.d/app1.localhost'
docker compose exec nginx nginx -s reload
```
