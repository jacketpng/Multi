import 'dart:io';

enum ToolId { ytDlp, galleryDl, aria2, ffmpeg, magick }

extension ToolIdInfo on ToolId {
  String get displayName => switch (this) {
        ToolId.ytDlp => 'yt-dlp',
        ToolId.galleryDl => 'gallery-dl',
        ToolId.aria2 => 'aria2',
        ToolId.ffmpeg => 'FFmpeg',
        ToolId.magick => 'ImageMagick',
      };

  String get blurb => switch (this) {
        ToolId.ytDlp => 'Video & audio from thousands of sites',
        ToolId.galleryDl => 'Image galleries and social media',
        ToolId.aria2 => 'Direct downloads, torrents, metalinks',
        ToolId.ffmpeg => 'Video & audio converting / remuxing',
        ToolId.magick => 'Image converting and processing',
      };

  /// Key used in the manifest json.
  String get key => name;
}

enum ToolStatusKind {
  unknown,
  checking,
  downloading,
  installing,
  ready,
  updateAvailable,
  usingSystem, // falling back to a PATH-installed copy
  missing,
  error,
}

class ToolStatus {
  final ToolStatusKind kind;
  final String? installedVersion;
  final String? installedTag;
  final String? latestTag;
  final double? progress; // 0..1 while downloading
  final String? message;

  const ToolStatus({
    this.kind = ToolStatusKind.unknown,
    this.installedVersion,
    this.installedTag,
    this.latestTag,
    this.progress,
    this.message,
  });

  ToolStatus copyWith({
    ToolStatusKind? kind,
    String? installedVersion,
    String? installedTag,
    String? latestTag,
    double? progress,
    String? message,
  }) =>
      ToolStatus(
        kind: kind ?? this.kind,
        installedVersion: installedVersion ?? this.installedVersion,
        installedTag: installedTag ?? this.installedTag,
        latestTag: latestTag ?? this.latestTag,
        progress: progress,
        message: message ?? this.message,
      );
}

enum ArchiveKind { none, zip, tarXz, sevenZip, appImage }

/// Where to get a tool for the current platform and how to unpack it.
class InstallSource {
  /// GitHub repo ('owner/name') to query for releases, or null for
  /// non-GitHub sources (then [latestUrl] must be set).
  final String? githubRepo;

  /// Release tag to use, 'latest' meaning the latest release endpoint.
  final String releaseTag;

  /// Asset filename. May contain the placeholder {tag} which is replaced
  /// with the release tag (with a leading 'v' or 'release-' stripped).
  final String? assetName;

  /// Direct download URL for non-GitHub sources.
  final String? latestUrl;

  final ArchiveKind archive;

  /// Path of the executable inside the extracted archive. May contain
  /// {tag}. Ignored for single-binary downloads.
  final String? innerPath;

  /// Extra executables to pull out of the same archive (e.g. ffprobe).
  final Map<String, String> extraInner;

  const InstallSource({
    this.githubRepo,
    this.releaseTag = 'latest',
    this.assetName,
    this.latestUrl,
    this.archive = ArchiveKind.none,
    this.innerPath,
    this.extraInner = const {},
  });
}

class ToolSpec {
  final ToolId id;

  /// Executable base name (used for PATH fallback and installed name).
  final String exeName;
  final List<String> versionArgs;
  final RegExp versionPattern;

  /// Per-platform sources; key: 'linux' | 'windows' | 'macos'.
  final Map<String, InstallSource> sources;

  /// Shown when no bundled build exists for this platform.
  final String? unavailableHint;

  const ToolSpec({
    required this.id,
    required this.exeName,
    required this.versionArgs,
    required this.versionPattern,
    required this.sources,
    this.unavailableHint,
  });

  InstallSource? get sourceForThisPlatform {
    final os = Platform.isWindows
        ? 'windows'
        : Platform.isMacOS
            ? 'macos'
            : 'linux';
    return sources[os];
  }
}

