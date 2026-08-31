/// Media stream info parsed from ffprobe.
class StreamInfo {
  final int index;
  final String type; // video / audio / subtitle / data / attachment
  final String codec;
  final String? profile;
  final int? width, height;
  final String? language;
  final int? channels;
  final int? sampleRate;
  final double? fps;
  final int? bitRate; // bits per second, when the container reports it
  final String? pixFmt; // e.g. yuv420p, yuv420p10le, bgra, pal8
  final bool attachedPic;

  StreamInfo({
    required this.index,
    required this.type,
    required this.codec,
    this.profile,
    this.width,
    this.height,
    this.language,
    this.channels,
    this.sampleRate,
    this.fps,
    this.bitRate,
    this.pixFmt,
    this.attachedPic = false,
  });

  String get summary {
    switch (type) {
      case 'video':
        final res = width != null ? '${width}x$height' : '';
        final f = fps != null ? '${fps!.toStringAsFixed(fps! % 1 == 0 ? 0 : 2)} fps' : '';
        return [codec.toUpperCase(), res, f].where((s) => s.isNotEmpty).join(' · ');
      case 'audio':
        final ch = switch (channels) {
          1 => 'mono',
          2 => 'stereo',
          6 => '5.1',
          8 => '7.1',
          _ => channels != null ? '$channels ch' : '',
        };
        final sr = sampleRate != null ? '${(sampleRate! / 1000).toStringAsFixed(1)} kHz' : '';
        return [codec.toUpperCase(), ch, sr, ?language]
            .where((s) => s.isNotEmpty)
            .join(' · ');
      case 'subtitle':
        return [codec, ?language].join(' · ');
      default:
        return codec;
    }
  }
}

class ProbeResult {
  final String path;
  final String container;
  final double? durationSeconds;
  final int? sizeBytes;
  final List<StreamInfo> streams;
  ProbeResult({
    required this.path,
    required this.container,
    this.durationSeconds,
    this.sizeBytes,
    required this.streams,
  });
}

enum StreamActionKind { copy, transcode, drop }

/// What happens to one stream when converting.
class StreamAction {
  final StreamInfo stream;
  final StreamActionKind kind;
  final String? targetCodec; // for transcode
  final String reason;

  /// This stream's share of the source file.
  final int? originalBytes;

  /// What it is expected to weigh afterwards.
  final int? estimatedBytes;
  final bool userForced; // user chose a codec even though copy was possible

  StreamAction({
    required this.stream,
    required this.kind,
    this.targetCodec,
    required this.reason,
    this.originalBytes,
    this.estimatedBytes,
    this.userForced = false,
  });

  /// Size change as a percentage: -40 means 40% smaller.
  double? get percentChange {
    final o = originalBytes, n = estimatedBytes;
    if (o == null || n == null || o == 0) return null;
    return (n - o) / o * 100;
  }
}

/// How to rate-control transcoded streams.
enum RateMode {
  constantQuality, // CRF-style, the default: quality stays, size varies
  constantBitrate, // fixed bitrate: size is predictable, quality varies
}

/// Picture-level FFmpeg filters applied to transcoded video.
class VideoFilters {
  /// libavfilter scale argument, e.g. '1920:-2'. Empty = keep size.
  String scale = '';
  String fps = ''; // e.g. '30'
  bool deinterlace = false;
  bool denoise = false;
  bool grayscale = false;
  String crop = ''; // 'w:h:x:y'
  String rotate = ''; // '90' | '180' | '270' | 'hflip' | 'vflip'
  String custom = ''; // raw filter chain appended verbatim

  bool get isEmpty =>
      scale.isEmpty &&
      fps.isEmpty &&
      !deinterlace &&
      !denoise &&
      !grayscale &&
      crop.isEmpty &&
      rotate.isEmpty &&
      custom.trim().isEmpty;

  /// Filters in a sensible order: fix the frame, then resize, then
  /// cosmetic passes.
  List<String> chain() => [
        if (deinterlace) 'yadif',
        if (crop.isNotEmpty) 'crop=$crop',
        ...switch (rotate) {
          '90' => ['transpose=1'],
          '180' => ['transpose=1', 'transpose=1'],
          '270' => ['transpose=2'],
          'hflip' => ['hflip'],
          'vflip' => ['vflip'],
          _ => <String>[],
        },
        if (scale.isNotEmpty) 'scale=$scale',
        if (fps.isNotEmpty) 'fps=$fps',
        if (denoise) 'hqdn3d',
        if (grayscale) 'format=gray',
        if (custom.trim().isNotEmpty) custom.trim(),
      ];

  /// Scale target parsed as (width, height); -1/-2 mean "keep ratio".
  (int?, int?) get scaleSize {
    if (scale.isEmpty) return (null, null);
    final parts = scale.split(':');
    if (parts.length < 2) return (null, null);
    final w = int.tryParse(parts[0]);
    final h = int.tryParse(parts[1]);
    return (w != null && w > 0 ? w : null, h != null && h > 0 ? h : null);
  }

