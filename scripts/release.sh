#!/bin/bash
# Build the multi-arch image locally and publish to GitHub Releases.
#
# Usage:
#   ./scripts/release.sh                    # auto-bump patch from latest release
#   ./scripts/release.sh --bump minor       # bump minor version
#   ./scripts/release.sh --bump major       # bump major version
#   ./scripts/release.sh v1.2.3             # use this exact version

set -euo pipefail

REPO="ljanaideh/claude-sandbox"

cd "$(git rev-parse --show-toplevel)"

# --- 1. Pre-flight ---
echo "==> Pre-flight"

command -v docker >/dev/null || { echo "FAIL: docker not installed"; exit 1; }
command -v gh     >/dev/null || { echo "FAIL: gh CLI not installed"; exit 1; }
docker buildx version >/dev/null 2>&1 || { echo "FAIL: docker buildx not available"; exit 1; }
gh auth status >/dev/null 2>&1 || { echo "FAIL: gh CLI not authenticated. Run: gh auth login"; exit 1; }

grep -q "WARNING: Failed to resolve"          init-firewall.sh \
    || { echo "FAIL: Patch A missing in init-firewall.sh"; exit 1; }
grep -q "ipset add -exist allowed-domains"    init-firewall.sh \
    || { echo "FAIL: Patch B missing in init-firewall.sh"; exit 1; }
echo "  patches verified"

[ -f scripts/install.sh ]  || { echo "FAIL: scripts/install.sh missing"; exit 1; }
[ -f scripts/install.ps1 ] || { echo "FAIL: scripts/install.ps1 missing"; exit 1; }
echo "  install scripts present"

if ! git diff-index --quiet HEAD --; then
    echo "FAIL: uncommitted changes - commit or stash first"
    git status --short
    exit 1
fi
echo "  git tree clean"

# --- 2. Determine TAG ---
echo "==> Determining release version"

bump_version() {
    local current="$1"
    local part="$2"
    if [[ ! "$current" =~ ^v([0-9]+)\.([0-9]+)\.([0-9]+)$ ]]; then
        echo "FAIL: '$current' isn't semver (vX.Y.Z) - specify version explicitly" >&2
        exit 1
    fi
    local major="${BASH_REMATCH[1]}"
    local minor="${BASH_REMATCH[2]}"
    local patch="${BASH_REMATCH[3]}"
    case "$part" in
        major) major=$((major+1)); minor=0; patch=0 ;;
        minor) minor=$((minor+1)); patch=0 ;;
        patch) patch=$((patch+1)) ;;
        *) echo "FAIL: invalid bump part '$part'" >&2; exit 1 ;;
    esac
    echo "v${major}.${minor}.${patch}"
}

LATEST=$(gh release list --repo "$REPO" --limit 1 --json tagName --jq '.[0].tagName // ""' 2>/dev/null || echo "")

if [ $# -eq 0 ]; then
    if [ -z "$LATEST" ]; then
        TAG="v0.0.1"
        echo "  no previous releases, starting at $TAG"
    else
        TAG=$(bump_version "$LATEST" patch)
        echo "  last release: $LATEST -> bumping patch -> $TAG"
    fi
elif [ "$1" = "--bump" ] && [ $# -eq 2 ]; then
    if [ -z "$LATEST" ]; then
        TAG="v0.0.1"
        echo "  no previous releases, starting at $TAG"
    else
        TAG=$(bump_version "$LATEST" "$2")
        echo "  last release: $LATEST -> bumping $2 -> $TAG"
    fi
elif [[ "$1" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    TAG="$1"
    echo "  using explicit version $TAG"
else
    echo "FAIL: invalid argument '$1'"
    echo "Usage: $0 [vX.Y.Z | --bump patch|minor|major]"
    exit 1
fi

# --- 3. Verify release doesn't already exist on GitHub ---
if gh release view "$TAG" --repo "$REPO" >/dev/null 2>&1; then
    echo "FAIL: release $TAG already exists on GitHub"
    echo "       To recreate: gh release delete $TAG --repo $REPO --yes"
    echo "       To skip:     pick a different version"
    exit 1
fi
echo "  no existing release for $TAG"

# --- 4. Create and push the git tag ---
if git rev-parse "$TAG" >/dev/null 2>&1; then
    echo "  tag $TAG already exists locally"
else
    git tag "$TAG"
    echo "  created local tag $TAG"
fi
git push origin "$TAG" 2>&1 | sed 's/^/  /' || true

# --- 5. Buildx + QEMU ---
echo ""
echo "==> Setting up buildx + QEMU (host networking)"
docker run --rm --privileged tonistiigi/binfmt --install all >/dev/null 2>&1 || true
docker buildx rm claude-sandbox-builder >/dev/null 2>&1 || true
docker buildx create \
    --name claude-sandbox-builder \
    --driver-opt network=host \
    --use >/dev/null
docker buildx inspect --bootstrap >/dev/null

mkdir -p dist

# --- 6. Build, test, save each arch ---
build_one() {
    local arch=$1
    echo ""
    echo "==> Building linux/$arch"
    docker buildx build \
        --platform "linux/$arch" \
        --build-arg UID=1000 --build-arg GID=1000 \
        -t "claude-sandbox:${TAG}-${arch}" \
        --load .

    echo "==> Smoke test linux/$arch"
    docker run --rm --platform "linux/$arch" \
        --entrypoint claude \
        "claude-sandbox:${TAG}-${arch}" --version

    echo "==> Saving linux/$arch"
    docker save "claude-sandbox:${TAG}-${arch}" \
        | gzip > "dist/claude-sandbox-${arch}.tar.gz"
}

build_one amd64
build_one arm64

echo ""
echo "==> Checksums (installers verify the tarball against SHA256SUMS)"
(
    cd dist
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum claude-sandbox-amd64.tar.gz claude-sandbox-arm64.tar.gz
    else
        shasum -a 256 claude-sandbox-amd64.tar.gz claude-sandbox-arm64.tar.gz
    fi
) > dist/SHA256SUMS
cat dist/SHA256SUMS

echo ""
echo "==> Build artifacts"
ls -lh dist/

# --- 7. Create the GitHub Release ---
echo ""
echo "==> Creating GitHub Release"
gh release create "$TAG" \
    dist/claude-sandbox-amd64.tar.gz \
    dist/claude-sandbox-arm64.tar.gz \
    dist/SHA256SUMS \
    scripts/install.sh \
    scripts/install.ps1 \
    --repo "$REPO" \
    --title "$TAG" \
    --generate-notes

echo ""
echo "Done. Release: https://github.com/$REPO/releases/tag/$TAG"
