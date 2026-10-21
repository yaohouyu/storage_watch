#!/bin/bash
# Build Storage Watch into a self-contained .app bundle.
#
#   ./build-app.sh                 # build with embedded Python runtime
#   ./build-app.sh --no-python     # build without it (development, uses local Python)
#
# The embedded runtime is fetched once and cached in build/cache/.
set -euo pipefail
cd "$(dirname "$0")"

OUT="build"
EMBED_PYTHON=1
for arg in "$@"; do
  case "$arg" in
    --no-python) EMBED_PYTHON=0 ;;
    --out=*) OUT="${arg#--out=}" ;;
    *) ;;
  esac
done

APP="$OUT/Storage Watch.app"
PY_VERSION="3.12.15"
PY_DATE="20261020"
PY_CACHE="$OUT/cache/python-$PY_VERSION"
ARCH="$(uname -m)"
case "$ARCH" in
  arm64) PY_ARCH="aarch64" ;;
  x86_64) PY_ARCH="x86_64" ;;
  *) echo "不支持的架构：$ARCH" >&2; exit 1 ;;
esac

mkdir -p "$OUT"
export CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-/tmp/storagewatch-clang-cache}"
export MACOSX_DEPLOYMENT_TARGET=13.0

echo "▸ 编译 Swift（release, macOS 13+）"
swift build -c release --triple "${ARCH}-apple-macosx13.0"

echo "▸ 组装 .app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$(swift build -c release --show-bin-path)/StorageWatch" "$APP/Contents/MacOS/"
cp Resources/Info.plist "$APP/Contents/"
cp Resources/AppIcon.icns "$APP/Contents/Resources/"
cp Resources/MenuBarIcon.png Resources/MenuBarIcon@2x.png "$APP/Contents/Resources/"

if [ "$EMBED_PYTHON" -eq 1 ]; then
  echo "▸ 准备内嵌 Python ${PY_VERSION} (${PY_ARCH})"
  if [ ! -x "$PY_CACHE/bin/python3" ]; then
    mkdir -p "$OUT/cache"
    TARBALL="$OUT/cache/python-$PY_VERSION.tar.gz"
    URL="https://github.com/astral-sh/python-build-standalone/releases/download/${PY_DATE}/cpython-${PY_VERSION}%2B${PY_DATE}-${PY_ARCH}-apple-darwin-install_only_stripped.tar.gz"
    if [ ! -f "$TARBALL" ]; then
      echo "  下载 $URL"
      curl -fL --retry 3 --progress-bar "$URL" -o "$TARBALL"
    fi
    rm -rf "$PY_CACHE" && mkdir -p "$PY_CACHE"
    tar -xzf "$TARBALL" -C "$PY_CACHE" --strip-components=1
  fi
  # Trim modules the scanner never uses to keep the download small.
  for dir in test idlelib tkinter turtledemo ensurepip lib2to3 pydoc_data; do
    rm -rf "$PY_CACHE/lib/python3.12/$dir"
  done
  rm -rf "$PY_CACHE"/lib/python3.12/site-packages/* "$PY_CACHE"/lib/python3.12/config-3.12-darwin
  find "$PY_CACHE" -name '__pycache__' -type d -prune -exec rm -rf {} + 2>/dev/null || true
  rm -f "$PY_CACHE"/bin/2to3* "$PY_CACHE"/bin/idle3* "$PY_CACHE"/bin/pip* "$PY_CACHE"/bin/pydoc* "$PY_CACHE"/bin/python3-config
  mkdir -p "$APP/Contents/Resources/python"
  ditto "$PY_CACHE" "$APP/Contents/Resources/python"
  cp ../engine/monitor.py "$APP/Contents/Resources/monitor.py"
  PY_FLAG="embedded"
else
  cp ../engine/monitor.py "$APP/Contents/Resources/monitor.py"
  PY_FLAG="system"
fi

PLIST="$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :SWPythonMode $PY_FLAG" "$PLIST" 2>/dev/null || \
  /usr/libexec/PlistBuddy -c "Add :SWPythonMode string $PY_FLAG" "$PLIST"

# Ad-hoc sign so Gatekeeper treats it as a consistent bundle.
# Sign in /tmp: iCloud/File Provider folders attach xattrs (com.apple.fileprovider.fpfs#P)
# that make codesign reject the bundle, so the final copy is signed outside the sync root.
SIGN_DIR="$(mktemp -d)"
trap 'rm -rf "$SIGN_DIR"' EXIT
SIGNED_APP="$SIGN_DIR/Storage Watch.app"
ditto "$APP" "$SIGNED_APP"
xattr -cr "$SIGNED_APP" 2>/dev/null || true
find "$SIGNED_APP" -name '._*' -delete 2>/dev/null || true
if [ "$EMBED_PYTHON" -eq 1 ]; then
  codesign --force --deep --sign - --identifier local.storagewatch.app "$SIGNED_APP" >/dev/null 2>&1 || true
else
  codesign --force --sign - --identifier local.storagewatch.app "$SIGNED_APP" >/dev/null 2>&1 || true
fi
codesign --verify --deep --strict "$SIGNED_APP" 2>/dev/null && echo "  签名校验通过"
rm -rf "$APP"
ditto "$SIGNED_APP" "$APP"

SIZE="$(du -sh "$APP" | cut -f1)"
echo "✓ 完成: ${APP} (${SIZE}, Python: ${PY_FLAG})"
