# merkleye/certspotter

The certspotter sidecar for [Merkleye](https://github.com/merkleye/merkleye)
— packages SSLMate's
[certspotter](https://github.com/SSLMate/certspotter) as Merkleye's primary
Certificate Transparency ingestion source, with a script hook (`hook.sh`)
that POSTs each discovered certificate to the backend, a healthcheck
(`healthcheck.sh`) that reports liveness and per-log checkpoint state, and a
supervisor (`supervise.sh`) that owns the certspotter process — certspotter
reads `-watchlist` once at startup with no reload signal, so `supervise.sh`
long-polls the backend for watch-set changes and restarts certspotter to
apply them (ADR-0060).

This repo was split out of `merkleye/merkleye`'s `sidecars/certspotter/`
directory so the certspotter integration has its own build/release
lifecycle, independent of the Go backend's. The published image,
`ghcr.io/merkleye/certspotter`, is what `merkleye/merkleye`'s
`deploy/docker-compose.yml` runs as the `certspotter` service — see that
repo's README and `docs/DESIGN.md` §06 for how the two fit together. It's a
new package name (not the `ghcr.io/merkleye/merkleye-certspotter` the old
monorepo published under), scoped to this repo so its own `GITHUB_TOKEN` can
push to it without a separate GHCR access grant.

## Layout

| Path | What |
|---|---|
| `hook.sh` | certspotter script hook → Merkleye backend |
| `healthcheck.sh` | Docker HEALTHCHECK + heartbeat/log-status POST |
| `supervise.sh` | Owns the certspotter process; pulls the watch set from the backend and restarts certspotter to apply changes |
| `Containerfile` | Builds `ghcr.io/merkleye/certspotter` on top of a pinned `certspotter` release |
| `tests/` | bats suite for `hook.sh`, `healthcheck.sh` and `supervise.sh`, run via `mise run test` |

## Testing

`mise run test` installs [bats-core](https://github.com/bats-core/bats-core)
and [bashcov](https://github.com/infertux/bashcov), then runs
`tests/*.bats` under bashcov and gates on a 100% statement-coverage floor
(`tests/coverage_report.sh`). `supervise.sh`'s functions are unit-tested by
sourcing the script directly (`SUPERVISE_SOURCE_ONLY=1` skips its top-level
boot/refresh loop, which isn't itself a function — see the script's own
comment); that loop is instead covered by `tests/supervise_integration.bats`,
which runs the real script as a subprocess against a fake `certspotter`
binary and a scripted fake `curl` (`tests/bin/`).

## CI/CD

- `.github/workflows/ci.yml` — runs the bats suite (100% statement-coverage
  floor, `mise run test`) and builds the container image on every pull
  request.
- `.github/workflows/pr-preview-image.yml` — publishes a
  `ghcr.io/merkleye/certspotter:pr-<number>` preview image per PR
  (non-fork only), cleaned up on close.
- `.github/workflows/release.yml` — manual `workflow_dispatch` on `main`;
  runs `semantic-release` (conventional commits) to version, build, and push
  a multi-arch (`linux/amd64`, `linux/arm64`) image plus SPDX SBOMs, then
  cuts a GitHub Release.

## License

Apache-2.0
