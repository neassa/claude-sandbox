#!/bin/bash
# Install or update the Claude Sandbox on macOS or Linux.
# Usage: gh release download -R ljanaideh/claude-sandbox -p 'install.sh' -O - | bash
set -euo pipefail

REPO="${REPO:-ljanaideh/claude-sandbox}"
TAG="${TAG:-latest}"
IMAGE="${IMAGE:-claude-sandbox}"
VOLUME="${VOLUME:-claude-home}"
# Path to an already-downloaded claude-sandbox-<arch>.tar.gz (skips gh download).
TARBALL="${TARBALL:-${CLAUDE_SANDBOX_TARBALL:-}}"

step() { echo "==> $1"; }
ok()   { echo "  [ok]      $1"; }
chg()  { echo "  [changed] $1"; }
fail() { echo "  [FAIL]    $1"; exit 1; }

step "Pre-flight"
command -v docker >/dev/null || fail "Docker not installed"
docker version >/dev/null 2>&1 || fail "Docker daemon not running. Start Docker Desktop or Rancher Desktop."
ok "Docker reachable"
command -v gh >/dev/null || fail "gh CLI not installed (macOS: brew install gh; Linux: apt install gh)"
ok "gh CLI installed"

case "$(uname -m)" in
    x86_64|amd64) ARCH=amd64 ;;
    arm64|aarch64) ARCH=arm64 ;;
    *) fail "Unsupported architecture: $(uname -m)" ;;
esac
ok "Architecture: $ARCH"

