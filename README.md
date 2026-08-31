# Multi

One GUI for the best media command-line tools. Multi bundles **yt-dlp**,
**gallery-dl**, **aria2**, **FFmpeg**, and **ImageMagick** into a single
Flutter desktop app for Linux, Windows, and macOS.

## How the bundling works

Multi doesn't ship the tools inside the binary — it manages them for you:

- On first launch each tool is downloaded automatically from its official
  release channel into the app's data directory
  (`~/.local/share/dev.multi.multi/tools` on Linux). No PATH edits, no
  package manager, no effort.
- On **every** launch Multi checks each tool's latest release and updates
  anything stale, in the background. The **Tools** page shows live status,
  versions, and progress.
- If a download isn't possible (offline, or no build exists for the
  platform), Multi falls back to a system-installed copy found on PATH.

| Tool | Source | Linux | Windows | macOS |
|---|---|---|---|---|
| yt-dlp | yt-dlp/yt-dlp releases | ✅ | ✅ | ✅ |
| gallery-dl | gdl-org/builds releases | ✅ | ✅ | ✅ |
| aria2 | abcfy2/aria2-static-build | ✅ | ✅ | PATH fallback (`brew install aria2`) |
| FFmpeg (+ffprobe) | BtbN/FFmpeg-Builds · evermeet.cx | ✅ | ✅ | ✅ |
| ImageMagick | ImageMagick releases | ✅ (AppImage, auto-extracted) | ✅ (portable) | PATH fallback (`brew install imagemagick`) |

## Downloading

Paste a link into the bar — Multi works out how to handle it, strongest
evidence first:

1. **Magnet links** → aria2 (nothing else does torrents)
2. **Known gallery/social sites** (Instagram, Pinterest, Pixiv, X, …) →
   gallery-dl, and **known video sites** (YouTube, Twitch, TikTok, …) →
   yt-dlp — instant, no network
3. Otherwise **the tools themselves are asked** whether they support the
   URL. Crucially this distinguishes "no extractor matches" from "an
   extractor matched but the fetch failed" — a login wall or a deleted
   post still means that tool is the right one. When nothing matches,
   both tools fail instantly without any network request.
4. **Only then**, if nothing claims the URL and it is a direct link to a
   file, → aria2
5. If nothing claims it and it isn't a file, Multi **asks you** instead
   of guessing: scan the page for files, force one of the tools, or
   fetch the URL directly.

aria2 is never chosen just because a URL ends in `.jpg`, and page
scanning never happens on its own. The scan's checklist contains only
links to real files, since aria2 can do nothing useful with a page.
The engine chip on each task is also a menu — any automatic choice can
be overridden in one click.

**Nothing downloads until you press Start.** Every pasted link is
previewed first: video links show the thumbnail, uploader, duration, and
the full format list (container, codecs, resolution, bitrate, estimated
size) so you can pick exactly the version you want; galleries show a
sample of their contents; direct files show the server-reported name,
size, and type.

Each download has:

- **Presets** — *Speed* (parallel connections, no delays), *Balanced*, and
  *Low profile* (single connection, randomized sleeps, rate caps — for
  sites that bot-detect). The recommended preset is picked automatically
  per site: Instagram, X, and Pixiv default to Low profile.
- **Progress** is per-item where the tool reports it: a bar per video for
  yt-dlp playlists and a bar per file for parallel aria2 batches.
  gallery-dl gets a single overall bar instead — it reports whole files
  with no byte-level progress, so a row per picture would be noise. Its
  denominator comes from gallery-dl's own `{count}` metadata (real for
  albums, posts, and chapters) or from an explicit `--range`; for endless
  feeds like a profile or tag search, where no total exists without a
  full extra enumeration pass, the bar stays indeterminate and shows an
  honest running count rather than a made-up percentage.
