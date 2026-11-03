# claude-sandbox

A hardened Docker sandbox for running Claude Code with a default-deny iptables firewall, pinned domain allowlist, non-root user, persistent credential volume, and pre-configured Figma MCP support.

The image is built once centrally and distributed via GitHub Releases. End users `docker pull`-equivalent (`docker load`) the latest tarball and use it through a small shell function. No build environment, no source files, no patches — just install and run.

---

## Quick install

### Prerequisites (one-time per machine)

- **Docker** running locally — Rancher Desktop or Docker Desktop on macOS/Windows, native Docker on Linux.
- **GitHub CLI** authenticated to your account:
  - Windows: `winget install GitHub.cli`
  - macOS: `brew install gh`
  - Linux: `sudo apt install gh`
  - Then: `gh auth login`

### Install / update (any platform)

**Windows (PowerShell):**

    gh release download -R ljanaideh/claude-sandbox -p 'install.ps1' -O "$env:TEMP\install.ps1" --clobber
    powershell -ExecutionPolicy Bypass -File "$env:TEMP\install.ps1"
    . $PROFILE

Don't pipe the script into `iex` (`... -O - | iex`): PowerShell feeds it line by line, which fails on the first blank line with `Cannot bind argument to parameter 'Command'`. Running it as a file also keeps an installer failure from closing your terminal.

The functions go into your current-host profile (`$PROFILE`, loaded last so they win over older copies), and into the PowerShell 7 profile too if you have one. The installer warns if it finds another `claude-docker` defined elsewhere.

**macOS / Linux:**

    gh release download -R ljanaideh/claude-sandbox -p 'install.sh' -O - | bash
    source ~/.zshrc      # or ~/.bashrc on bash systems

The installer detects your CPU architecture, downloads the matching tarball, loads it into Docker, creates the credentials volume, and adds `claude-docker` / `claude-update` / `claude-refresh` functions to your shell profile.

---

## First-time setup

Run the sandbox:

    claude-docker

Inside Claude:

    /login
    claude mcp add --transport http --callback-port 8976 figma https://mcp.figma.com/mcp
    /mcp

Pick **figma**, choose **Authenticate**, complete the OAuth flow in your browser. Pinning `--callback-port 8976` matches the docker-run port forwarding so Figma OAuth survives container restarts. After auth, `/exit` and re-run `claude-docker`. Figma should show `connected` without re-prompting.

---

## Daily use

    cd ~/projects/some-project
    claude-docker

Project mounts to `/workspace`. `/exit` when done.

| Inside the sandbox you can | You cannot |
|---|---|
| Read / edit files in your mounted project | Reach the internet outside the allowlist |
| Run any command Claude suggests | Affect your host laptop directly |
| Use Figma MCP for design context | Use other MCPs without adding their domains |
| Use pre-installed tools (git, jq, ripgrep, python3) | Install system packages permanently |

---

## Updates

    claude-update

`claude-update` downloads the latest release from GitHub, loads it into Docker, and re-tags it as `claude-sandbox` — replacing the old image in place. Your credentials and MCP configuration in the `claude-home` volume are untouched.

**What it does, step by step:**

1. Detects your CPU architecture (amd64 or arm64).
2. Downloads the matching tarball from the latest GitHub Release using `gh release download`.
3. Loads it into Docker with `docker load`.
4. Re-tags the loaded image as `claude-sandbox` so `claude-docker` picks it up immediately.
5. Skips recreating the `claude-home` volume if it already exists.

**When to run it:**

- A new version has been released and you want the latest Claude Code version or firewall rules.
- Figma MCP stops working after a Figma domain change (maintainers will cut a patch release).
- You're told to update as part of a troubleshooting step.

**What is preserved:**

- Your Claude login (`/login` credentials stored in `claude-home`).
- Figma MCP OAuth token (also in `claude-home`).
- The `claude-home` Docker volume itself — it is never deleted or modified by the update.

