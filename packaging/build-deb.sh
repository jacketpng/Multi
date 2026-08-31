#!/usr/bin/env bash
# Build a .deb from an already-built Flutter release bundle.
#
#   ./packaging/build-deb.sh [--skip-build]
#
# Needs dpkg-deb. Debian puts arch-specific private files in
# /usr/lib/<pkg> rather than /usr/lib64, so the layout differs slightly
# from the RPM.
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PKG_DIR="$PROJECT_DIR/packaging"
SKIP_BUILD=0
[[ "${1:-}" == "--skip-build" ]] && SKIP_BUILD=1

NAME=multi
APPID=dev.multi.Multi
VERSION="$(grep -m1 '^version:' "$PROJECT_DIR/pubspec.yaml" | awk '{print $2}' | cut -d+ -f1)"

command -v dpkg-deb >/dev/null || { echo "missing: dpkg-deb (apt install dpkg-dev)"; exit 1; }

# Debian architecture names differ from uname's.
case "$(uname -m)" in
    x86_64)  DEB_ARCH=amd64 ;;
    aarch64) DEB_ARCH=arm64 ;;
    armv7l)  DEB_ARCH=armhf ;;
    *)       echo "unsupported architecture: $(uname -m)"; exit 1 ;;
esac

BUNDLE="$PROJECT_DIR/build/linux/${DEB_ARCH/amd64/x64}/release/bundle"
[[ -d "$BUNDLE" ]] || BUNDLE="$PROJECT_DIR/build/linux/arm64/release/bundle"

if [[ $SKIP_BUILD -eq 0 ]]; then
    FLUTTER="${FLUTTER_BIN:-$(command -v flutter || true)}"
    [[ -n "$FLUTTER" ]] || { echo "flutter not found; set FLUTTER_BIN or pass --skip-build"; exit 1; }
    (cd "$PROJECT_DIR" && "$FLUTTER" build linux --release)
fi
[[ -x "$BUNDLE/$NAME" ]] || { echo "no release bundle at $BUNDLE"; exit 1; }

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
ROOT="$STAGE/${NAME}_${VERSION}_${DEB_ARCH}"

install -d "$ROOT/usr/lib/$NAME" "$ROOT/usr/bin" \
           "$ROOT/usr/share/applications" \
           "$ROOT/usr/share/icons/hicolor/scalable/apps" \
           "$ROOT/DEBIAN"
cp -a "$BUNDLE/." "$ROOT/usr/lib/$NAME/"
chmod 0755 "$ROOT/usr/lib/$NAME/$NAME"

# Flutter bakes its build-tree path into plugin libraries as RUNPATH.
# It is not inherited from the executable and the plugins link the
# bundle-private libflutter_linux_gtk.so, so point them at their own
# directory instead of leaving a path that exists on no other machine.
if command -v patchelf >/dev/null; then
    for so in "$ROOT/usr/lib/$NAME"/lib/*.so; do
        [[ -e "$so" ]] || continue
        if patchelf --print-rpath "$so" 2>/dev/null | grep -q '^/'; then
            patchelf --set-rpath '$ORIGIN' "$so"
        fi
    done
fi

ln -sr "$ROOT/usr/lib/$NAME/$NAME" "$ROOT/usr/bin/$NAME"
install -m 0644 "$PKG_DIR/$APPID.desktop" "$ROOT/usr/share/applications/"
install -m 0644 "$PKG_DIR/$NAME.svg" \
    "$ROOT/usr/share/icons/hicolor/scalable/apps/$APPID.svg"

INSTALLED_KB="$(du -ks "$ROOT/usr" | cut -f1)"
cat > "$ROOT/DEBIAN/control" <<EOF
Package: $NAME
Version: $VERSION
Section: video
Priority: optional
Architecture: $DEB_ARCH
Maintainer: Matt Vasquez <mattjack.vasquez@gmail.com>
Installed-Size: $INSTALLED_KB
Depends: libgtk-3-0 | libgtk-3-0t64, libglib2.0-0 | libglib2.0-0t64, libstdc++6, libc6, tar
Recommends: xdg-utils
Homepage: https://github.com/jacketpng/Multi
Description: Media multi-tool GUI for yt-dlp, gallery-dl, aria2 and FFmpeg
 Multi is a single graphical front end for the best media command-line
 tools. Paste a link and it picks the right engine automatically: yt-dlp
 for video sites, gallery-dl for image galleries, aria2 for direct
 downloads.
 .
 Conversion is remux-first: streams the target container supports are
 copied bit-for-bit, and only what cannot be copied is re-encoded.
 .
 yt-dlp, gallery-dl, aria2, FFmpeg and ImageMagick are downloaded and
 kept up to date automatically in the user's own data directory, so they
 are not packaging dependencies.
EOF

dpkg-deb --build --root-owner-group "$ROOT" >/dev/null
OUT="$PROJECT_DIR/${NAME}_${VERSION}_${DEB_ARCH}.deb"
mv "$ROOT.deb" "$OUT"
echo "$OUT"
