# Multi ships prebuilt Flutter binaries (the Flutter SDK is not packaged
# in Fedora), so the tarball built by packaging/build-rpm.sh is installed
# as-is and there is no debuginfo subpackage.
%global debug_package %{nil}
%global appid dev.multi.Multi
# build-rpm.sh passes the version from pubspec.yaml, so the two cannot
# drift apart; the literal is only a fallback for a manual rpmbuild.
%global appversion %{?_version}%{!?_version:0.3.0}

Name:           multi
Version:        %{appversion}
Release:        1%{?dist}
Summary:        Media multi-tool GUI for yt-dlp, gallery-dl, aria2, FFmpeg, and ImageMagick

License:        GPL-3.0-or-later
URL:            https://github.com/jacketpng/Multi
Source0:        %{name}-%{version}-linux-%{_arch}.tar.gz
Source1:        %{appid}.desktop
Source2:        %{name}.svg
Source3:        LICENSE

ExclusiveArch:  x86_64 aarch64

BuildRequires:  desktop-file-utils
BuildRequires:  patchelf

Requires:       gtk3
Requires:       tar
Requires:       hicolor-icon-theme
# Used to open the file manager from "Open folder" buttons.
Recommends:     xdg-utils
# Multi downloads and updates yt-dlp, gallery-dl, aria2, FFmpeg, and
# ImageMagick into the user's data directory on first launch, so none of
# them are packaging dependencies. System copies on PATH are used as a
# fallback when a download is not possible.

%description
Multi is a single graphical front end for the best media command-line
tools. Paste a link and it picks the right engine automatically: yt-dlp
for video sites, gallery-dl for image galleries, and aria2 for direct
downloads. Links that no extractor supports are scraped into a checklist
of files to fetch.

Conversion is remux-first: streams the target container supports are
copied bit-for-bit, and only what cannot be copied is re-encoded. Every
conversion shows a per-stream plan with codec choices, size estimates,
constant-quality or constant-bitrate control, and optional hardware
acceleration.

The bundled tools are downloaded and kept up to date automatically in
the user's own data directory; nothing needs to be installed by hand.

%prep
%setup -q -n %{name}-%{version}

%build
# Nothing to compile: Source0 contains the release bundle produced by
# "flutter build linux --release".

%install
install -d %{buildroot}%{_libdir}/%{name}
cp -a . %{buildroot}%{_libdir}/%{name}/
chmod 0755 %{buildroot}%{_libdir}/%{name}/%{name}

# Flutter bakes its build-tree path into plugin libraries as RUNPATH
# (e.g. .../linux/flutter/ephemeral), which does not exist on an
# installed system. RUNPATH is not inherited from the executable, and
# these plugins link the bundle-private libflutter_linux_gtk.so, so
# point them at their own directory instead of just dropping it.
for so in %{buildroot}%{_libdir}/%{name}/lib/*.so; do
    if patchelf --print-rpath "$so" | grep -q '^/'; then
        patchelf --set-rpath '$ORIGIN' "$so"
    fi
done

# /usr/bin/multi resolves through /proc/self/exe, so the bundle still
# finds its adjacent data/ and lib/ directories through this symlink.
install -d %{buildroot}%{_bindir}
ln -sr %{buildroot}%{_libdir}/%{name}/%{name} %{buildroot}%{_bindir}/%{name}

install -Dpm 0644 %{SOURCE1} %{buildroot}%{_datadir}/applications/%{appid}.desktop
install -Dpm 0644 %{SOURCE2} \
    %{buildroot}%{_datadir}/icons/hicolor/scalable/apps/%{appid}.svg
cp -p %{SOURCE3} .

%check
desktop-file-validate %{buildroot}%{_datadir}/applications/%{appid}.desktop

%files
%license LICENSE
%{_bindir}/%{name}
%{_libdir}/%{name}/
%{_datadir}/applications/%{appid}.desktop
%{_datadir}/icons/hicolor/scalable/apps/%{appid}.svg

%changelog
* Tue Sep 01 2026 Matt Vasquez <mattjack.vasquez@gmail.com> - 0.3.0-1
- Subtitles: burn-in, sidecar extraction, format conversion
- Audio: sample rate, channels, VBR, EBU R128 and peak normalisation
- Black bar removal measured with cropdetect across the whole file
- Two-pass encoding, per-stream metadata, stream reordering
- GIF now builds a palette from the clip instead of the fixed web one
- Audio and subtitle tracks can be filtered by language
- Download all, and a paste of several links becomes one task each
- New icon
* Sun Aug 30 2026 Matt Vasquez <mattjack.vasquez@gmail.com> - 0.2.0-1
- Settings page for saved defaults
- Hardware encoding on by default when the machine supports it
- Full per-container codec lists filtered against the local FFmpeg build
- Size comparison, size caps, and video filters when transcoding
- Routing asks the tools what they support instead of guessing
- LibreWolf cookie profiles, with manual profile entry

* Sun Aug 30 2026 Matt Vasquez <mattjack.vasquez@gmail.com> - 0.1.0-1
- Initial package
