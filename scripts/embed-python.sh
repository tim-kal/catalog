#!/bin/bash
# Xcode Run Script Build Phase: copy vendor/python into the app bundle and codesign binaries.
# Place this AFTER "Copy Bundle Resources" in Build Phases.
set -euo pipefail

PYTHON_SRC="${PROJECT_DIR}/vendor/python"
PYTHON_DEST="${BUILT_PRODUCTS_DIR}/${CONTENTS_FOLDER_PATH}/Resources/python"

if [ ! -d "$PYTHON_SRC" ]; then
    echo "warning: vendor/python not found — run scripts/bundle-python.sh first. Skipping embed."
    exit 0
fi

echo "==> Embedding Python into app bundle..."

# Only re-copy if source is newer than destination
if [ ! -d "$PYTHON_DEST" ] || [ "$PYTHON_SRC" -nt "$PYTHON_DEST" ]; then
    rm -rf "$PYTHON_DEST"
    rsync -a "$PYTHON_SRC/" "$PYTHON_DEST/"
    echo "    Copied vendor/python -> Resources/python"
else
    echo "    Python bundle up to date, skipping copy"
fi

# Codesign all Mach-O binaries inside the Python tree
# Use the same identity as the app (from Xcode build settings)
SIGN_IDENTITY="${EXPANDED_CODE_SIGN_IDENTITY:-}"

if [ -z "$SIGN_IDENTITY" ] || [ "$SIGN_IDENTITY" = "-" ]; then
    # Ad-hoc signing for development builds
    SIGN_IDENTITY="-"
fi

echo "==> Codesigning Python binaries (identity: ${SIGN_IDENTITY:0:20}...)..."

# Sign .so and .dylib files
find "$PYTHON_DEST" -type f \( -name "*.so" -o -name "*.dylib" \) | while read -r f; do
    codesign --force --sign "$SIGN_IDENTITY" --timestamp=none "$f" 2>/dev/null || true
done

# Sign the python3 binaries
for bin in "$PYTHON_DEST/bin/python3" "$PYTHON_DEST/bin/python3.11"; do
    if [ -f "$bin" ]; then
        codesign --force --sign "$SIGN_IDENTITY" --timestamp=none "$bin" 2>/dev/null || true
    fi
done

echo "==> Python embedding complete ($(du -sh "$PYTHON_DEST" | cut -f1))"
