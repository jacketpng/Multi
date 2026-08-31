#!/usr/bin/env bash
# Build Multi as an RPM.
#
#   ./packaging/build-rpm.sh
#
# Runs "flutter build linux --release", tars the bundle, and hands it to
# rpmbuild. Needs flutter on PATH (or FLUTTER_BIN set) plus rpmbuild and
# desktop-file-validate:
#   Fedora: dnf install rpm-build desktop-file-utils
#   Debian: apt install rpm desktop-file-utils
#
# On a host without the Flutter Linux toolchain (clang/cmake/gtk3-devel),
# build inside a toolbox and pass --skip-build here, or run this whole
# script inside that toolbox.
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PKG_DIR="$PROJECT_DIR/packaging"
SKIP_BUILD=0
[[ "${1:-}" == "--skip-build" ]] && SKIP_BUILD=1

NAME=multi
VERSION_RAW="$(grep -m1 '^version:' "$PROJECT_DIR/pubspec.yaml" | awk '{print $2}' | cut -d+ -f1)"
# An RPM Version field cannot contain '-', so a pre-release such as
# 0.3.0-beta1 becomes 0.3.0~beta1 — the '~' also sorts *before* the
# final release, which is what a pre-release should do. The tarball is
# named with the same string so the spec's %setup still matches.
VERSION="${VERSION_RAW//-/\~}"
[[ "$VERSION" == "$VERSION_RAW" ]] || echo "==> version $VERSION_RAW -> $VERSION (RPM-safe)"
case "$(uname -m)" in
    x86_64)  BUNDLE_ARCH=x64 ;;
    aarch64) BUNDLE_ARCH=arm64 ;;
    *)       echo "unsupported architecture: $(uname -m)"; exit 1 ;;
esac
BUNDLE="$PROJECT_DIR/build/linux/$BUNDLE_ARCH/release/bundle"

for tool in rpmbuild desktop-file-validate; do
    command -v "$tool" >/dev/null || {
        echo "missing: $tool"
        echo "  Fedora: dnf install rpm-build desktop-file-utils"
        echo "  Debian: apt install rpm desktop-file-utils"
        exit 1
    }
done

if [[ $SKIP_BUILD -eq 0 ]]; then
    FLUTTER="${FLUTTER_BIN:-$(command -v flutter || true)}"
    [[ -n "$FLUTTER" ]] || { echo "flutter not found; set FLUTTER_BIN or pass --skip-build"; exit 1; }
    echo "==> flutter build linux --release"
    (cd "$PROJECT_DIR" && "$FLUTTER" build linux --release)
fi
[[ -x "$BUNDLE/$NAME" ]] || { echo "no release bundle at $BUNDLE"; exit 1; }

echo "==> staging $NAME-$VERSION"
TOP="$(rpmbuild --eval %{_topdir})"
# Built by hand rather than with rpmdev-setuptree, which lives in
# rpmdevtools and is not packaged on Debian-family systems.
mkdir -p "$TOP"/{BUILD,BUILDROOT,RPMS,SOURCES,SPECS,SRPMS}
ARCH="$(uname -m)"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
cp -a "$BUNDLE" "$STAGE/$NAME-$VERSION"
tar -czf "$TOP/SOURCES/$NAME-$VERSION-linux-$ARCH.tar.gz" -C "$STAGE" "$NAME-$VERSION"
install -m 0644 "$PKG_DIR/dev.multi.Multi.desktop" "$PKG_DIR/$NAME.svg" \
    "$PROJECT_DIR/LICENSE" "$TOP/SOURCES/"

echo "==> rpmbuild"
# rpm on Debian-family systems defaults _libdir to /usr/lib, which would
# put an RPM's files in the wrong place for the distributions it targets.
# Pin it so the package is identical wherever it is built.
# --nodeps: BuildRequires are resolved against rpm's own database, which
# on a Debian-family build host knows nothing about the apt packages that
# actually provide these tools. The checks above already confirmed they
# are present, and the spec keeps its BuildRequires for real RPM hosts.
rpmbuild -bb "$PKG_DIR/$NAME.spec" \
    --nodeps \
    --define "_version $VERSION" \
    --define "_libdir /usr/lib64" \
    --target "$ARCH"

find "$TOP/RPMS" -name "$NAME-$VERSION-*.rpm" -newermt '-5 minutes' -print
