#!/usr/bin/env bash
# Build an AppImage from an already-built Flutter release bundle.
#
#   ./packaging/build-appimage.sh [--skip-build]
#
# Downloads appimagetool for the host architecture if it isn't on PATH.
# Runs it with --appimage-extract-and-run so no FUSE is needed, which
# matters in containers and CI.
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PKG_DIR="$PROJECT_DIR/packaging"
SKIP_BUILD=0
[[ "${1:-}" == "--skip-build" ]] && SKIP_BUILD=1

NAME=multi
APPID=dev.multi.Multi
VERSION="$(grep -m1 '^version:' "$PROJECT_DIR/pubspec.yaml" | awk '{print $2}' | cut -d+ -f1)"
ARCH="$(uname -m)"

case "$ARCH" in
    x86_64)  BUNDLE_DIR=x64 ;;
    aarch64) BUNDLE_DIR=arm64 ;;
    *)       echo "unsupported architecture: $ARCH"; exit 1 ;;
esac
BUNDLE="$PROJECT_DIR/build/linux/$BUNDLE_DIR/release/bundle"

if [[ $SKIP_BUILD -eq 0 ]]; then
    FLUTTER="${FLUTTER_BIN:-$(command -v flutter || true)}"
    [[ -n "$FLUTTER" ]] || { echo "flutter not found; set FLUTTER_BIN or pass --skip-build"; exit 1; }
    (cd "$PROJECT_DIR" && "$FLUTTER" build linux --release)
fi
[[ -x "$BUNDLE/$NAME" ]] || { echo "no release bundle at $BUNDLE"; exit 1; }

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
APPDIR="$STAGE/$NAME.AppDir"

install -d "$APPDIR/usr/bin" "$APPDIR/usr/share/applications" \
           "$APPDIR/usr/share/icons/hicolor/scalable/apps"
cp -a "$BUNDLE/." "$APPDIR/usr/bin/"
chmod 0755 "$APPDIR/usr/bin/$NAME"

if command -v patchelf >/dev/null; then
    for so in "$APPDIR/usr/bin"/lib/*.so; do
        [[ -e "$so" ]] || continue
        if patchelf --print-rpath "$so" 2>/dev/null | grep -q '^/'; then
            patchelf --set-rpath '$ORIGIN' "$so"
        fi
    done
fi

# The desktop file and icon must sit at the AppDir root as well; the
# icon's basename has to match the desktop file's Icon= key.
install -m 0644 "$PKG_DIR/$APPID.desktop" \
    "$APPDIR/usr/share/applications/$APPID.desktop"
install -m 0644 "$PKG_DIR/$APPID.desktop" "$APPDIR/$APPID.desktop"
install -m 0644 "$PKG_DIR/$NAME.svg" \
    "$APPDIR/usr/share/icons/hicolor/scalable/apps/$APPID.svg"
install -m 0644 "$PKG_DIR/$NAME.svg" "$APPDIR/$APPID.svg"

cat > "$APPDIR/AppRun" <<'EOF'
#!/bin/sh
HERE="$(dirname "$(readlink -f "$0")")"
exec "$HERE/usr/bin/multi" "$@"
EOF
chmod 0755 "$APPDIR/AppRun"

TOOL="$(command -v appimagetool || true)"
if [[ -z "$TOOL" ]]; then
    TOOL="$STAGE/appimagetool"
    url="https://github.com/AppImage/appimagetool/releases/download/continuous/appimagetool-$ARCH.AppImage"
    echo "==> fetching appimagetool for $ARCH"
    curl -sSfL -o "$TOOL" "$url"
    chmod +x "$TOOL"
fi

OUT="$PROJECT_DIR/Multi-$VERSION-$ARCH.AppImage"
rm -f "$OUT"
ARCH="$ARCH" "$TOOL" --appimage-extract-and-run "$APPDIR" "$OUT" >/dev/null
chmod +x "$OUT"
echo "$OUT"
