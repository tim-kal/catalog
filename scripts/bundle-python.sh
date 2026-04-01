#!/bin/bash
# Bundle a standalone Python interpreter with all dependencies for embedding in DriveCatalog.app
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
VENDOR_DIR="$PROJECT_DIR/vendor"
PYTHON_DIR="$VENDOR_DIR/python"
PYTHON_VERSION="3.11"

echo "==> Setting up embedded Python $PYTHON_VERSION for DriveCatalog"

# Step 1: Ensure uv has the right Python installed
echo "==> Ensuring Python $PYTHON_VERSION is available via uv..."
uv python install "$PYTHON_VERSION"

UV_PYTHON="$(uv python find "$PYTHON_VERSION")"
UV_PYTHON_ROOT="$(dirname "$(dirname "$UV_PYTHON")")"

echo "    Source: $UV_PYTHON_ROOT"

# Step 2: Copy the standalone Python tree
if [ -d "$PYTHON_DIR" ]; then
    echo "==> Removing previous vendor/python..."
    rm -rf "$PYTHON_DIR"
fi

echo "==> Copying Python to vendor/python..."
mkdir -p "$VENDOR_DIR"
cp -a "$UV_PYTHON_ROOT" "$PYTHON_DIR"

# Remove the externally-managed marker (we own this copy now)
rm -f "$PYTHON_DIR/lib/python${PYTHON_VERSION}/EXTERNALLY-MANAGED"

# Step 3: Ensure pip is available and install dependencies
echo "==> Installing pip..."
"$PYTHON_DIR/bin/python3" -m ensurepip --upgrade 2>/dev/null || true

echo "==> Installing project dependencies..."
"$PYTHON_DIR/bin/python3" -m pip install --no-cache-dir --quiet \
    'fastapi[standard]>=0.115.0' \
    'click>=8.1.0' \
    'rich>=13.0.0' \
    'xxhash>=3.0.0' \
    'watchdog>=3.0.0' \
    'ffmpeg-python>=0.2.0' \
    'pyyaml>=6.0.0'

# Step 4: Install the project itself (so `python -m drivecatalog.api` works)
echo "==> Installing drivecatalog package..."
"$PYTHON_DIR/bin/python3" -m pip install --no-cache-dir --quiet "$PROJECT_DIR"

# Step 5: Trim unnecessary files to reduce bundle size
echo "==> Trimming unnecessary files..."
find "$PYTHON_DIR" -name "__pycache__" -type d -exec rm -rf {} + 2>/dev/null || true
find "$PYTHON_DIR" -name "*.pyc" -delete 2>/dev/null || true
find "$PYTHON_DIR" -name "*.pyo" -delete 2>/dev/null || true
rm -rf "$PYTHON_DIR/include"
rm -rf "$PYTHON_DIR/share"
rm -rf "$PYTHON_DIR/lib/python${PYTHON_VERSION}/test"
rm -rf "$PYTHON_DIR/lib/python${PYTHON_VERSION}/unittest/test"
rm -rf "$PYTHON_DIR/lib/python${PYTHON_VERSION}/idlelib"
rm -rf "$PYTHON_DIR/lib/python${PYTHON_VERSION}/tkinter"
rm -rf "$PYTHON_DIR/lib/python${PYTHON_VERSION}/turtle*"
rm -rf "$PYTHON_DIR/lib/python${PYTHON_VERSION}/ensurepip"
# Remove pip itself (no longer needed at runtime)
"$PYTHON_DIR/bin/python3" -m pip uninstall pip setuptools -y --quiet 2>/dev/null || true
# Remove unnecessary bin scripts
find "$PYTHON_DIR/bin" -type f ! -name "python*" -delete 2>/dev/null || true
# Remove distutils, unused stdlib
rm -rf "$PYTHON_DIR/lib/python${PYTHON_VERSION}/distutils"
rm -rf "$PYTHON_DIR/lib/python${PYTHON_VERSION}/lib2to3"

# Step 6: Verify it works
echo "==> Verifying..."
"$PYTHON_DIR/bin/python3" -c "
import fastapi, uvicorn, click, rich, xxhash, watchdog, yaml
import drivecatalog.api.main
print(f'  FastAPI {fastapi.__version__}')
print(f'  Uvicorn {uvicorn.__version__}')
print('  drivecatalog.api.main OK')
"

SIZE=$(du -sh "$PYTHON_DIR" | cut -f1)
echo ""
echo "==> Done! Embedded Python ready at vendor/python ($SIZE)"
echo "    Binary: $PYTHON_DIR/bin/python3"
