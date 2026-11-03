# Maintaining claude-sandbox

How to build, release, and keep this image healthy. For end-user install and daily use, see README.md.

---

## Repository layout

    claude-sandbox/
    Dockerfile                  Image definition (node:24-slim base, hardened)
    init-firewall.sh            Vendored from upstream Anthropic, patched
    entrypoint.sh               Container start: firewall + extra-allows + claude
    extra-allows.sh             Team-wide allowlist additions
    refresh-allows.sh           Mid-session DNS re-resolve for CDN-prone domains
    scripts/
      upgrade-firewall.sh       Sync init-firewall.sh with upstream
      release.sh                Auto-version multi-arch build + GitHub Release
      install.sh                User installer for macOS / Linux
      install.ps1               User installer for Windows
    README.md
    MAINTAINING.md
    .gitignore

---

## Cutting a release

### Simple flow

    git commit -am "Description"
    git push
    ./scripts/release.sh                  # auto-bumps patch from latest release

The script bumps the patch version (e.g. v1.0.5 -> v1.0.6) and creates the release.

### Choosing a version explicitly

    ./scripts/release.sh                  # auto patch
    ./scripts/release.sh --bump patch     # explicit patch
    ./scripts/release.sh --bump minor     # 0.1.5 -> 0.2.0
    ./scripts/release.sh --bump major     # 0.5.3 -> 1.0.0
    ./scripts/release.sh v1.2.3           # use this exact version

### What release.sh does

1. Pre-flight tools: docker, gh, buildx, gh auth status.
2. Pre-flight files: init-firewall.sh patches A & B, scripts/install.{sh,ps1} exist.
3. Verify clean working tree.
4. Determine version: query gh release list, apply bump, pick new tag.
5. Verify release doesn't already exist on GitHub.
6. Create and push the git tag.
7. Set up buildx with --driver-opt network=host.
8. Build linux/amd64 -> smoke-test -> save tarball.
9. Build linux/arm64 -> smoke-test -> save tarball.
10. Create GitHub Release with both tarballs and both install scripts attached.

If any step fails, the release isn't created — end users never see broken builds.

### Build time

| Where you run release.sh | linux/amd64 | linux/arm64 | Total |
|---|---|---|---|
| Linux x86_64 (native) | ~4 min | ~12 min QEMU | ~18 min |
| Apple Silicon Mac | ~12 min Rosetta+QEMU | ~4 min native | ~18 min |
| Intel Mac | ~4 min native | ~12 min QEMU | ~18 min |
| Windows + WSL2 | ~4 min native | ~12 min QEMU | ~18 min |

### Recovery flows

Pre-flight failed: uncommitted changes:

    git status
    git add -A && git commit -m "Fix" && git push
    ./scripts/release.sh

Pre-flight failed: release already exists on GitHub. Two options:

Option 1 — delete and recreate (cached layers, fast):

    gh release delete vX.Y.Z --repo ljanaideh/claude-sandbox --yes
    ./scripts/release.sh vX.Y.Z

Option 2 — upload to existing release without rebuilding:

    gh release upload vX.Y.Z \
        dist/claude-sandbox-amd64.tar.gz \
        dist/claude-sandbox-arm64.tar.gz \
        dist/SHA256SUMS \
        scripts/install.sh \
        scripts/install.ps1 \
        --repo ljanaideh/claude-sandbox --clobber

If you re-upload a tarball, regenerate `dist/SHA256SUMS` first (`sha256sum`/`shasum -a 256` of both tarballs, run inside `dist/`) — the installers refuse a tarball whose checksum doesn't match.

Build fails on Cloudflare R2 / Docker Hub blob fetch:

    for i in 1 2 3; do docker pull node:24-slim && break; sleep 30; done
    ./scripts/release.sh

---

## Syncing init-firewall.sh with upstream

init-firewall.sh is vendored — builds are reproducible, upstream changes don't silently break releases. Sync quarterly or as needed:

    ./scripts/upgrade-firewall.sh
    git add init-firewall.sh
    git commit -m "Sync init-firewall.sh with upstream"
    git push
    ./scripts/release.sh

If patches no longer apply, edit scripts/upgrade-firewall.sh — update the old_a Python string for the new upstream form.

### About the patches

**Patch A — DNS retry instead of fail-fast.** Upstream calls exit 1 on resolve failure. Patch replaces with three retries followed by continue.

**Patch B — ipset add -exist.** Upstream errors when the same IP is added twice (common with marketplace.visualstudio.com). Patch swaps to -exist for silent no-op on duplicates. Tracked as upstream issues #15611 and #35197.

---

## Modifying the team-wide allowlist

Edit extra-allows.sh:

    allow_domain "new-service.example.com"
    allow_domain "api.new-service.example.com"

Then commit and release. CDN-prone domains also go in refresh-allows.sh:

    CDN_DOMAINS=(
      # ... existing ...
      "api.new-service.example.com"
    )

---

## Adding a new MCP server beyond Figma

1. Allow its domains in extra-allows.sh.
2. Add usage instructions to README.md mirroring the Figma section.

All HTTP-transport MCPs reuse port 8976.

---

## Build environment requirements

- Docker (any modern version).
- docker buildx (verify with `docker buildx version`).
- QEMU emulators (auto-installed by release.sh).
- GitHub CLI (gh) authenticated with `repo` scope.
- Clean git working tree.

---

## Troubleshooting (maintainer)

| Symptom | Fix |
|---|---|
| `dial tcp 172.64.66.1:443: i/o timeout` | Buildkit can't reach Cloudflare R2. Script uses --driver-opt network=host. |
| `exec format error` on arm64 | docker run --rm --privileged tonistiigi/binfmt --install all |
| gh release create HTTP 403 | gh auth refresh -s write:packages,repo |
| gh release create HTTP 422 / "tag_name already exists" | See Recovery flows above. |
| Smoke test: `claude: not found` | Network blip during npm install. Re-run release. |
| Pre-flight: Patch B missing | ./scripts/upgrade-firewall.sh && commit |
| Build times out at metadata fetch | Pre-pull node:24-slim, then retry. |
| Install scripts missing from release assets | gh release upload ... --clobber |
| User reports `SSL certificate verification failed` inside the sandbox | Corporate TLS inspection. `claude-docker` (install.sh/.ps1) mounts the host CA bundle + sets `NODE_EXTRA_CA_CERTS`; make sure the user ran `claude-update`. Reproduce locally with a `mitmproxy/mitmproxy` container and `-e HTTPS_PROXY=http://<mitm>:8080`. |

---

## Versioning

- v0.X.Y while pre-release.
- v1.0.0 after end-to-end validation with 2-3 real users.
- Patch (v1.0.X): new domains, deps, doc fixes.
- Minor (v1.X.0): new MCP support, behavior changes.
- Major (vX.0.0): incompatible base image, breaks existing volumes.

release.sh defaults to patch. Use --bump minor or --bump major when warranted.

---

## Quarterly maintenance checklist

- Run ./scripts/upgrade-firewall.sh, review diff.
- Bump base image if node:24-slim ships a new patch.
- Check Claude Code release notes.
- Check Figma MCP changelog for OAuth domain changes.
- Cut a release.
