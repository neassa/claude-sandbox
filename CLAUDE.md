# claude-sandbox — Project Context

A hardened Docker sandbox for running Claude Code. Distributed as pre-built multi-arch Docker images attached to GitHub Releases. No registry involved — users download a `.tar.gz` and `docker load` it.

## Key facts

- **Repo:** `ljanaideh/claude-sandbox` on GitHub
- **Image names:** `claude-sandbox:vX.Y.Z-amd64` / `claude-sandbox:vX.Y.Z-arm64`, re-tagged to `claude-sandbox`
- **Credential persistence:** Docker named volume `claude-home` mounted at `/home/dev`
- **Figma MCP port:** `8976` (hardcoded in `claude-docker` shell function and `docker run`)
- **Base image:** `node:24-slim`

## File map

| File | Purpose |
|---|---|
| `Dockerfile` | Image definition — node:24-slim, non-root user (UID/GID 1000), tools installed |
| `init-firewall.sh` | Vendored from Anthropic upstream — **two patches applied, never overwrite manually** |
| `entrypoint.sh` | Container start: runs firewall → extra-allows → claude |
| `extra-allows.sh` | Team allowlist additions (edit here to add domains) |
| `refresh-allows.sh` | Re-resolves CDN-prone domains mid-session |
| `scripts/release.sh` | Full release automation — builds both arches, smoke-tests, publishes GitHub Release |
| `scripts/install.sh` | User installer for macOS/Linux — downloads tarball, loads image, writes shell functions |
| `scripts/install.ps1` | User installer for Windows PowerShell — same flow |
| `scripts/upgrade-firewall.sh` | Syncs `init-firewall.sh` with upstream, re-applies patches |

## Critical patches in init-firewall.sh

Both must always be present. `release.sh` pre-flight checks for them and fails if either is missing.

- **Patch A** — DNS retry: replaces `exit 1` on resolve failure with 3 retries + `continue`
  - Grep marker: `WARNING: Failed to resolve`
- **Patch B** — ipset dedup: replaces `ipset add` with `ipset add -exist` to silently skip duplicate IPs
  - Grep marker: `ipset add -exist allowed-domains`

## Release workflow

```
git commit -am "what changed"
git push
./scripts/release.sh              # auto-bumps patch
./scripts/release.sh --bump minor # bump minor
./scripts/release.sh v1.2.3       # explicit version
```

`release.sh` does everything: version bump, git tag + push, buildx setup, amd64 build + smoke test + save, arm64 build + smoke test + save, SHA256SUMS generation, GitHub Release creation with all 5 assets.

**Never run `./scripts/release.sh` on behalf of the user** — releases are human-triggered only.

## Release assets (5 per release)

- `claude-sandbox-amd64.tar.gz` (~420 MB)
- `claude-sandbox-arm64.tar.gz` (~410 MB)
- `SHA256SUMS` — checksums of both tarballs; the installers verify against it (added in v0.0.2)
- `install.sh`
- `install.ps1`

The installers fetch the tarball with curl + HTTP range resume (not `gh release download`, whose Go HTTP/2 client dies with `tls: bad record MAC` behind TLS-inspecting proxies) and verify size + SHA256.

## Shell functions installed by install.sh

- `claude-docker` — runs the container (NET_ADMIN/NET_RAW caps, project mount, volume, port 8976). Also mounts the host CA trust store over `/etc/ssl/certs/ca-certificates.crt` and sets `NODE_EXTRA_CA_CERTS` so corporate TLS inspection (WARP Gateway / Zscaler) doesn't break `claude`, curl or git inside the container. Linux: system bundle; macOS: Keychain export to `~/.claude-sandbox/ca-bundle.pem`; Windows: root-store export to `%USERPROFILE%\.claude-sandbox\ca-bundle.pem`. `CLAUDE_SANDBOX_CA_BUNDLE` overrides (`none` disables).
- `claude-update` — re-runs installer from latest release; credentials untouched
- `claude-refresh` — execs into running container to re-resolve CDN DNS

## Things to never do

- Do not modify `init-firewall.sh` directly — use `scripts/upgrade-firewall.sh` and verify patches survive
- Do not force-push or rewrite history
- Do not delete GitHub releases
- Do not run `./scripts/release.sh` — only the human triggers releases
- Do not modify files other than the three listed when doing a content update (README.md, MAINTAINING.md, scripts/release.sh)

## Testing the installer safely

```bash
HOME=$(mktemp -d) bash scripts/install.sh
```

Writes shell profile changes to a throwaway directory. Docker image load and volume check still hit the real daemon (safe — both already exist).

## Recovery: partial release assets

If a release exists but is missing assets and `dist/` has the tarballs:

```bash
gh release upload vX.Y.Z \
    dist/claude-sandbox-amd64.tar.gz \
    dist/claude-sandbox-arm64.tar.gz \
    scripts/install.sh \
    scripts/install.ps1 \
    --repo ljanaideh/claude-sandbox --clobber
```

If `dist/` is empty — do NOT rebuild. Report and let the human decide.