- **Parallel downloads on the Speed preset.** Neither yt-dlp nor
  gallery-dl downloads multiple items concurrently on its own (yt-dlp's
  `-N` only parallelizes fragments *within* one video), so Multi shards
  the work across several instances using each tool's interleaved slice
  syntax — yt-dlp `-I k::n`, gallery-dl `--range k::n`. Worker *k* of *n*
  takes every *n*-th item, so the shards are disjoint by construction and
  no item is fetched twice. Playlists of 8+ get 4 workers, 4–7 get 2, and
  galleries get 3. Sharding is skipped automatically when it would be
  unsafe or pointless: on other presets, on small playlists, when you set
  your own item range, and when a download archive is in use (concurrent
  writes to one archive file aren't safe). aria2 is left alone — it
  already parallelizes internally.
- **Cookies** — read straight from Firefox/Chrome/Edge/Brave/… or from a
  Netscape cookie file. Sites that need login (Instagram, X, Patreon, …)
  show a hint.
- **LibreWolf** is supported even though neither yt-dlp nor gallery-dl
  knows it by name: Multi passes the profile as `firefox:<profile path>`,
  which both accept. Selecting LibreWolf shows a box to paste the profile
  folder (from `about:profiles` → the Root Directory of the profile in
  use), which accepts either the profile folder or the installation root
  containing `profiles.ini`. Auto-detection of the usual system, Flatpak,
  and Snap locations is offered as a one-click suggestion, but the pasted
  path always wins. The path is remembered between runs.
- **Login-walled sites are never touched before you choose cookies.**
  Instagram, X, Pixiv, Patreon, and friends show nothing to a logged-out
  visitor, so pasting such a link parks the task with a cookie chooser
  instead of previewing it — no request is made to the site until you
  pick cookies (or explicitly continue without them). Tick "remember this
  choice" and later links skip the prompt.
- **Options** — a large catalog of each tool's flags as GUI controls
  (subtitles, SponsorBlock, selection filters, network tuning,
  BitTorrent…), an extra-arguments field for everything else, and a live
  preview of the exact command line that will run.
- **Convert after download** — pick a target container and finished media
  files go straight to the Convert queue (remux-first, as always).

## Converting

The Convert page is remux-first: *"I have this container, I want that
container."*

- Streams the target container supports are **copied bit-for-bit** —
  no quality loss, takes seconds.
- Only streams the target can't hold are **transcoded**, to sensible
  defaults (H.264/AAC for MP4, VP9/Opus for WebM, …).
- Before anything runs you see a per-stream plan: green **COPY**, amber
  **TRANSCODE (HEVC → H264)**, grey **DROP**, each with the reason and an
  **estimated output size**.
- Every video/audio stream has a dropdown of the codecs its target
  container supports, each with a plain-language description (H.264 is
  the compatible/fast one, HEVC and AV1 are smaller but slower and less
  compatible, …). You can force a re-encode even when copy is possible.
- **Every codec** the container accepts *and* your FFmpeg build can
  encode is listed, sorted by popularity and compatibility. For a
  permissive container like MKV that really is everything the build
  offers: curated codecs (with descriptions and tuned defaults) first,
  then the long tail.
- **Sizes** are shown per stream and overall: the original, the
  estimate, and the percentage change between them.
- **Constant quality is the default** rate control. The slider follows
  whichever scale is actually in force — FFmpeg's CRF for software, or
  the hardware family's own CQ/QP scale when hardware encoding is on.
  Constant quality is greyed out for encoders that lack a dependable
  one (VideoToolbox), which fall back to bitrate.
- **Hardware acceleration is on by default** whenever this machine has a
  working encoder for the chosen codec — proven with a real test encode,
  not just assumed — and can be switched off per conversion or globally
  in Settings.
- **Match the original size**: Multi starts from the quality whose
  estimated output is closest to the source file, and a button re-runs
  that search at any time.
- **Cap the file size** in MB (8 / 10 / 25 / 50 …) to fit upload limits;
  Multi derives the bitrate from the duration, leaving room for audio.
- **Filters**: resolution, frame rate, rotate/flip, crop, deinterlace,
  denoise, grayscale, plus a raw filter-chain field. Resizing and frame
  rate changes feed back into the size estimate.

### Settings

A Settings page stores the defaults: hardware acceleration, rate
control, whether to match the original size, default bitrates and
container, download folder, how many downloads and how many items run at
once, preset and cookie defaults, convert-after-download, and whether to
check for tool updates at launch.

The Images page applies the same philosophy with ImageMagick: the plan
under each file states exactly what happens (lossless → lossy, resize,
metadata stripping) before you convert.

## Building

```bash
flutter pub get
flutter build linux    # or: windows / macos
```

Linux needs the usual Flutter desktop deps: `clang cmake ninja-build
gtk3-devel pkgconf`.

### Packages

Each format has a script that works from an already-built bundle, so
they can be run individually:

```bash
./packaging/build-rpm.sh       # .rpm   (Fedora, RHEL, openSUSE)
./packaging/build-deb.sh       # .deb   (Debian, Ubuntu, Mint)
./packaging/build-appimage.sh  # .AppImage (any distro)
```

Pass `--skip-build` to package an existing
`build/linux/*/release/bundle` instead of rebuilding. All three detect
x86_64 vs aarch64 from the host and apply the same `$ORIGIN` RUNPATH fix.

Requirements: `rpmbuild` and `desktop-file-validate` for the RPM
(`dnf install rpm-build desktop-file-utils`, or `apt install rpm
desktop-file-utils`), `dpkg-deb` for the .deb, and `patchelf`.
`build-appimage.sh` downloads `appimagetool` itself if it isn't on PATH.

The packages install the bundle to a private directory (`%{_libdir}/multi`
for RPM, `/usr/lib/multi` for deb) with a symlink at `/usr/bin/multi`,
plus a desktop entry and icon. Runtime dependencies are detected from the
ELF binaries; the five media tools are deliberately *not* dependencies,
since Multi downloads and updates them itself.

Two details worth knowing. Flutter bakes its build-tree path into plugin
libraries as `RUNPATH`; since `RUNPATH` is not inherited from the
executable and those plugins link the bundle-private
`libflutter_linux_gtk.so`, every packaging script rewrites it to
`$ORIGIN` rather than simply deleting it. And an RPM `Version` cannot
contain `-`, so a pre-release like `0.3.0-beta1` becomes `0.3.0~beta1`,
which is also the form that sorts correctly *before* the final release.

### Releases from CI

`.github/workflows/release.yml` builds every platform and publishes a
GitHub Release whenever a version tag is pushed:

```bash
git tag v0.2.0
git push origin v0.2.0
```

It runs `flutter analyze` and `flutter test` first and stops if either
fails, then builds:

| Job | Runner | Produces |
|---|---|---|
| `linux` (x86_64) | `ubuntu-22.04` | `.deb`, `.rpm`, `.AppImage`, `.tar.gz` |
| `linux` (aarch64) | `ubuntu-22.04-arm` | `.deb`, `.rpm`, `.AppImage`, `.tar.gz` |
| `windows` (x64) | `windows-latest` | Inno Setup `-setup.exe` + portable `.zip` |
| `windows` (arm64) | `windows-11-arm` | Inno Setup `-setup.exe` + portable `.zip` |
| `macos` | `macos-14` | universal (arm64 + x86_64) `.dmg` |

Linux builds run on Ubuntu 22.04 deliberately: glibc is forward
compatible, so binaries built against an older glibc run on newer
distributions but not the reverse.

The version comes from the tag, so `v1.2.3` builds `1.2.3` — no need to
edit `pubspec.yaml` first. "Run workflow" in the Actions tab does a test
build that uploads artifacts without publishing a release.

Two things to know before the first run:

- **Arm runners.** `ubuntu-22.04-arm` and `windows-11-arm` are free for
  public repositories; private repositories need a paid plan. Delete
  those matrix entries if that applies. `fail-fast: false` means one
  architecture failing does not cancel the others.
- **Signing.** The Windows and macOS builds are unsigned; signing needs
  certificates in repository secrets and is not set up here. macOS
  quarantines unsigned apps, so first launch needs right-click → Open.

## Development notes

- `lib/services/tool_manager.dart` — download/update/locate the tools
- `lib/services/url_router.dart` — engine decision for pasted URLs
- `lib/services/convert_planner.dart` — container/codec matrix and ffmpeg
  command builder
- `flutter test` runs unit tests for the router, planner, and presets.
