import 'dart:io';

enum Engine { ytDlp, galleryDl, aria2 }

extension EngineInfo on Engine {
  String get displayName => switch (this) {
        Engine.ytDlp => 'yt-dlp',
        Engine.galleryDl => 'gallery-dl',
        Engine.aria2 => 'aria2',
      };
}

enum PresetId { speed, balanced, gentle }

extension PresetInfo on PresetId {
  String get label => switch (this) {
        PresetId.speed => 'Speed',
        PresetId.balanced => 'Balanced',
        PresetId.gentle => 'Low profile',
      };
  String get description => switch (this) {
        PresetId.speed =>
          'Parallel connections, no delays. Fastest, but easy to rate-limit.',
        PresetId.balanced => 'Sensible defaults for most sites.',
        PresetId.gentle =>
          'Single connection, randomized delays, capped speed. For if you '
          'don\'t want to look like a robot.',
      };
}

enum CookieSource {
  none,
  librewolf,
  firefox,
  chrome,
  chromium,
  edge,
  brave,
  opera,
  vivaldi,
  safari,
  file,
}

extension CookieSourceInfo on CookieSource {
  String get label => switch (this) {
        CookieSource.none => 'No cookies',
        CookieSource.file => 'Cookie file (Netscape format)…',
        CookieSource.librewolf => 'LibreWolf',
        _ => name[0].toUpperCase() + name.substring(1),
      };

  /// Value for --cookies-from-browser, or null.
  ///
  /// LibreWolf is deliberately absent: neither yt-dlp nor gallery-dl
  /// knows it by name, so it is passed as `firefox:<profile path>` with
  /// a profile located by BrowserProfiles.
  String? get browserKey => switch (this) {
        CookieSource.none ||
        CookieSource.file ||
        CookieSource.librewolf =>
          null,
        _ => name,
      };

  /// True when the browser stores cookies in Firefox's profile format.
  bool get isFirefoxFamily =>
      this == CookieSource.firefox || this == CookieSource.librewolf;

  bool get availableOnThisOs => switch (this) {
        CookieSource.safari => Platform.isMacOS,
        _ => true,
      };
}

/// One configurable CLI option, rendered generically in the options panel.
sealed class OptionDef {
  final String id;
  final String label;
  final String? help;
  final String group;
  const OptionDef(
      {required this.id, required this.label, this.help, required this.group});

  List<String> args(Object? value);
}

class FlagOption extends OptionDef {
  final List<String> flagArgs;
  final bool defaultValue;
  const FlagOption({
    required super.id,
    required super.label,
    super.help,
    required super.group,
    required this.flagArgs,
    this.defaultValue = false,
  });

  @override
  List<String> args(Object? value) => (value as bool? ?? defaultValue) ? flagArgs : const [];
}

class TextOption extends OptionDef {
  final String flag;
  final String? placeholder;
  const TextOption({
    required super.id,
    required super.label,
    super.help,
    required super.group,
    required this.flag,
    this.placeholder,
  });

  @override
  List<String> args(Object? value) {
    final v = (value as String?)?.trim();
    return (v == null || v.isEmpty) ? const [] : [flag, v];
  }
}

class ChoiceOption extends OptionDef {
  final String? flag; // null → the value IS the args (joined by \x00)
  final Map<String, String> choices; // value -> label
  final Map<String, String> descriptions; // value -> small helper text
  final String defaultValue;
  const ChoiceOption({
    required super.id,
    required super.label,
    super.help,
    required super.group,
    this.flag,
    required this.choices,
    this.descriptions = const {},
    required this.defaultValue,
  });

  @override
  List<String> args(Object? value) {
    final v = (value as String?) ?? defaultValue;
    if (v.isEmpty) return const [];
    if (flag == null) return v.split('\x00').where((s) => s.isNotEmpty).toList();
    return [flag!, v];
  }
}

/// User-tunable download configuration attached to a task.
class DownloadOptions {
  PresetId preset;
  CookieSource cookieSource;
  String? cookieFilePath;
  String? outputDir;

  /// Container id from the converter to remux/transcode into after the
  /// download finishes, or null for no conversion.
  String? convertTo;

  /// Values for engine-specific [OptionDef]s, keyed by option id.
  Map<String, Object?> values;

  /// Free-form extra CLI arguments — full access to every flag.
  String extraArgs;

  DownloadOptions({
    this.preset = PresetId.balanced,
    this.cookieSource = CookieSource.none,
    this.cookieFilePath,
    this.outputDir,
    this.convertTo,
    Map<String, Object?>? values,
    this.extraArgs = '',
  }) : values = values ?? {};

  DownloadOptions clone() => DownloadOptions(
        preset: preset,
        cookieSource: cookieSource,
        cookieFilePath: cookieFilePath,
        outputDir: outputDir,
        convertTo: convertTo,
        values: Map.of(values),
        extraArgs: extraArgs,
      );
}

/// One item inside a multi-item download — a playlist video, or one
/// file of a parallel aria2 batch. Each renders its own progress bar.
class DownloadPart {
  final String key; // playlist index, or aria2 gid
  String? title;
  int percent;
  String? speed;
  String? eta;

  DownloadPart({required this.key, this.title, this.percent = 0, this.speed, this.eta});