/// The tool catalog. Asset names verified against each project's releases.
final List<ToolSpec> toolSpecs = [
  ToolSpec(
    id: ToolId.ytDlp,
    exeName: 'yt-dlp',
    versionArgs: const ['--version'],
    versionPattern: RegExp(r'(\d{4}\.\d{2}\.\d{2}\S*)'),
    sources: const {
      'linux': InstallSource(
          githubRepo: 'yt-dlp/yt-dlp', assetName: 'yt-dlp_linux'),
      'windows':
          InstallSource(githubRepo: 'yt-dlp/yt-dlp', assetName: 'yt-dlp.exe'),
      'macos': InstallSource(
          githubRepo: 'yt-dlp/yt-dlp', assetName: 'yt-dlp_macos'),
    },
  ),
  ToolSpec(
    id: ToolId.galleryDl,
    exeName: 'gallery-dl',
    versionArgs: const ['--version'],
    versionPattern: RegExp(r'(\d+\.\d+\.\d+\S*)'),
    // Official standalone builds are published in gdl-org/builds.
    sources: const {
      'linux': InstallSource(
          githubRepo: 'gdl-org/builds', assetName: 'gallery-dl_linux'),
      'windows': InstallSource(
          githubRepo: 'gdl-org/builds', assetName: 'gallery-dl_windows.exe'),
      'macos': InstallSource(
          githubRepo: 'gdl-org/builds', assetName: 'gallery-dl_macos'),
    },
  ),
  ToolSpec(
    id: ToolId.aria2,
    exeName: 'aria2c',
    versionArgs: const ['--version'],
    versionPattern: RegExp(r'aria2 version (\S+)'),
    sources: const {
      'linux': InstallSource(
        githubRepo: 'abcfy2/aria2-static-build',
        assetName: 'aria2-x86_64-linux-musl_static.zip',
        archive: ArchiveKind.zip,
        innerPath: 'aria2c',
      ),
      'windows': InstallSource(
        githubRepo: 'abcfy2/aria2-static-build',
        assetName: 'aria2-x86_64-w64-mingw32_static.zip',
        archive: ArchiveKind.zip,
        innerPath: 'aria2c.exe',
      ),
      // No maintained static macOS build; fall back to a system install.
    },
    unavailableHint: 'Install with: brew install aria2',
  ),
  ToolSpec(
    id: ToolId.ffmpeg,
    exeName: 'ffmpeg',
    versionArgs: const ['-version'],
    versionPattern: RegExp(r'ffmpeg version (\S+)'),
    sources: const {
      'linux': InstallSource(
        githubRepo: 'BtbN/FFmpeg-Builds',
        releaseTag: 'latest',
        assetName: 'ffmpeg-master-latest-linux64-gpl.tar.xz',
        archive: ArchiveKind.tarXz,
        innerPath: 'ffmpeg-master-latest-linux64-gpl/bin/ffmpeg',
        extraInner: {
          'ffprobe': 'ffmpeg-master-latest-linux64-gpl/bin/ffprobe'
        },
      ),
      'windows': InstallSource(
        githubRepo: 'BtbN/FFmpeg-Builds',
        releaseTag: 'latest',
        assetName: 'ffmpeg-master-latest-win64-gpl.zip',
        archive: ArchiveKind.zip,
        innerPath: 'ffmpeg-master-latest-win64-gpl/bin/ffmpeg.exe',
        extraInner: {
          'ffprobe.exe': 'ffmpeg-master-latest-win64-gpl/bin/ffprobe.exe'
        },
      ),
      'macos': InstallSource(
        latestUrl: 'https://evermeet.cx/ffmpeg/getrelease/ffmpeg/zip',
        archive: ArchiveKind.zip,
        innerPath: 'ffmpeg',
      ),
    },
  ),
  ToolSpec(
    id: ToolId.magick,
    exeName: 'magick',
    versionArgs: const ['-version'],
    versionPattern: RegExp(r'ImageMagick (\S+)'),
    sources: const {
      'linux': InstallSource(
        githubRepo: 'ImageMagick/ImageMagick',
        assetName: 'ImageMagick-{tag}-gcc-x86_64.AppImage',
        archive: ArchiveKind.appImage,
      ),
      'windows': InstallSource(
        githubRepo: 'ImageMagick/ImageMagick',
        assetName: 'ImageMagick-{tag}-portable-Q16-x64.7z',
        archive: ArchiveKind.sevenZip,
        innerPath: 'magick.exe',
      ),
      // ImageMagick ships no portable macOS build; use Homebrew.
    },
    unavailableHint: 'Install with: brew install imagemagick',
  ),
];
