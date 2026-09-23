# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- First version.

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

### Deprecated

### Removed

### Fixed

### Security
