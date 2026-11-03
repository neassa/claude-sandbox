---
name: claude-sandbox
description: Use when working in the claude-sandbox repo — updating files, managing releases, fixing release assets, or testing the installer without affecting the user's environment
---

# claude-sandbox

Reference guide for working on the `ljanaideh/claude-sandbox` project.

## Key constraints

- **Never run `./scripts/release.sh`** — releases are human-triggered only
- **Never force-push or delete releases**
- **Only edit README.md, MAINTAINING.md, scripts/release.sh** for content updates unless explicitly told otherwise
- **Never touch `init-firewall.sh` directly** — patches must survive any sync

## Patch verification (pre-flight check)

`release.sh` will fail if either patch is missing from `init-firewall.sh`:

| Patch | Grep marker |
|---|---|
| A — DNS retry | `WARNING: Failed to resolve` |
| B — ipset dedup | `ipset add -exist allowed-domains` |

## Common tasks

**Update content files and push:**
```bash
# Edit README.md / MAINTAINING.md / scripts/release.sh
bash -n scripts/release.sh        # validate bash syntax before committing
git add README.md MAINTAINING.md scripts/release.sh
git commit -m "description"
git push
```

**Check release asset state:**
```bash
gh release view vX.Y.Z --repo ljanaideh/claude-sandbox --json assets --jq '.assets[] | .name'
```

**Fix partial release (assets missing, dist/ has tarballs):**
```bash
gh release upload vX.Y.Z \
    dist/claude-sandbox-amd64.tar.gz \
    dist/claude-sandbox-arm64.tar.gz \
    scripts/install.sh \
    scripts/install.ps1 \
    --repo ljanaideh/claude-sandbox --clobber
```
If `dist/` is empty — stop, report, let the human decide.

**Test installer without touching user's shell profile:**
```bash
HOME=$(mktemp -d) bash scripts/install.sh
```
Docker image load and volume check still hit the real daemon — safe because both already exist.

## Release asset sizes (expected)

| Asset | Size |
|---|---|
| `claude-sandbox-amd64.tar.gz` | ~374 MB |
| `claude-sandbox-arm64.tar.gz` | ~367 MB |
| `install.sh` | ~3 KB |
| `install.ps1` | ~4 KB |

## What persists across updates

`claude-home` Docker volume (credentials, Figma MCP OAuth) — never deleted by installer or update.

## Full project context

See `CLAUDE.md` in the repo root for the complete file map, patch details, and recovery procedures.