step "Downloading image"
ASSET="claude-sandbox-${ARCH}.tar.gz"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# Release metadata in one API call: tag | asset API url | asset size | SHA256SUMS url.
# '|' as separator because `read` with IFS=tab collapses empty fields.
REL_API="repos/$REPO/releases/latest"
[ "$TAG" = "latest" ] || REL_API="repos/$REPO/releases/tags/$TAG"
REL_TAG="" ASSET_URL="" ASSET_SIZE="" SUMS_URL=""
if REL_META=$(gh api "$REL_API" --jq "[.tag_name,
        ((.assets[] | select(.name == \"$ASSET\") | .url) // \"\"),
        ((.assets[] | select(.name == \"$ASSET\") | .size) // \"\"),
        ((.assets[] | select(.name == \"SHA256SUMS\") | .url) // \"\")]
        | map(tostring) | join(\"|\")" 2>/dev/null); then
    IFS='|' read -r REL_TAG ASSET_URL ASSET_SIZE SUMS_URL <<< "$REL_META"
fi

# Download with curl + HTTP range resume. A stream killed mid-way by a VPN or
# TLS-inspecting proxy ("local error: tls: bad record MAC" from gh's Go client)
# continues from the last byte instead of starting over; the result is then
# verified by size and, when the release publishes SHA256SUMS, by checksum.
GH_TOKEN_VALUE=""
fetch_asset() {  # $1 = asset API url, $2 = destination, $3 = expected size ("" = unknown), $4 = "quiet" to hide the progress bar
    local url="$1" dest="$2" size="$3" quiet="${4:-}" attempt have http progress
    progress="--progress-bar"
    [ -n "$quiet" ] && progress="-s"
    [ -n "$GH_TOKEN_VALUE" ] || GH_TOKEN_VALUE="$(gh auth token)"
    for attempt in $(seq 1 10); do
        have=0
        [ -f "$dest" ] && have=$(wc -c < "$dest" | tr -d ' ')
        if [ -n "$size" ] && [ "$have" -eq "$size" ]; then return 0; fi
        if [ -n "$size" ] && [ "$have" -gt "$size" ]; then rm -f "$dest"; have=0; fi
        [ "$attempt" -gt 1 ] && echo "  [retry]   attempt $attempt, resuming from $((have / 1048576)) MB..."
        # Authorization is only sent to api.github.com; curl drops it on the
        # redirect to the asset CDN, which is what the signed CDN URL expects.
        # No curl --retry: its internal retries restart from the offset of the
        # first request and discard bytes fetched since; this loop resumes
        # from the real end of the file instead. The progress bar briefly
        # shows 100% for the tiny API redirect response before the real one.
        if http=$(curl -fSL $progress -C - \
                -H "Authorization: Bearer $GH_TOKEN_VALUE" \
                -H "Accept: application/octet-stream" \
                -o "$dest" -w '%{http_code}' "$url"); then
            return 0
        fi
        case "$http" in
            416) return 0 ;;                      # range not satisfiable: file already complete
            408|429) ;;                           # timeout / rate limit: retry
            4[0-9][0-9]) echo "  [FAIL]    HTTP $http for $url"; return 1 ;;   # permanent: don't retry
        esac
        sleep $((3 * attempt))
    done
    return 1
}

verify_asset() {  # $1 = file, $2 = asset name, $3 = expected size ("" = unknown)
    local file="$1" name="$2" size="$3" have expected actual sums
    if [ -z "$REL_TAG" ]; then
        echo "  [warn]    could not reach the GitHub API; skipping verification"
        return 0
    fi
    have=$(wc -c < "$file" | tr -d ' ')
    if [ -n "$size" ] && [ "$have" -ne "$size" ]; then
        echo "  [FAIL]    $name is $have bytes, release $REL_TAG says $size"
        return 1
    fi
    if [ -z "$SUMS_URL" ]; then
        ok "Size verified ($have bytes); release $REL_TAG publishes no SHA256SUMS"
        return 0
    fi
    sums="$TMP/SHA256SUMS"
    rm -f "$sums"
    if ! fetch_asset "$SUMS_URL" "$sums" "" quiet; then
        echo "  [warn]    could not download SHA256SUMS; size check only"
        return 0
    fi
    expected=$(awk -v n="$name" '$2 == n || $2 == "*" n {print tolower($1)}' "$sums")
    if [ -z "$expected" ]; then
        echo "  [warn]    no SHA256SUMS entry for $name; size check only"
        return 0
    fi
    if command -v sha256sum >/dev/null 2>&1; then
        actual=$(sha256sum "$file" | awk '{print tolower($1)}')
    else
        actual=$(shasum -a 256 "$file" | awk '{print tolower($1)}')
    fi
    if [ "$expected" != "$actual" ]; then
        echo "  [FAIL]    SHA256 mismatch for $name"
        return 1
    fi
    ok "SHA256 verified"
}

downloaded=0
if [ -n "$TARBALL" ]; then
    [ -f "$TARBALL" ] || fail "Tarball not found: $TARBALL"
    TARBALL_PATH="$TARBALL"
    ok "Using local tarball $TARBALL"
    verify_asset "$TARBALL_PATH" "$ASSET" "$ASSET_SIZE" \
        || fail "Local tarball does not match release $REL_TAG. Download it again."
else
    if [ -z "$ASSET_URL" ]; then
        gh auth status >/dev/null 2>&1 || fail "gh is not authenticated. Run: gh auth login"
        fail "Release asset $ASSET not found for '$TAG' in $REPO"
    fi
    # Stable location so a partial download from an earlier run is resumed.
    DL_DIR="${TMPDIR:-/tmp}/claude-sandbox-install"
    mkdir -p "$DL_DIR"
    TARBALL_PATH="$DL_DIR/$REL_TAG-$ASSET"
    echo "  downloading $ASSET ($((ASSET_SIZE / 1048576)) MB) for $REL_TAG - resumable, re-run if interrupted"
    if command -v curl >/dev/null 2>&1; then
        fetch_asset "$ASSET_URL" "$TARBALL_PATH" "$ASSET_SIZE" \
            || fail "Download failed after 10 resumable attempts. The partial file is kept at $TARBALL_PATH - re-run to continue, or download $ASSET in your browser from https://github.com/$REPO/releases/tag/$REL_TAG and re-run with TARBALL=/path/to/$ASSET"
    else
        # No curl: fall back to gh, forced to HTTP/1.1 (Go's HTTP/2 client is
        # what TLS-inspecting proxies most often break).
        GODEBUG=http2client=0 gh release download "$REL_TAG" -R "$REPO" -p "$ASSET" -O "$TARBALL_PATH" --clobber \
            || fail "gh download failed. Download $ASSET in your browser from https://github.com/$REPO/releases/tag/$REL_TAG and re-run with TARBALL=/path/to/$ASSET"
    fi
    verify_asset "$TARBALL_PATH" "$ASSET" "$ASSET_SIZE" \
        || { rm -f "$TARBALL_PATH"; fail "Downloaded file failed verification and was deleted. Re-run to download again."; }
    ok "Downloaded $ASSET"
    downloaded=1
fi

step "Loading image"
docker load -i "$TARBALL_PATH"
if [ "$downloaded" -eq 1 ]; then rm -f "$TARBALL_PATH"; fi
chg "Image loaded"

LOADED=$(docker images --format '{{.Repository}}:{{.Tag}}' | grep -E "^claude-sandbox:.*-${ARCH}$" | head -1)
[ -n "$LOADED" ] || fail "Loaded image not found"
docker tag "$LOADED" "$IMAGE"
chg "Tagged $LOADED -> $IMAGE"

if docker volume ls --format '{{.Name}}' | grep -qx "$VOLUME"; then
    ok "Volume '$VOLUME' exists"
else
    docker volume create "$VOLUME" >/dev/null
    chg "Volume '$VOLUME' created"
fi

step "Updating shell profile"
if [ "$(basename "$SHELL")" = "zsh" ]; then
    PROFILE="$HOME/.zshrc"
elif [ -f "$HOME/.bashrc" ]; then
    PROFILE="$HOME/.bashrc"
else
    PROFILE="$HOME/.bash_profile"
fi
[ -f "$PROFILE" ] || touch "$PROFILE"

# Quoted heredoc: nothing is expanded here; __VOLUME__/__IMAGE__/__REPO__ are
# substituted below so the block can use $ freely.
BLOCK=$(cat <<'EOF'

# >>> claude-sandbox functions (managed by install.sh) >>>
# Host CA passthrough: corporate TLS inspection (Cloudflare WARP Gateway,
# Zscaler, ...) re-signs HTTPS with a private CA the image does not trust,
# which surfaces as "Unable to connect to API: SSL certificate verification
# failed". Mount the host trust store over the container's bundle and point
# Node at it. Override with CLAUDE_SANDBOX_CA_BUNDLE=/path/to/bundle.pem;
# set it to "none" to disable.
claude-docker() {
    local ca_bundle="${CLAUDE_SANDBOX_CA_BUNDLE:-}" f
    if [ -z "$ca_bundle" ]; then
        for f in /etc/ssl/certs/ca-certificates.crt /etc/pki/tls/certs/ca-bundle.crt /etc/ssl/cert.pem; do
            if [ -f "$f" ]; then ca_bundle="$f"; break; fi
        done
    fi
    if [ -z "$ca_bundle" ] && [ "$(uname -s)" = "Darwin" ]; then
        # macOS keeps trust in Keychain; export system + root CAs to a PEM file.
        ca_bundle="$HOME/.claude-sandbox/ca-bundle.pem"
        mkdir -p "$HOME/.claude-sandbox"
        security find-certificate -a -p \
            /Library/Keychains/System.keychain \
            /System/Library/Keychains/SystemRootCertificates.keychain \
            > "$ca_bundle" 2>/dev/null || ca_bundle=""
    fi
    local -a ca_args=()
    if [ -n "$ca_bundle" ] && [ "$ca_bundle" != "none" ] && [ -s "$ca_bundle" ]; then
        ca_args=(-v "$ca_bundle:/etc/ssl/certs/ca-certificates.crt:ro"
                 -e NODE_EXTRA_CA_CERTS=/etc/ssl/certs/ca-certificates.crt)
    fi
    docker run -it --rm \
        --cap-add=NET_ADMIN --cap-add=NET_RAW \
        -v "$(pwd):/workspace" \
        -v __VOLUME__:/home/dev \
        -p 127.0.0.1:8976:8976 \
        -w /workspace \
        "${ca_args[@]}" \
        __IMAGE__ "$@"
}
claude-update() {
    curl -fsSL https://github.com/__REPO__/releases/latest/download/install.sh | bash
}
claude-refresh() {
    local cid=$(docker ps -q --filter ancestor=__IMAGE__ | head -1)
    if [ -z "$cid" ]; then echo "No running __IMAGE__ container."; return; fi
    docker exec -u root "$cid" /usr/local/bin/refresh-allows.sh
}
# <<< claude-sandbox functions <<<
EOF
)
BLOCK=${BLOCK//__VOLUME__/$VOLUME}
BLOCK=${BLOCK//__IMAGE__/$IMAGE}
BLOCK=${BLOCK//__REPO__/$REPO}

if grep -q "# >>> claude-sandbox functions" "$PROFILE"; then
    sed -i.bak '/# >>> claude-sandbox functions/,/# <<< claude-sandbox functions/d' "$PROFILE"
    rm -f "$PROFILE.bak"
    chg "Replaced existing managed block in $PROFILE"
else
    chg "Added managed block to $PROFILE"
fi
echo "$BLOCK" >> "$PROFILE"

# Any claude-* function defined outside a managed block (e.g. a hand-written
# claude-docker from before the installer) may override ours if it loads later.
conflicts=0
for f in "$HOME/.bashrc" "$HOME/.zshrc" "$HOME/.bash_profile" "$HOME/.profile"; do
    [ -f "$f" ] || continue
    while IFS= read -r line; do
        echo "  [WARN]    $line outside the managed block. It may override the installed one - delete it."
        conflicts=$((conflicts + 1))
    done < <(awk -v f="$f" '
        /# >>> claude-sandbox functions/ { b = 1 }
        /# <<< claude-sandbox functions/ { b = 0; next }
        !b && /^[[:space:]]*(function[[:space:]]+)?claude-(docker|update|refresh)[[:space:]]*(\(\)|\{)/ {
            printf "%s:%d defines %s", f, NR, $0
            print ""
        }' "$f")
done
[ "$conflicts" -eq 0 ] && ok "No conflicting claude-* definitions in shell profiles"

echo ""
echo "Done. Reload: source $PROFILE"
echo "Then run:    claude-docker"
