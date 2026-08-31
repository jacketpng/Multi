#!/usr/bin/env bash
# Build a relocatable macOS binary bundle for one of the media tools.
#
#   ./build-macos-tool.sh ffmpeg|aria2|imagemagick <output-dir>
#
# Nobody publishes portable macOS builds of aria2 or ImageMagick, and
# the only FFmpeg ones are Intel-only, so Multi builds its own.
#
# Homebrew installs binaries that hard-code /opt/homebrew paths for
# their libraries, which is useless on a machine that has no Homebrew.
# dylibbundler copies each dependency next to the binary and rewrites
# the install names to @executable_path/../lib, giving a tree that runs
# anywhere:
#
#   bin/ffmpeg          <- rewritten to look in ../lib
#   lib/libx264.dylib   <- and its own dependencies, recursively
set -euo pipefail

TOOL="${1:?usage: build-macos-tool.sh <ffmpeg|aria2|imagemagick> <outdir>}"
OUT="${2:?missing output directory}"
ARCH="$(uname -m)"   # arm64 or x86_64

case "$TOOL" in
    ffmpeg)      FORMULA=ffmpeg;      BINS=(ffmpeg ffprobe) ;;
    aria2)       FORMULA=aria2;       BINS=(aria2c) ;;
    imagemagick) FORMULA=imagemagick; BINS=(magick) ;;
    *) echo "unknown tool: $TOOL"; exit 1 ;;
esac

echo "==> installing $FORMULA and dylibbundler"
brew update >/dev/null
brew install "$FORMULA" dylibbundler >/dev/null

PREFIX="$(brew --prefix "$FORMULA")"
VERSION="$(brew list --versions "$FORMULA" | awk '{print $2}')"
echo "==> $FORMULA $VERSION at $PREFIX"

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
mkdir -p "$STAGE/bin" "$STAGE/lib"

for b in "${BINS[@]}"; do
    cp "$PREFIX/bin/$b" "$STAGE/bin/$b"
    chmod +w "$STAGE/bin/$b"
done

echo "==> bundling libraries"
# -od: overwrite existing, -b: bundle, -cd: create dest dir,
# -p: the install-name prefix baked into the binaries.
dylibbundler -od -b -cd \
    $(printf -- '-x %s ' "${BINS[@]/#/$STAGE/bin/}") \
    -d "$STAGE/lib" -p '@executable_path/../lib' >/dev/null

# ImageMagick looks for its configuration relative to MAGICK_HOME. A
# tiny launcher keeps that self-contained rather than depending on
# whatever is installed on the user's machine.
if [[ "$TOOL" == imagemagick ]]; then
    mv "$STAGE/bin/magick" "$STAGE/bin/magick.bin"
    cat > "$STAGE/bin/magick" <<'LAUNCHER'
#!/bin/sh
HERE="$(cd "$(dirname "$0")" && pwd)"
export MAGICK_HOME="$HERE/.."
export MAGICK_CONFIGURE_PATH="$HERE/../etc:$HERE/../share"
exec "$HERE/magick.bin" "$@"
LAUNCHER
    chmod +x "$STAGE/bin/magick"
    for d in etc/ImageMagick-7 share/ImageMagick-7; do
        [[ -d "$PREFIX/$d" ]] && { mkdir -p "$STAGE/$(dirname "$d")"; cp -R "$PREFIX/$d" "$STAGE/$(dirname "$d")/"; }
    done || true
fi

# Record exactly what went in. GPL-3 §6(d) lets object code be conveyed
# from a network server as long as clear directions to the corresponding
# source sit next to it — this manifest is those directions.
{
    echo "tool:     $TOOL"
    echo "formula:  $FORMULA $VERSION"
    echo "arch:     $ARCH"
    echo "built:    $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "macos:    $(sw_vers -productVersion)"
    echo
    echo "Built from the Homebrew formula above. Corresponding source for"
    echo "this binary and every bundled library:"
    echo "  brew edit --print-path $FORMULA   (formula, pinned version above)"
    echo "  https://github.com/Homebrew/homebrew-core"
    echo "  and each project's own release for the exact version listed by"
    echo "  'brew list --versions' at build time, recorded in DEPS below."
    echo
    echo "DEPS (every dependency baked into this bundle):"
    brew deps --installed --formula "$FORMULA" | while read -r d; do
        echo "  $d $(brew list --versions "$d" 2>/dev/null | awk '{print $2}')"
    done
    echo
    echo "BUNDLED LIBRARIES:"
    ls -1 "$STAGE/lib" 2>/dev/null | sed 's/^/  /'
} > "$STAGE/SOURCES.txt"

echo "==> verifying the bundle is relocatable"
fail=0
for b in "${BINS[@]}"; do
    target="$STAGE/bin/$b"
    [[ "$TOOL" == imagemagick && "$b" == magick ]] && target="$STAGE/bin/magick.bin"
    # Anything still pointing into /opt/homebrew or /usr/local would
    # break on a machine without Homebrew.
    if otool -L "$target" | tail -n +2 | grep -E '/opt/homebrew|/usr/local/(opt|Cellar)'; then
        echo "  !! $b still references Homebrew paths"
        fail=1
    else
        echo "  ok $b"
    fi
done
[[ $fail -eq 0 ]] || { echo "bundle is not relocatable"; exit 1; }

mkdir -p "$OUT"
TARBALL="$OUT/$TOOL-macos-$ARCH.tar.gz"
tar -C "$STAGE" -czf "$TARBALL" .
echo "$TARBALL"