  bool get done => percent >= 100;
  double get fraction => (percent / 100).clamp(0.0, 1.0);

  /// '#3' for playlist videos, '#a1b2' for aria2 gids.
  String get label =>
      int.tryParse(key) != null ? '#$key' : '#${key.substring(0, key.length.clamp(0, 4))}';
}

enum TaskStatus {
  needsCookies, // login-walled site: pick cookies before Multi touches it
  needsEngine, // nothing claims this URL — the user picks what to do
  resolving, // deciding which engine handles the URL, fetching preview info
  awaitingChoice, // link-scrape result waiting for the user's selection
  ready, // routed + previewed, waiting for the user to press Start
  queued, // started, waiting for a free slot
  running,
  done,
  failed,
  canceled,
}

/// One downloadable format/version reported by yt-dlp for a URL.
class MediaFormat {
  final String id;
  final String ext; // container
  final String vcodec; // 'none' when audio-only
  final String acodec; // 'none' when video-only
  final int? width, height;
  final double? fps;
  final double? tbr; // total bitrate, kbit/s
  final int? filesize; // bytes
  final bool sizeIsEstimate;
  final String note;
  final String? language;

  MediaFormat({
    required this.id,
    required this.ext,
    required this.vcodec,
    required this.acodec,
    this.width,
    this.height,
    this.fps,
    this.tbr,
    this.filesize,
    this.sizeIsEstimate = false,
    this.note = '',
    this.language,
  });

  bool get hasVideo => vcodec.isNotEmpty && vcodec != 'none';
  bool get hasAudio => acodec.isNotEmpty && acodec != 'none';

  /// 'avc1.640028' → 'H.264' etc., for humans.
  static String prettyCodec(String c) {
    final base = c.split('.').first.toLowerCase();
    return switch (base) {
      'avc1' || 'avc3' || 'h264' => 'H.264',
      'hev1' || 'hvc1' || 'h265' || 'hevc' => 'HEVC',
      'av01' || 'av1' => 'AV1',
      'vp09' || 'vp9' => 'VP9',
      'vp08' || 'vp8' => 'VP8',
      'mp4a' || 'aac' => 'AAC',
      'opus' => 'Opus',
      'mp3' => 'MP3',
      'vorbis' => 'Vorbis',
      'ec-3' || 'eac3' => 'E-AC-3',
      'ac-3' || 'ac3' => 'AC-3',
      'flac' => 'FLAC',
      'none' => '',
      _ => c,
    };
  }
}

/// What Multi learned about a URL before downloading anything.
class MediaPreview {
  String? title;
  String? uploader;
  String? thumbnailUrl;
  double? durationSeconds;
  int? playlistCount; // >1 when the URL is a playlist
  List<MediaFormat> formats = [];

  // gallery-dl: a sample of what the gallery contains.
  List<String> sampleItems = [];

  // aria2 direct downloads: what the server says about the file.
  String? fileName;
  int? fileSize;
  String? contentType;
}

class DownloadTask {
  final int id;
  final String url;
  Engine engine;
  final DownloadOptions options;
  TaskStatus status = TaskStatus.queued;
  double? progress; // 0..1, null = indeterminate
  String statusLine = '';
  String? title;
  final List<String> log = [];
  Process? process;

  /// All processes of this task — several when the Speed preset shards
  /// a playlist/gallery across parallel workers.
  final List<Process> processes = [];
  int filesDone = 0;

  /// Pre-download info: formats, sizes, samples. Filled while resolving.
  MediaPreview? preview;

  /// yt-dlp -f selector chosen in the format picker; null = best (auto).
  String? chosenFormat;

  /// yt-dlp -S sort expression from a format preset (e.g. "most
  /// compatible" → prefer H.264/AAC, falling back gracefully).
  String? formatSort;

  /// Human summary of the chosen format for the card.
  String? chosenFormatLabel;

  /// Files this task produced (for convert-after-download).
  final List<String> outputFiles = [];

  /// Per-item progress for multi-item tasks: playlist videos (keyed by
  /// playlist index) or parallel aria2 files (keyed by gid). Each gets
  /// its own progress bar in the UI.
  final Map<String, DownloadPart> parts = {};

  /// Total items expected, when known (playlist length / file count).
  int? partsTotal;

  /// gallery-dl: the {num} of the last file, used to notice when a new
  /// post starts and the per-post {count} stops being a run total.
  int? lastItemNum;
  bool multiplePosts = false;

  /// Parts sorted for display: numeric keys in order, others after.
  List<DownloadPart> get sortedParts {
    final list = parts.values.toList();
    list.sort((a, b) {
      final ai = int.tryParse(a.key), bi = int.tryParse(b.key);
      if (ai != null && bi != null) return ai.compareTo(bi);
      if (ai != null) return -1;
      if (bi != null) return 1;
      return a.key.compareTo(b.key);
    });
    return list;
  }

  int get partsDone => parts.values.where((p) => p.done).length;
  int get partsActive => parts.values.where((p) => !p.done).length;

  /// Set for link-scrape tasks: chosen direct URLs for aria2.
  List<String>? directUrls;

  DownloadTask({
    required this.id,
    required this.url,
    required this.engine,
    required this.options,
  });

  void addLog(String line) {
    log.add(line);
    if (log.length > 400) log.removeRange(0, log.length - 400);
  }
}
