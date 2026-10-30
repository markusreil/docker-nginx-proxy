# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Fixed

- `certgen` removal grace no longer stalls all cert generation: `reconcile`
  previously `sleep`ed `GEN_REMOVAL_GRACE` (default 1 day) while holding the
  lock whenever any host stopped opting in, wedging the `docker-gen` watch
  loop so newly (re)started containers got no cert (surfaced as
  `SSL_ERROR_UNRECOGNIZED_NAME_ALERT`). Grace is now per-host timestamps in
  `certs/.certgen.pending`; reconciles never sleep, stale hosts keep serving
  their existing cert until their own grace expires, and hosts that re-opt
  in re-use their cert. Note: hosts already stale at upgrade get a fresh
  grace window starting at the first reconcile after redeploy.

### Added

- First version.
- Optional local-CA signing for `certgen`: when `ca.crt`/`ca.key` are present
  in the `certs` volume (paths overridable via `CA_CRT`/`CA_KEY`), host certs
  are signed by that CA (leaf + chain in `<host>.crt`) instead of being
  self-signed; otherwise the self-signed behavior is unchanged. The name `ca`
  is reserved so an opted-in host cannot clobber the CA pair. New helper
  `bin/create-ca.sh` generates a CA into the volume (cert goes to stdout or
  `--out PATH`, nothing is written into the checkout). Renamed to
  `certgen-ca.crt`/`certgen-ca.key` (was `ca.crt`/`ca.key`): nginx-proxy
  treats a `ca.crt` in its certs dir as a client-verification CA and switches
  every vhost to mTLS (`ssl_verify_client` defaults to `on`); the new names
  are ignored by the proxy. `bin/create-ca.sh --force` migrates an old-named
  CA (installs the new names, removes the legacy pair).

### Changed

- README downstream examples now declare the **complete** proxy contract:
  both TLS opt-ins (`ACME_HOST` + `GEN_SELF_SIGNED_CERT`) on every proxied
  service, plus a note that omitting a variable fails silently and that the
  proxy network is created by this cluster and must be joined as `external`.
- Corrected the real-cert example: a plain HTTP backend (`VIRTUAL_PORT` "3000")
  instead of an app on 443 without `VIRTUAL_PROTO: https`.
- `AGENTS.md` downstream rule now states every applicable var must be set.
- Renamed the cluster contact-email variable `LE_EMAIL` → `ACME_EMAIL` (still
  wired to `acme-companion`'s `DEFAULT_EMAIL`). Updated `.env`, `env.example`,
  `docker-compose.public.yml`, `README.md`, and `AGENTS.md`. **Breaking**:
  existing `.env` files must rename the variable.
- Standardized the docs on the `ACME_*` env spelling for every ACME variable;
  the `LETSENCRYPT_*` aliases are deprecated and must not be used. The staging
  toggle stays `LETSENCRYPT_TEST` (it has no `ACME_` spelling).
- `GEN_REMOVAL_GRACE` default is now 1 day (`86400`, was `30`): short cluster
  stop/starts keep their certs instead of deleting and re-minting them
  (which retriggered the browser warning).
- New `maxbody` sidecar (wired into the base compose file, runs in every
  variant): writes one `/etc/nginx/vhost.d/<host>` file per downstream
  container that sets `NGINX_MAX_BODY_SIZE` (`client_max_body_size <size>;`) and
  reloads nginx; removal is prompt with fallback to the global `10m`.
  Invalid sizes are ignored with a warning.

### Deprecated

### Removed

### Fixed

### Security
