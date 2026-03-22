#!/usr/bin/env bash
set -euo pipefail

# Build zeroclaw for x86_64-unknown-linux-gnu inside Docker and publish
# a GitHub Release with the single tarball + checksum.
#
# Usage:
#   scripts/release/release_sensible.sh [--dry-run]
#
# Reads version from Cargo.toml. Requires: docker, gh (authenticated), git.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DRY_RUN=false

for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=true ;;
    *) echo "Unknown option: $arg" >&2; exit 1 ;;
  esac
done

# ---------------------------------------------------------------------------
# Resolve version
# ---------------------------------------------------------------------------
VERSION=$(sed -n 's/^version = "\([^"]*\)"/\1/p' "$REPO_ROOT/Cargo.toml" | head -1)
TAG="v${VERSION}"

if [[ -z "$VERSION" ]]; then
  echo "error: could not read version from Cargo.toml" >&2
  exit 1
fi

echo "==> Version: $VERSION  Tag: $TAG"

# ---------------------------------------------------------------------------
# Preflight checks
# ---------------------------------------------------------------------------
for cmd in docker gh git; do
  if ! command -v "$cmd" &>/dev/null; then
    echo "error: $cmd is required but not found" >&2
    exit 1
  fi
done

if ! gh auth status &>/dev/null; then
  echo "error: gh is not authenticated — run 'gh auth login' first" >&2
  exit 1
fi

# Check tag doesn't already exist as a release
if gh release view "$TAG" --repo "$(gh repo view --json nameWithOwner -q .nameWithOwner)" &>/dev/null 2>&1; then
  echo "error: GitHub release $TAG already exists" >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Build inside Docker
# ---------------------------------------------------------------------------
BUILD_IMAGE="zeroclaw-build-sensible"
CARGO_FEATURES="channel-matrix,channel-lark,memory-postgres"
OUT_DIR="$REPO_ROOT/target/release-sensible"
ARTIFACT="zeroclaw-x86_64-unknown-linux-gnu.tar.gz"

mkdir -p "$OUT_DIR"

echo "==> Building Docker image for compilation..."
docker build -t "$BUILD_IMAGE" -f - "$REPO_ROOT" <<'DOCKERFILE'
FROM rust:1.92-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates pkg-config libssl-dev git perl \
  && rm -rf /var/lib/apt/lists/*

# Install Node for web dashboard build
RUN curl -fsSL https://deb.nodesource.com/setup_22.x | bash - \
  && apt-get install -y --no-install-recommends nodejs \
  && rm -rf /var/lib/apt/lists/*

WORKDIR /src
DOCKERFILE

echo "==> Building zeroclaw (x86_64-unknown-linux-gnu, release)..."
docker run --rm \
  -v "$REPO_ROOT":/src \
  -v zeroclaw-cargo-registry:/usr/local/cargo/registry \
  -v zeroclaw-cargo-git:/usr/local/cargo/git \
  -w /src \
  "$BUILD_IMAGE" \
  bash -c "
    set -euo pipefail
    echo '--- Building web dashboard ---'
    cd web && npm ci && npm run build && cd ..
    echo '--- Building zeroclaw binary ---'
    cargo build --release --locked --features '$CARGO_FEATURES' --target x86_64-unknown-linux-gnu
    echo '--- Packaging ---'
    cd target/x86_64-unknown-linux-gnu/release
    tar czf /src/target/release-sensible/$ARTIFACT zeroclaw
    echo '--- Done ---'
  "

if [[ ! -f "$OUT_DIR/$ARTIFACT" ]]; then
  echo "error: build artifact not found at $OUT_DIR/$ARTIFACT" >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Generate checksum
# ---------------------------------------------------------------------------
echo "==> Generating checksum..."
(cd "$OUT_DIR" && shasum -a 256 "$ARTIFACT" > SHA256SUMS)
cat "$OUT_DIR/SHA256SUMS"

# ---------------------------------------------------------------------------
# Publish
# ---------------------------------------------------------------------------
if [[ "$DRY_RUN" == "true" ]]; then
  echo ""
  echo "==> Dry run — skipping release creation."
  echo "    Artifact: $OUT_DIR/$ARTIFACT"
  echo "    Checksum: $OUT_DIR/SHA256SUMS"
  echo "    Would create release: $TAG"
  exit 0
fi

REPO="$(gh repo view --json nameWithOwner -q .nameWithOwner)"

echo "==> Creating GitHub release $TAG..."
gh release create "$TAG" \
  "$OUT_DIR/$ARTIFACT" \
  "$OUT_DIR/SHA256SUMS" \
  --repo "$REPO" \
  --title "$TAG" \
  --generate-notes \
  --latest

echo ""
echo "==> Release published: https://github.com/$REPO/releases/tag/$TAG"
