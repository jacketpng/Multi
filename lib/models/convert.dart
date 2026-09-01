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

  /// Disposition flags the source carries — 'default', 'forced',
  /// 'hearing_impaired' and the rest. Kept so that changing one flag
  /// does not quietly throw the others away.
  final Set<String> disposition;

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
    this.disposition = const {},
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

  /// Set when [crop] came from FFmpeg's own cropdetect rather than
  /// being typed in, plus a plain-language summary of what it found.
  bool cropDetected = false;
  String cropSummary = '';

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
    ..custom = custom
    ..cropDetected = cropDetected
    ..cropSummary = cropSummary;
}

/// How loudness is handled on transcoded audio.
enum AudioNormalize {
  /// Leave the levels exactly as they are.
  none,

  /// EBU R128 loudness normalisation — the broadcast/streaming standard.
  loudnorm,

  /// Raise the whole track until its loudest sample just fits, which
  /// changes nothing else about the dynamics.
  peak,
}

extension AudioNormalizeInfo on AudioNormalize {
  String get label => switch (this) {
        AudioNormalize.none => 'Leave levels alone',
        AudioNormalize.loudnorm => 'Loudness (EBU R128)',
        AudioNormalize.peak => 'Peak normalise',
      };
  String get description => switch (this) {
        AudioNormalize.none => 'The audio keeps whatever levels it had.',
        AudioNormalize.loudnorm =>
          'Matches a target loudness the way streaming services do, so '
              'this file sits at the same volume as everything else.',
        AudioNormalize.peak =>
          'Turns the whole track up until the loudest moment just fits. '
              'Nothing is compressed.',
      };
}

/// Per-stream metadata and flags written into the output.
class StreamMeta {
  String title = '';
  String language = '';
  bool? isDefault; // null = leave the source disposition alone
  bool? forced;

  bool get isEmpty =>
      title.isEmpty && language.isEmpty && isDefault == null && forced == null;

  StreamMeta clone() => StreamMeta()
    ..title = title
    ..language = language
    ..isDefault = isDefault
    ..forced = forced;
}

/// GIF is a special case: FFmpeg's plain gif encoder quantises to a
/// fixed 256-colour web palette and the result looks dreadful. A
/// per-file palette generated from the actual footage costs one extra
/// filter and is dramatically better, so Multi does it by default.
class GifSettings {
  /// Frames per second. GIF stores delays in hundredths of a second,
  /// so rates that do not divide 100 evenly get uneven timing.
  int fps = 15;

  /// Width in pixels; height follows the aspect ratio. 0 = keep source.
  int width = 480;

  /// palettegen stats_mode: 'diff' weights moving areas, which is
  /// usually what matters in a clip; 'full' treats every pixel equally.
  String statsMode = 'diff';

  /// paletteuse dither. 'bayer' is small and banded, the error-diffusion
  /// modes look better but compress worse.
  String dither = 'bayer';

  /// bayer_scale 0-5: lower is a coarser, more visible pattern that
  /// compresses smaller.
  int bayerScale = 5;

  /// Reuse the palette between frames where the picture has not moved.
  bool diffRectangles = true;

  /// 0 = loop forever, -1 = play once.
  int loop = 0;

  /// Maximum palette size. Fewer colours, smaller file.
  int maxColors = 256;
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

  /// Encode twice, measuring on the first pass so the second can spend
  /// the bit budget where it matters. Only meaningful at a fixed
  /// bitrate — at constant quality there is nothing to aim at.
  bool twoPass = false;

  // ---- audio ----

  /// Output sample rate in Hz; null = keep the source's (moved to the
  /// nearest the encoder accepts, if it has to be).
  int? audioSampleRate;

  /// Output channel count; null = keep the source's.
  int? audioChannels;

  /// Use the encoder's variable-bitrate mode instead of a fixed rate.
  bool audioVbr = false;

  /// Quality on that encoder's own VBR scale; null = its default.
  double? audioVbrQuality;

  AudioNormalize normalize = AudioNormalize.none;

  /// EBU R128 targets: integrated loudness (LUFS), true peak (dBTP),
  /// loudness range (LU). The defaults are the streaming-service ones.
  double loudnessTarget = -16;
  double truePeak = -1.5;
  double loudnessRange = 11;

  /// Plain gain in dB, applied after any normalisation.
  double gainDb = 0;

  /// Loudest sample in the source, in dBFS, as measured by FFmpeg.
  /// Peak normalisation needs a real measurement — there is no way to
  /// know how much headroom a file has without looking.
  double? measuredPeakDb;

  // ---- subtitles ----

  /// Source index of a subtitle stream to burn into the picture, or
  /// null. Burning in forces the video to be re-encoded.
  int? burnInSubtitle;

  final VideoFilters filters = VideoFilters();
  final GifSettings gif = GifSettings();
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

  /// What FFmpeg says the encoders in this plan support, keyed by
  /// encoder name. Filled in before the arguments are built so that
  /// pixel formats, sample rates and channel counts can be matched to
  /// what will actually be accepted.
  final Map<String, dynamic> encoderCaps = {};

  /// Muxer capabilities for the target container.
  dynamic muxerCaps;

  /// Extra encoder options the user set, per stream index then option
  /// name — every option FFmpeg reports for that encoder is available.
  final Map<int, Map<String, String>> streamOptions = {};

  /// Container-level options, by name.
  final Map<String, String> muxerOptions = {};

  /// Trim: keep only this part of the input.
  String? trimStart;
  String? trimEnd;

  /// Title, language and default/forced flags per source stream index.
  final Map<int, StreamMeta> streamMeta = {};

  /// Title written into the file itself.
  String fileTitle = '';

  /// Order the kept streams are written in, as source indices. null =
  /// the order they appear in the source.
  List<int>? streamOrder;

  /// Also write each text subtitle track out as its own file next to
  /// the output.
  bool extractSubtitles = false;
  String extractSubtitleFormat = 'subrip';


  StreamMeta metaFor(int index) =>
      streamMeta.putIfAbsent(index, () => StreamMeta());

  /// Languages present on audio and subtitle streams, lower-cased.
  /// 'und' stands in for anything untagged.
  Set<String> get languagesPresent => {
        for (final s in input.streams)
          if (s.type == 'audio' || s.type == 'subtitle')
            (s.language ?? 'und').toLowerCase(),
      };

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

  /// Live figures from FFmpeg's -progress stream.
  String? speed; // '2.31x'
  String? bitrate; // '1234.5kbits/s'
  int? outputBytes; // bytes written so far
  double? etaSeconds; // remaining wall-clock, from speed and duration
  int? frame;
  double? outSeconds; // position within the input

  /// Which pass is running when two-pass encoding is on.
  int pass = 0;
  int passes = 1;

  /// Sidecar subtitle files written alongside the output.
  final List<String> sidecarFiles = [];

  /// Adaptations that were needed to make FFmpeg accept the job.
  List<String> repairedWith = const [];

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