  VideoFilters clone() => VideoFilters()
    ..scale = scale
    ..fps = fps
    ..deinterlace = deinterlace
    ..denoise = denoise
    ..grayscale = grayscale
    ..crop = crop
    ..rotate = rotate
    ..custom = custom;
}

/// User-tunable transcode parameters shared by a conversion.
class TranscodeSettings {
  RateMode mode = RateMode.constantQuality;

  /// Quality on the active scale — FFmpeg's CRF for software encoders,
  /// or the hardware family's own CQ/QP scale. null = codec default.
  int? crf;

  /// e.g. '5M' — used in constant-bitrate mode.
  String videoBitrate = '4M';

  /// kbit/s for transcoded audio; null = codec default.
  int? audioKbps;

  /// Use a hardware encoder when one is available for the codec.
  bool hwAccel = false;

  /// True once the user has flipped [hwAccel] themselves, after which
  /// Multi stops re-deciding it for them.
  bool hwAccelUserSet = false;

  /// Keep the output under this many megabytes, by deriving a bitrate
  /// from the duration. null = no cap.
  int? sizeCapMb;

  /// Remove the source file once the conversion succeeds.
  bool deleteSourceWhenDone = false;

  /// Video bitrate the size cap works out to, in bits per second.
  /// Derived by the planner, not set by the user.
  int? cappedVideoBps;

  final VideoFilters filters = VideoFilters();
}

/// A conversion being configured: per-stream selection ('copy', 'drop',
/// or a codec id) on top of the probed input, plus shared settings.
class ConvertPlan {
  final ProbeResult input;
  final String targetContainer;

  /// stream index → 'copy' | 'drop' | codec id
  final Map<int, String> selection;
  final TranscodeSettings settings = TranscodeSettings();

  /// Filled by the planner every time selection/settings change.
  List<StreamAction> actions = [];

  /// Whether hardware encoding should be chosen automatically when the
  /// machine supports the codec in play (Settings > Converting).
  bool preferHardware = true;

  /// Where the output goes; null means beside the source file.
  String? outputDir;

  ConvertPlan({
    required this.input,
    required this.targetContainer,
    required this.selection,
  });

  /// Streams that survive into the output.
  int get keptCount =>
      actions.where((a) => a.kind != StreamActionKind.drop).length;

  /// Nothing survives — e.g. a silent video sent to an audio-only
  /// container. FFmpeg would fall back to guessing its own stream
  /// selection here, so this has to be refused rather than run.
  bool get keepsNothing => keptCount == 0;

  bool get isPureRemux => actions
      .where((a) => a.kind != StreamActionKind.drop)
      .every((a) => a.kind == StreamActionKind.copy);

  int get copiedCount =>
      actions.where((a) => a.kind == StreamActionKind.copy).length;
  int get transcodedCount =>
      actions.where((a) => a.kind == StreamActionKind.transcode).length;
  int get droppedCount =>
      actions.where((a) => a.kind == StreamActionKind.drop).length;

  int? get estimatedTotalBytes {
    var total = 0;
    var any = false;
    for (final a in actions) {
      if (a.estimatedBytes != null) {
        total += a.estimatedBytes!;
        any = true;
      }
    }
    return any ? total : null;
  }

  String get headline {
    if (transcodedCount == 0 && droppedCount == 0) {
      return 'Pure remux — every stream is copied, no quality loss, takes seconds.';
    }
    if (transcodedCount == 0) {
      return 'Remux — kept streams are copied bit-for-bit; $droppedCount dropped.';
    }
    return '$copiedCount copied, $transcodedCount transcoded'
        '${droppedCount > 0 ? ', $droppedCount dropped' : ''} — only what '
        'needs re-encoding gets re-encoded.';
  }
}

enum JobStatus { queued, running, done, failed, canceled }

class ConvertJob {
  final int id;
  final ConvertPlan plan;
  final String outputPath;
  final List<String> args;
  JobStatus status = JobStatus.queued;
  double? progress;
  String statusLine = '';
  final List<String> log = [];
  ConvertJob({
    required this.id,
    required this.plan,
    required this.outputPath,
    required this.args,
  });
}

/// A planned image conversion (ImageMagick).
class ImagePlan {
  final String inputPath;
  final String inputFormat;
  final String targetFormat;
  final bool losslessSource;
  final bool losslessTarget;
  final List<String> operations; // human-readable op list
  final List<String> args;
  ImagePlan({
    required this.inputPath,
    required this.inputFormat,
    required this.targetFormat,
    required this.losslessSource,
    required this.losslessTarget,
    required this.operations,
    required this.args,
  });
}
