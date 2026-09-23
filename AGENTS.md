# AGENTS.md — docker-nginx-proxy

Ongoing rules for agents working in this repo. This is a summary, not a copy:
detail lives in `README.md`, `certgen/README.md`, and the authoritative spec at
`/specs/COMPOSE-SPEC.md`.

## Keep the spec in sync (do this on every change)

- `/specs/COMPOSE-SPEC.md` is the source of truth for the compose conventions
  this repo implements, including the **downstream proxy contract**.
- Whenever this project changes in a way that touches those conventions —
  compose file layout, variant selection, env var names/contract, proxy or
  certificate behaviour, `.env`/`env.example` shape, docs — **remind the user
  that `/specs/COMPOSE-SPEC.md` likely needs updating**. Do not call the change
  done until the spec is updated, or the user explicitly defers.
- Keep `README.md` and `certgen/README.md` in sync with the same changes.
- Follow the spec's `CHANGELOG.md` discipline (Keep a Changelog; add entries
  under `## [Unreleased]` as changes land).

## Ongoing rules

- **Config in `.env` only.** All deployment config lives in `.env` (gitignored);
  `env.example` is the tracked source of truth for its shape. Keep both in the
  same order and shape; every variable keeps its own comment.
- **Fail fast.** Required vars use `${VAR:?...}`; optional vars use
  `${VAR:-default}` and are documented as optional.
- **Variants via `COMPOSE_FILE`.** The base `docker-compose.yml` is
  variant-neutral; one override per variant (`docker-compose.lan.yml`,
  `docker-compose.public.yml`), selected by `COMPOSE_FILE` in `.env`. The LAN
  variant runs `certgen` (self-signed); the public variant runs `acme-companion`;
  neither variant runs both.
- **No downstream `ports:`.** The proxy owns 80/443; downstream services attach
  to the proxy network and advertise via `expose:`.
- **Downstream services are variant-agnostic and declare their complete
  contract.** Every applicable var is set — `VIRTUAL_HOST` always,
  `VIRTUAL_PORT` / `VIRTUAL_PROTO` where the defaults do not fit, and for HTTPS
  **both** TLS opt-ins: `ACME_HOST` (internet variant) and
  `GEN_SELF_SIGNED_CERT=true` (LAN variant). The proxy honours only the opt-in
  matching its variant; the other is inert. Omitting a var fails silently (no
  routing / HTTP-only), and `ACME_HOST`/`GEN_SELF_SIGNED_CERT` must be exact,
  filename-safe hostnames. See the spec's "Downstream proxy contract".
- **Hostnames come from `x-hosts` anchors**, never copy-pasted literals.
- **Named volumes over bind mounts.** `conf.d` snippets are baked into the
  built `nginx` image (`nginx/docker/conf.d/`); per-host `vhost.d` config is the
  `vhostd` named volume; the Docker socket is the only bind mount.
- `restart: unless-stopped`; carry Homepage labels on services.

## Verify before reporting done

- `docker compose config` (uses `COMPOSE_FILE` from `.env`) passes; public:
  `ACME_EMAIL=you@example.com docker compose -f docker-compose.yml -f docker-compose.public.yml config`.
- `sh -n` on `certgen/docker/*.sh`.
- Build: `docker compose -f docker-compose.yml -f docker-compose.lan.yml build certgen`.
- Walk the spec's review checklist at `/specs/COMPOSE-SPEC.md`.