**What is replaced:**

- The Docker image layers (the OS, firewall scripts, Claude Code binary, and npm packages).
- The shell functions in your profile are refreshed to the latest version of the installer.

**To update to a specific version instead of latest:**

    TAG=v0.0.2 claude-update

Or manually:

    gh release download v0.0.2 -R ljanaideh/claude-sandbox -p 'install.sh' -O - | bash

---

## Cheat sheet

| Goal | Command |
|---|---|
| Start a session | `claude-docker` |
| Update | `claude-update` |
| Refresh CDN IPs | `claude-refresh` |
| Reset credentials | `docker volume rm claude-home && claude-docker` |
| Exit | `/exit` |

---

## Troubleshooting

| Symptom | Fix |
|---|---|
| `Cannot connect to the Docker daemon` | Start Docker / Rancher Desktop, wait for "Running." |
| `claude-docker: command not found` | Reload shell: `. $PROFILE` or `source ~/.zshrc`. |
| Works right after installing, but a **new PowerShell window** shows the old behaviour (e.g. the SSL error again) | An older `claude-docker` is defined somewhere that loads after the installed one. Find it: `Select-String -Path $PROFILE.AllUsersAllHosts,$PROFILE.AllUsersCurrentHost,$PROFILE.CurrentUserAllHosts,$PROFILE.CurrentUserCurrentHost -Pattern 'claude-docker' -ErrorAction SilentlyContinue \| Select Path,LineNumber`; delete the copies that are not inside a `# >>> claude-sandbox functions` block, then re-run the installer. Check the active one with `(Get-Command claude-docker).Definition -match 'NODE_EXTRA_CA_CERTS'` (must be True). |
| `gh: HTTP 401 Bad credentials` | `gh auth refresh` |
| `local error: tls: bad record MAC` while downloading the image | Not an auth problem: a VPN / TLS-inspecting proxy (WARP, Zscaler) killed gh's transfer mid-stream. The v0.0.2 installer no longer uses gh for the ~420 MB tarball: it downloads with curl, resumes from the last byte on every interruption, and verifies size + SHA256. Re-download the installer and run it again. Last resort: download `claude-sandbox-<arch>.tar.gz` in your browser from the [releases page](https://github.com/ljanaideh/claude-sandbox/releases) and run `.\install.ps1 -Tarball <path>` (Windows) or `TARBALL=<path> bash install.sh` (macOS/Linux); the file is verified the same way. |
| Hangs at firewall init | Wait 60s, then Ctrl+C and retry on better network. |
| `Unable to connect to API: SSL certificate verification failed` | Corporate TLS inspection (WARP Gateway, Zscaler) is re-signing HTTPS with a CA the image doesn't trust. `claude-docker` passes your host trust store into the container automatically since v0.0.2 — run `claude-update`. To use a specific bundle: `CLAUDE_SANDBOX_CA_BUNDLE=/path/to/bundle.pem claude-docker` (`none` disables). |
| `WARNING: Failed to resolve <domain>` at startup | Harmless — the firewall skips domains that don't resolve and continues. |
| Figma `failed` after auth | `/exit`, then `claude-docker`. |
| Everything broken | `docker volume rm claude-home && claude-update && claude-docker` |

---

## Releasing new versions (maintainers only)

Full runbook: MAINTAINING.md. Short version:

    git commit -am "Description of what changed"
    git push
    ./scripts/release.sh                  # auto-bumps patch from latest release

Other version flags:

    ./scripts/release.sh --bump minor     # 0.1.5 -> 0.2.0
    ./scripts/release.sh --bump major     # 0.5.3 -> 1.0.0
    ./scripts/release.sh v1.2.3           # explicit

The release script creates and pushes the git tag, builds multi-arch (amd64 + arm64), smoke-tests both, attaches install scripts to the release. About 12-18 minutes per release.
