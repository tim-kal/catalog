#!/bin/bash
# Xcode Run Script Build Phase: embed .secrets into the app bundle's Resources.
# Secrets are read at runtime by the Python backend. Never committed to git.
set -euo pipefail

SECRETS_SRC="${PROJECT_DIR}/.secrets"
SECRETS_DEST="${BUILT_PRODUCTS_DIR}/${CONTENTS_FOLDER_PATH}/Resources/.secrets"

if [ ! -d "$SECRETS_SRC" ]; then
    echo "warning: .secrets/ not found — bug reports will use config.yaml token or browser fallback."
    exit 0
fi

echo "==> Embedding secrets into app bundle..."
mkdir -p "$SECRETS_DEST"

# Copy only specific expected files
for secret in github_token; do
    if [ -f "$SECRETS_SRC/$secret" ]; then
        cp "$SECRETS_SRC/$secret" "$SECRETS_DEST/$secret"
        echo "    Embedded $secret"
    fi
done
