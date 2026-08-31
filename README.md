# merkleye/certspotter

The certspotter sidecar for [Merkleye](https://github.com/merkleye/merkleye)
— packages SSLMate's
[certspotter](https://github.com/SSLMate/certspotter) as Merkleye's primary
Certificate Transparency ingestion source, with a script hook (`hook.sh`)
that POSTs each discovered certificate to the backend and a healthcheck
(`healthcheck.sh`) that reports liveness and per-log checkpoint state.

This repo was split out of `merkleye/merkleye`'s `sidecars/certspotter/`
directory so the certspotter integration has its own build/release
lifecycle, independent of the Go backend's. The published image,
`ghcr.io/merkleye/merkleye-certspotter`, is unchanged and is what
`merkleye/merkleye`'s `deploy/docker-compose.yml` runs as the `certspotter`
service — see that repo's README and `docs/DESIGN.md` §06 for how the two
fit together.

## Layout

| Path | What |
|---|---|
| `hook.sh` | certspotter script hook → Merkleye backend |
| `healthcheck.sh` | Docker HEALTHCHECK + heartbeat/log-status POST |
| `Containerfile` | Builds `ghcr.io/merkleye/merkleye-certspotter` on top of a pinned `certspotter` release |

## CI/CD

- `.github/workflows/ci.yml` — builds the container image on every pull
  request.
- `.github/workflows/pr-preview-image.yml` — publishes a
  `ghcr.io/merkleye/merkleye-certspotter:pr-<number>` preview image per PR
  (non-fork only), cleaned up on close.
- `.github/workflows/release.yml` — manual `workflow_dispatch` on `main`;
  runs `semantic-release` (conventional commits) to version, build, and push
  a multi-arch (`linux/amd64`, `linux/arm64`) image plus SPDX SBOMs, then
  cuts a GitHub Release.

## License

Apache-2.0, matching `merkleye/merkleye`.
