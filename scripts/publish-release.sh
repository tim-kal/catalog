#!/bin/bash
# publish-release.sh — Create a GitHub release and update the update manifest.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
MANIFEST="$PROJECT_DIR/updates/latest.json"
REPO="tim-kal/catalog"

usage() {
    cat <<EOF
Usage: $(basename "$0") --zip PATH --version VERSION --build NUMBER [OPTIONS]

Create a GitHub release and update the update manifest.

Required:
  --zip PATH            Path to the release ZIP (from build-release.sh)
  --version VERSION     Release version (e.g. "1.3.0")
  --build NUMBER        Build number (e.g. 3)

Options:
  --notes TEXT          Release notes (inline text)
  --notes-file PATH    Read release notes from a file (e.g. updates/notes.md)
  --repo OWNER/NAME    GitHub repo (default: $REPO)
  --draft              Create as draft release
  -h, --help           Show this help message
EOF
    exit 0
}

ZIP_PATH=""
VERSION=""
BUILD_NUMBER=""
NOTES=""
NOTES_FILE=""
DRAFT=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --zip)        ZIP_PATH="$2"; shift 2 ;;
        --version)    VERSION="$2"; shift 2 ;;
        --build)      BUILD_NUMBER="$2"; shift 2 ;;
        --notes)      NOTES="$2"; shift 2 ;;
        --notes-file) NOTES_FILE="$2"; shift 2 ;;
        --repo)       REPO="$2"; shift 2 ;;
        --draft)      DRAFT="--draft"; shift ;;
        -h|--help)    usage ;;
        *)            echo "Unknown option: $1"; usage ;;
    esac
done

# Validate required arguments
if [ -z "$ZIP_PATH" ] || [ -z "$VERSION" ] || [ -z "$BUILD_NUMBER" ]; then
    echo "ERROR: --zip, --version, and --build are required."
    usage
fi

if [ ! -f "$ZIP_PATH" ]; then
    echo "ERROR: ZIP file not found: $ZIP_PATH"
    exit 1
fi

# Resolve release notes
if [ -n "$NOTES_FILE" ] && [ -f "$NOTES_FILE" ]; then
    NOTES="$(cat "$NOTES_FILE")"
elif [ -n "$NOTES_FILE" ]; then
    echo "ERROR: Notes file not found: $NOTES_FILE"
    exit 1
fi

if [ -z "$NOTES" ]; then
    NOTES="Release v${VERSION} (build ${BUILD_NUMBER})"
fi

# Check gh is available
if ! command -v gh &>/dev/null; then
    echo "ERROR: GitHub CLI (gh) is required. Install via: brew install gh"
    exit 1
fi

TAG="v${VERSION}"

# ---------- Create GitHub Release ----------

echo "==> Creating GitHub release $TAG..."

GH_ARGS=(
    release create "$TAG"
    "$ZIP_PATH"
    --repo "$REPO"
    --title "DriveCatalog $TAG"
    --notes "$NOTES"
)

if [ -n "$DRAFT" ]; then
    GH_ARGS+=("$DRAFT")
fi

RELEASE_URL=$(gh "${GH_ARGS[@]}" 2>&1)
echo "    Release: $RELEASE_URL"

# ---------- Update manifest ----------

DOWNLOAD_URL="https://github.com/${REPO}/releases/download/${TAG}/DriveCatalog.zip"

echo "==> Updating $MANIFEST..."

# Escape notes for JSON (replace newlines and quotes)
NOTES_JSON=$(printf '%s' "$NOTES" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))')

cat > "$MANIFEST" <<EOF
{
  "version": "${VERSION}",
  "build": ${BUILD_NUMBER},
  "url": "${DOWNLOAD_URL}",
  "notes": ${NOTES_JSON},
  "min_os": "14.0"
}
EOF

echo "    Manifest updated."

# ---------- Commit and push ----------

echo "==> Committing manifest update..."
(
    cd "$PROJECT_DIR"
    git add updates/latest.json
    git commit -m "release: update manifest for v${VERSION} (build ${BUILD_NUMBER})"
    git push
)

echo ""
echo "========================================"
echo "  Release published!"
echo "  Tag:      $TAG"
echo "  Download: $DOWNLOAD_URL"
echo "  Release:  $RELEASE_URL"
echo "========================================"
