import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:path/path.dart' as p;

import '../models/convert.dart';
import '../models/tool.dart';
import 'codec_catalog.dart';
import 'ffmpeg_capabilities.dart';
import 'tool_manager.dart';

export 'codec_catalog.dart'
    show
        CodecInfo,
        HwFamily,
        CodecCatalog,
        hwFamilies,
        codecCatalog,
        codecInfo,
        shortBlurbForRawCodec;

/// What a target container can hold. The planner's rule stays: copy
/// whenever the codec is allowed, transcode only when it isn't — unless
/// the user explicitly picks a codec for a stream.
class ContainerSpec {
  final String id;
  final String label;
  final String extension;
  final bool audioOnly;
  final Set<String> video; // ffprobe codec_name values; {'*'} = anything
  final Set<String> audio;
  final Set<String> subtitle;
  final String videoTarget; // default codec to transcode to
  final String audioTarget;
  final String? subtitleTarget;
  final List<String> extraOutputArgs;

  /// Elementary-stream containers that hold exactly one audio track.
  /// FFmpeg rejects a second with "Exactly one ... audio stream is
  /// required", so extra tracks have to be dropped rather than offered.
  final bool singleAudioStream;

  const ContainerSpec({
    required this.id,
    required this.label,
    required this.extension,
    this.audioOnly = false,
    this.video = const {},
    required this.audio,
    this.subtitle = const {},
    this.videoTarget = '',
    required this.audioTarget,
    this.subtitleTarget,
    this.extraOutputArgs = const [],
    this.singleAudioStream = false,
  });

  bool get allowsAnyVideo => video.contains('*');
  bool get allowsAnyAudio => audio.contains('*');

  bool allows(String type, String codec) {
    final set = switch (type) {
      'video' => video,
      'audio' => audio,
      'subtitle' => subtitle,
      _ => const <String>{},
    };
    return set.contains('*') || set.contains(codec);
  }
}

const containerSpecs = <ContainerSpec>[
  ContainerSpec(
    id: 'mp4',
    label: 'MP4',
    extension: 'mp4',
    video: {'h264', 'hevc', 'av1', 'vp9', 'mpeg4', 'mpeg2video', 'mjpeg'},
    audio: {
      'aac', 'mp3', 'ac3', 'eac3', 'alac', 'opus', 'flac', 'dts', 'mp2'
    },
    subtitle: {'mov_text'},
    videoTarget: 'h264',
    audioTarget: 'aac',
    subtitleTarget: 'mov_text',
    extraOutputArgs: ['-movflags', '+faststart'],
  ),
  ContainerSpec(
    id: 'mkv',
    label: 'MKV',
    extension: 'mkv',
    video: {'*'},
    audio: {'*'},
    subtitle: {
      'subrip', 'ass', 'ssa', 'webvtt', 'hdmv_pgs_subtitle', 'dvd_subtitle'
    },
    videoTarget: 'h264',
    audioTarget: 'aac',
    subtitleTarget: 'srt',
  ),
  ContainerSpec(
    id: 'webm',
    label: 'WebM',
    extension: 'webm',
    video: {'vp8', 'vp9', 'av1'},
    audio: {'opus', 'vorbis'},
    subtitle: {'webvtt'},
    videoTarget: 'vp9',
    audioTarget: 'opus',
    subtitleTarget: 'webvtt',
  ),
  ContainerSpec(
    id: 'mov',
    label: 'MOV',
    extension: 'mov',
    // No AV1: FFmpeg's mov muxer rejects it with "av1 only supported in
    // MP4 and AVIF".
    video: {
      'h264', 'hevc', 'prores', 'dnxhd', 'mjpeg', 'mpeg4',
      'rawvideo', 'qtrle'
    },
    audio: {
      'aac', 'alac', 'pcm_s16le', 'pcm_s24le', 'pcm_s16be', 'mp3', 'ac3'
    },
    subtitle: {'mov_text'},
    videoTarget: 'h264',
    audioTarget: 'aac',
    subtitleTarget: 'mov_text',
  ),
  ContainerSpec(
    id: 'avi',
    label: 'AVI',
    extension: 'avi',
    // No H.264: MP4 and MKV carry it in AVCC form and AVI needs
    // Annex-B, so copying one in fails with "h264 bitstream malformed,
    // no startcode found". AVI's native codecs are the MPEG-4 family.
    video: {
      'mpeg4', 'mjpeg', 'huffyuv', 'ffv1', 'utvideo', 'magicyuv',
      'rawvideo', 'dvvideo', 'mpeg2video', 'wmv2'
    },
    // No AAC: FFmpeg's avi muxer rejects an AAC packet copy with
    // "Invalid data found when processing input". MP3 is the format AVI
    // is actually used with.
    audio: {'mp3', 'ac3', 'pcm_s16le', 'mp2', 'wmav2'},
    videoTarget: 'mpeg4',
    audioTarget: 'mp3',
  ),
  ContainerSpec(
    id: 'mpegts',
    label: 'MPEG-TS',
    extension: 'ts',
    video: {'h264', 'hevc', 'mpeg2video', 'mpeg4'},
    audio: {'aac', 'mp3', 'ac3', 'eac3', 'mp2'},
    videoTarget: 'h264',
    audioTarget: 'aac',
  ),
  ContainerSpec(
    id: 'gif',
    label: 'GIF',
    extension: 'gif',
    video: {'gif'},
    audio: {},
    videoTarget: 'gif',
    audioTarget: '',
  ),
  // Audio-only targets.
  ContainerSpec(
    id: 'mp3',
    singleAudioStream: true,
    label: 'MP3',
    extension: 'mp3',
    audioOnly: true,
    audio: {'mp3'},
    audioTarget: 'mp3',
  ),
  ContainerSpec(
    id: 'm4a',
    label: 'M4A',
    extension: 'm4a',
    audioOnly: true,
    audio: {'aac', 'alac'},
    audioTarget: 'aac',
  ),
  ContainerSpec(
    id: 'opus',
    label: 'Opus',
    extension: 'opus',
    audioOnly: true,
    audio: {'opus'},
    audioTarget: 'opus',
  ),
  ContainerSpec(
    id: 'ogg',
    label: 'OGG',
    extension: 'ogg',
    audioOnly: true,
    audio: {'vorbis', 'opus', 'flac'},
    audioTarget: 'vorbis',
  ),
  ContainerSpec(
    id: 'flac',
    singleAudioStream: true,
    label: 'FLAC',
    extension: 'flac',
    audioOnly: true,
    audio: {'flac'},
    audioTarget: 'flac',
  ),
  ContainerSpec(
    id: 'wav',
    singleAudioStream: true,
    label: 'WAV',
    extension: 'wav',
    audioOnly: true,
    audio: {'pcm_s16le', 'pcm_s24le', 'pcm_f32le'},
    audioTarget: 'pcm_s16le',
  ),
  ContainerSpec(
    id: 'ac3',
    singleAudioStream: true,
    label: 'AC-3',
    extension: 'ac3',
    audioOnly: true,
    audio: {'ac3'},
    audioTarget: 'ac3',
  ),
];

/// Which encoders the local FFmpeg build actually has, and which
/// hardware families work on this machine.
class EncoderInventory {
  final Set<String> encoders;

  /// encoder name → codec_name it produces.
  final Map<String, String> codecOf;

  /// encoder name → 'video' | 'audio'.
  final Map<String, String> kindOf;

  /// Hardware families available here, best first.
  final List<String> hwFamilies;

  /// Hardware encoders proven to work by a real test encode, by exact
  /// name ('h264_vaapi'). A GPU commonly supports some codecs and not
  /// others — this machine encodes H.264 and HEVC through VAAPI but not
  /// VP9 or AV1 — so the family alone says nothing about a given codec.
  /// Empty means "not probed yet"; treat every listed family as usable.
  final Set<String> provenHwEncoders;

  const EncoderInventory({
    this.encoders = const {},
    this.codecOf = const {},
    this.kindOf = const {},
    this.hwFamilies = const [],
    this.provenHwEncoders = const {},
  });

  static const empty = EncoderInventory();

  /// Parse `ffmpeg -encoders`.
  factory EncoderInventory.parse(String output, {List<String> hw = const []}) {
    final encoders = <String>{};
    final codecOf = <String, String>{};
    final kindOf = <String, String>{};
    final line = RegExp(r'^\s*([VA])[A-Z.]{5}\s+(\S+)\s+(.*)$');
    final codecTag = RegExp(r'\(codec ([^)]+)\)');
    for (final raw in output.split('\n')) {
      final m = line.firstMatch(raw);
      if (m == null) continue;
      final kind = m.group(1) == 'V' ? 'video' : 'audio';
      final name = m.group(2)!;
      if (name == '=') continue;
      encoders.add(name);
      kindOf[name] = kind;
      final tag = codecTag.firstMatch(m.group(3)!);
      codecOf[name] = tag != null ? tag.group(1)!.trim() : name;
    }
    return EncoderInventory(
        encoders: encoders, codecOf: codecOf, kindOf: kindOf, hwFamilies: hw);
  }

  /// Best hardware encoder for a codec that this machine can really
  /// use, or null.
  String? hwEncoderFor(String codecId) {
    for (final family in hwFamilies) {
      final name = '${codecId}_$family';
      if (!encoders.contains(name)) continue;
      // Once probing has happened, only an encoder that actually
      // produced a frame counts.
      if (provenHwEncoders.isNotEmpty && !provenHwEncoders.contains(name)) {
        continue;
      }
      return name;
    }
    return null;
  }

  HwFamily? hwFamilyFor(String codecId) {
    final enc = hwEncoderFor(codecId);
    if (enc == null) return null;
    return hwFamiliesById[enc.split('_').last];
  }
}

const hwFamiliesById = hwFamilies;

class ConvertPlanner {
  final ToolManager tools;
  late final FfmpegCapabilities capabilities =
      FfmpegCapabilities(() => tools.pathFor(ToolId.ffmpeg) ?? 'ffmpeg');
  ConvertPlanner(this.tools);

  /// Ask FFmpeg what every encoder in this plan accepts, so the
  /// arguments can be tailored to it. Cheap after the first call.
  Future<void> loadCapabilities(ConvertPlan plan, ContainerSpec target,
      EncoderInventory inv) async {
    for (final a in plan.actions) {
      if (a.kind != StreamActionKind.transcode) continue;
      final encoder = encoderNameFor(a.targetCodec!, plan.settings, inv);
      if (encoder == null || plan.encoderCaps.containsKey(encoder)) continue;
      plan.encoderCaps[encoder] = await capabilities.encoder(encoder);
    }
    plan.muxerCaps ??= await capabilities.muxer(muxerNameFor(target));
  }

  /// FFmpeg's muxer name for a container, which is not always its id.
  static String muxerNameFor(ContainerSpec target) => switch (target.id) {
        'mkv' => 'matroska',
        'mp3' => 'mp3',
        'm4a' => 'ipod',
        'ac3' => 'ac3',
        _ => target.id,
      };

  /// The encoder that will actually be used for a codec.
  String? encoderNameFor(
      String codecId, TranscodeSettings st, EncoderInventory inv) {
    if (st.hwAccel) {
      final hw = inv.hwEncoderFor(codecId);
      if (hw != null) return hw;
    }
    final c = CodecCatalog.byId(codecId);
    if (c == null) return codecId;
    return CodecCatalog.availableEncoder(c, inv.encoders) ?? c.encoder;
  }

  /// Choose a pixel format the encoder actually lists, preferring the
  /// source's own so nothing is converted needlessly.
  static String? pickPixelFormat(List<String> supported, String? sourcePix) {
    if (supported.isEmpty) return null;
    if (sourcePix != null && supported.contains(sourcePix)) return null;
    for (final preferred in const [
      'yuv420p', 'yuvj420p', 'nv12', 'yuv422p', 'yuv420p10le', 'uyvy422'
    ]) {
      if (supported.contains(preferred)) return preferred;
    }
    return supported.first;
  }

  /// Nearest sample rate the encoder accepts.
  static int? pickSampleRate(List<int> supported, int? sourceRate) {
    if (supported.isEmpty || sourceRate == null) return null;
    if (supported.contains(sourceRate)) return null;
    var best = supported.first;
    for (final r in supported) {
      if ((r - sourceRate).abs() < (best - sourceRate).abs()) best = r;
    }
    return best;
  }

  Future<ProbeResult> probe(String path) async {
    final ffprobe = tools.ffprobePath;
    if (ffprobe == null) {
      throw 'FFmpeg (ffprobe) is not installed yet — check the Tools page';
    }
    final r = await Process.run(ffprobe, [
      '-v', 'quiet',
      '-print_format', 'json',
      '-show_format',
      '-show_streams',
      path,
    ]).timeout(const Duration(seconds: 30));
    if (r.exitCode != 0) {
      throw 'Could not read file: ${r.stderr}';
    }
    final j = jsonDecode(r.stdout as String) as Map<String, dynamic>;
    final fmt = (j['format'] as Map<String, dynamic>?) ?? {};
    final streams = ((j['streams'] as List?) ?? [])
        .cast<Map<String, dynamic>>()
        .map((s) {
      double? fps;
      final rate = s['avg_frame_rate'] as String?;
      if (rate != null && rate.contains('/') && !rate.startsWith('0/')) {
        final parts = rate.split('/');
        final den = double.tryParse(parts[1]) ?? 1;
        if (den != 0) fps = (double.tryParse(parts[0]) ?? 0) / den;
      }
      return StreamInfo(
        index: s['index'] as int,
        type: (s['codec_type'] as String?) ?? 'data',
        codec: (s['codec_name'] as String?) ?? 'unknown',
        profile: s['profile']?.toString(),
        width: s['width'] as int?,
        height: s['height'] as int?,
        language: (s['tags'] as Map<String, dynamic>?)?['language'] as String?,
        channels: s['channels'] as int?,
        sampleRate: int.tryParse(s['sample_rate']?.toString() ?? ''),
        fps: fps,
        bitRate: int.tryParse(s['bit_rate']?.toString() ?? ''),
        pixFmt: s['pix_fmt'] as String?,
        attachedPic: ((s['disposition']
                    as Map<String, dynamic>?)?['attached_pic'] as int?) ==
            1,
      );
    }).toList();
    return ProbeResult(
      path: path,
      container: (fmt['format_name'] as String?) ?? p.extension(path),
      durationSeconds: double.tryParse(fmt['duration']?.toString() ?? ''),
      sizeBytes: int.tryParse(fmt['size']?.toString() ?? ''),
      streams: streams,
    );
  }

  /// Every codec the target container accepts *and* this FFmpeg build
  /// can encode, most popular and compatible first.
  ///
  /// For a permissive container like MKV this really is everything the
  /// build offers; the curated codecs come first, then the rest.
  List<CodecInfo> encodableFor(
      ContainerSpec target, String type, EncoderInventory inv) {
    final anything =
        type == 'video' ? target.allowsAnyVideo : target.allowsAnyAudio;
    final allowed = type == 'video' ? target.video : target.audio;

    final out = <CodecInfo>[];
    final seen = <String>{};

    for (final c in CodecCatalog.curated.where((c) => c.kind == type)) {
      if (!anything && !allowed.contains(c.id)) continue;
      // Only offer it if the build can actually encode it.
      if (inv.encoders.isEmpty ||
          CodecCatalog.availableEncoder(c, inv.encoders) != null) {
        out.add(c);
        seen.add(c.id);
      }
    }
    out.sort((a, b) => a.rank.compareTo(b.rank));

    if (anything && inv.encoders.isNotEmpty) {
      // The long tail: anything else the build can encode.
      final extra = <CodecInfo>[];
      for (final enc in inv.encoders) {
        if (inv.kindOf[enc] != type) continue;
        final codec = inv.codecOf[enc] ?? enc;
        if (!seen.add(codec)) continue;
        extra.add(CodecCatalog.generic(codec, type, enc));
      }
      extra.sort((a, b) => a.id.compareTo(b.id));
      out.addAll(extra);
    }
    return out;
  }

  /// Quality scale in force for a codec: the hardware family's own when
  /// hardware encoding is on, otherwise FFmpeg's CRF.
  (int min, int max, int def, bool supported) qualityScale(
      String codecId, TranscodeSettings st, EncoderInventory inv) {
    final c = CodecCatalog.byId(codecId);
    if (st.hwAccel) {
      final fam = inv.hwFamilyFor(codecId);
      if (fam != null) {
        return fam.supportsConstantQuality
            ? (fam.cqMin, fam.cqMax, fam.cqDefault, true)
            : (0, 0, 0, false);
      }
    }
    if (c == null || !c.supportsCrf) return (0, 0, 0, false);
    return (c.crfMin, c.crfMax, c.crfDefault, true);
  }

  /// Default selection: copy what fits, transcode what doesn't (to the
  /// container's default codec), drop what can't exist there.
  ConvertPlan plan(ProbeResult input, ContainerSpec target,
      {EncoderInventory inventory = EncoderInventory.empty,
      bool preferHardware = true}) {
    final selection = <int, String>{};
    for (final s in input.streams) {
      switch (s.type) {
        case 'video':
          if (target.audioOnly || target.video.isEmpty) {
            selection[s.index] = 'drop';
          } else if (s.attachedPic && target.id == 'gif') {
            selection[s.index] = 'drop';
          } else if (target.allows('video', s.codec)) {
            selection[s.index] = 'copy';
          } else {
            selection[s.index] = target.videoTarget;
          }
          break;
        case 'audio':
          if (target.audio.isEmpty) {
            selection[s.index] = 'drop';
          } else if (target.singleAudioStream &&
              input.streams.any((o) =>
                  o.type == 'audio' && o.index < s.index)) {
            // Only the first track survives in a single-stream container.
            selection[s.index] = 'drop';
          } else if (target.allows('audio', s.codec)) {
            selection[s.index] = 'copy';
          } else {
            selection[s.index] = target.audioTarget;
          }
          break;
        case 'subtitle':
          if (target.subtitle.isEmpty || _isImageSub(s.codec)) {
            selection[s.index] =
                target.allows('subtitle', s.codec) ? 'copy' : 'drop';
          } else if (target.allows('subtitle', s.codec)) {
            selection[s.index] = 'copy';
          } else {
            selection[s.index] = target.subtitleTarget ?? 'drop';
          }
          break;
        default:
          selection[s.index] = 'drop';
      }
    }
    final plan = ConvertPlan(
        input: input, targetContainer: target.id, selection: selection);

    plan.preferHardware = preferHardware;
    recompute(plan, target, inventory);
    return plan;
  }

  /// The codec a video stream is currently being transcoded to, or null
  /// when no video stream is being re-encoded.
  ///
  /// Reads the stream type rather than looking the codec up in the
  /// catalog, so a codec Multi has no entry for still counts.
  String? transcodedVideoCodec(ConvertPlan plan) {
    for (final s in plan.input.streams) {
      if (s.type != 'video' || s.attachedPic) continue;
      final sel = plan.selection[s.index];
      if (sel != null && sel != 'copy' && sel != 'drop') return sel;
    }
    return null;
  }

  /// Turn hardware encoding on whenever this machine can actually do it
  /// for the codec in play.
  ///
  /// This has to run after *every* change, not just when the plan is
  /// first built: switching a stream from Copy to a codec, or picking a
  /// different codec, changes whether a hardware encoder exists. An
  /// explicit choice by the user is never overridden.
  void applyHardwareDefault(ConvertPlan plan, EncoderInventory inventory) {
    final st = plan.settings;
    if (st.hwAccelUserSet) return;
    final codec = transcodedVideoCodec(plan);
    if (codec == null) {
      st.hwAccel = false;
      return;
    }
    final available = inventory.hwEncoderFor(codec) != null;
    st.hwAccel = plan.preferHardware && available;
    if (st.hwAccel) {
      final fam = inventory.hwFamilyFor(codec);
      if (fam != null && !fam.supportsConstantQuality) {
        st.mode = RateMode.constantBitrate;
      }
    }
  }

  bool _isImageSub(String codec) =>
      const {'hdmv_pgs_subtitle', 'dvd_subtitle', 'dvb_subtitle', 'xsub'}
          .contains(codec);

  /// Rebuild actions (badges, reasons, size estimates) from the current
  /// selection and settings. Call after any change.
  void recompute(ConvertPlan plan, ContainerSpec target,
      [EncoderInventory inventory = EncoderInventory.empty]) {
    applyHardwareDefault(plan, inventory);
    final dur = plan.input.durationSeconds;
    List<StreamAction> build() => [
          for (final s in plan.input.streams)
            _action(s, plan.selection[s.index] ?? 'drop', target,
                plan.settings, dur, inventory),
        ];
    plan.actions = build();
    // A size cap depends on what the audio actually costs, which is only
    // known once the actions exist — so work it out, then rebuild so the
    // video estimate reflects the capped bitrate.
    if (plan.settings.sizeCapMb != null) {
      plan.settings.cappedVideoBps = videoBitrateForSizeCap(plan);
      plan.actions = build();
    } else {
      plan.settings.cappedVideoBps = null;
    }
  }

  StreamAction _action(StreamInfo s, String sel, ContainerSpec target,
      TranscodeSettings st, double? dur, EncoderInventory inv) {
    final original = _estimateCopy(s, dur);
    if (sel == 'drop') {
      final reason = switch (s.type) {
        'video' when s.attachedPic =>
          'Cover art — not carried into ${target.label}',
        'video' => target.audioOnly
            ? '${target.label} holds audio only'
            : '${target.label} can\'t hold this video',
        'audio' => target.audio.isEmpty
            ? '${target.label} holds no audio'
            : '${target.label} holds a single audio track, and this is not '
                'the first',
        'subtitle' => _isImageSub(s.codec)
            ? 'Image-based subtitles can\'t become text in ${target.label}'
            : '${target.label} has no subtitle support',
        _ => 'Data/attachment stream — not carried over',
      };
      return StreamAction(
          stream: s,
          kind: StreamActionKind.drop,
          reason: reason,
          originalBytes: original,
          estimatedBytes: 0);
    }
    if (sel == 'copy') {
      return StreamAction(
        stream: s,
        kind: StreamActionKind.copy,
        reason:
            '${s.codec.toUpperCase()} is supported in ${target.label} — copied bit-for-bit',
        originalBytes: original,
        estimatedBytes: original,
      );
    }
    final wasAllowed = target.allows(s.type, s.codec);
    return StreamAction(
      stream: s,
      kind: StreamActionKind.transcode,
      targetCodec: sel,
      userForced: wasAllowed,
      reason: wasAllowed
          ? 'Re-encode chosen — ${s.codec.toUpperCase()} could have been copied'
          : '${target.label} can\'t hold ${s.codec.toUpperCase()} ${s.type}',
      originalBytes: original,
      estimatedBytes: _estimateTranscode(s, sel, st, dur, inv),
    );
  }

  // ---- size estimation (rough, labelled with ~ in the UI) ----

  int? _estimateCopy(StreamInfo s, double? dur) {
    if (dur == null) return null;
    final rate = s.bitRate?.toDouble() ?? _fallbackRate(s);
    if (rate == null) return null;
    return (rate * dur / 8).round();
  }

  double? _fallbackRate(StreamInfo s) {
    switch (s.type) {
      case 'video':
        if (s.width == null || s.height == null) return null;
        final bpp = CodecCatalog.byId(s.codec)?.bpp;
        return (bpp == null || bpp == 0 ? 0.1 : bpp) *
            s.width! * s.height! * (s.fps ?? 30);
      case 'audio':
        return 128000;
      case 'subtitle':
        return 2000;
    }
    return null;
  }

  int? _estimateTranscode(StreamInfo s, String codecId, TranscodeSettings st,
      double? dur, EncoderInventory inv) {
    if (dur == null) return null;
    final c = CodecCatalog.byId(codecId) ??
        CodecCatalog.generic(codecId, s.type, codecId);
    double rate;
    if (c.kind == 'video') {
      if (s.width == null || s.height == null) return null;
      if (st.sizeCapMb != null) {
        // The cap decides the bitrate outright; the audio streams carry
        // their own estimate, so only the video share belongs here.
        final bps = st.cappedVideoBps;
        if (bps == null) return null;
        return (bps * dur / 8).round();
      }
      if (st.mode == RateMode.constantBitrate) {
        rate = parseBitrate(st.videoBitrate)?.toDouble() ?? 4e6;
      } else {
        // Filters change the pixel count, which changes the size.
        var width = s.width!.toDouble(), height = s.height!.toDouble();
        final (sw, sh) = st.filters.scaleSize;
        if (sw != null || sh != null) {
          final ratio = height / width;
          if (sw != null && sh != null) {
            width = sw.toDouble();
            height = sh.toDouble();
          } else if (sw != null) {
            width = sw.toDouble();
            height = width * ratio;
          } else {
            height = sh!.toDouble();
            width = height / ratio;
          }
        }
        var fps = s.fps ?? 30;
        final targetFps = double.tryParse(st.filters.fps);
        if (targetFps != null && targetFps > 0) fps = targetFps;

        final scale = qualityScale(codecId, st, inv);
        final quality = st.crf ?? scale.$3;
        // Each ~6 steps roughly halves or doubles the size.
        final factor = math.pow(2, (scale.$3 - quality) / 6.0).toDouble();

        // Constant quality spends bits according to how complex the
        // picture is, which a bits-per-pixel constant cannot know: the
        // same 1080p30 frame costs wildly different amounts for a
        // gradient and for confetti. Measured against real encodes, the
        // constant was ~5x too high on ordinary footage.
        //
        // The source's own bitrate already encodes that complexity, so
        // anchor to it and adjust for the things that genuinely change:
        // codec efficiency, pixel count, frame rate and quality.
        final sourceRate = s.bitRate?.toDouble();
        if (sourceRate != null && sourceRate > 0) {
          final srcInfo = CodecCatalog.byId(s.codec);
          final srcBpp =
              (srcInfo != null && srcInfo.bpp > 0) ? srcInfo.bpp : c.bpp;
          final efficiency = srcBpp > 0 ? c.bpp / srcBpp : 1.0;
          final srcPixels =
              s.width! * s.height! * (s.fps ?? 30);
          final newPixels = width * height * fps;
          final pixelRatio = srcPixels > 0 ? newPixels / srcPixels : 1.0;
          // Re-encoding lossy footage costs a little extra, because the
          // previous encoder's artefacts are themselves detail to carry.
          const generationLoss = 1.10;
          rate = sourceRate * efficiency * pixelRatio * factor *
              generationLoss;
        } else {
          // No reported bitrate (raw or odd containers): fall back to
          // the bits-per-pixel model.
          rate = c.bpp * width * height * fps * factor;
        }
        // Hardware encoders are a little less efficient at equal quality.
        if (st.hwAccel && inv.hwEncoderFor(codecId) != null) rate *= 1.15;
      }
    } else {
      if (c.lossless) {
        final raw = (s.channels ?? 2) * (s.sampleRate ?? 48000) * 16.0;
        rate = switch (c.id) {
          'flac' => raw * 0.60,
          'alac' => raw * 0.55,
          'wavpack' => raw * 0.60,
          'tta' => raw * 0.62,
          'truehd' => raw * 0.70,
          _ => raw,
        };
      } else {
        rate = (st.audioKbps ?? c.defaultKbps) * 1000.0;
      }
    }
    return (rate * dur / 8).round();
  }

  /// The quality value whose estimated size lands closest to the
  /// original file — the setting most people actually want when they
  /// are changing container or codec but not quality.
  int? qualityMatchingOriginalSize(
      ConvertPlan plan, ContainerSpec target, EncoderInventory inv) {
    final video = plan.actions.firstWhere(
        (a) => a.kind == StreamActionKind.transcode && a.stream.type == 'video',
        orElse: () => StreamAction(
            stream: StreamInfo(index: -1, type: 'none', codec: ''),
            kind: StreamActionKind.drop,
            reason: ''));
    if (video.stream.index < 0 || video.targetCodec == null) return null;
    final target0 = video.originalBytes;
    if (target0 == null || target0 <= 0) return null;

    final scale = qualityScale(video.targetCodec!, plan.settings, inv);
    if (!scale.$4) return null;
    final saved = plan.settings.crf;
    int? best;
    var bestDelta = double.infinity;
    for (var q = scale.$1; q <= scale.$2; q++) {
      plan.settings.crf = q;
      final est = _estimateTranscode(video.stream, video.targetCodec!,
          plan.settings, plan.input.durationSeconds, inv);
      if (est == null) continue;
      final delta = (est - target0).abs().toDouble();
      if (delta < bestDelta) {
        bestDelta = delta;
        best = q;
      }
    }
    plan.settings.crf = saved;
    return best;
  }

  static int? parseBitrate(String s) {
    final m = RegExp(r'^\s*([\d.]+)\s*([kKmM]?)').firstMatch(s);
    if (m == null) return null;
    final n = double.tryParse(m.group(1)!);
    if (n == null) return null;
    return switch (m.group(2)!.toLowerCase()) {
      'k' => (n * 1e3).round(),
      'm' => (n * 1e6).round(),
      _ => n.round(),
    };
  }

  /// Bits per second of audio that will actually end up in the output.
  ///
  /// A copied track keeps the source's own bitrate, so a size cap has to
  /// read the real streams rather than assume the target codec's
  /// default — otherwise the budget is wrong for exactly the common
  /// case of copying a 640 kbps AC-3 track.
  double audioBitsPerSecond(ConvertPlan plan) {
    final st = plan.settings;
    var bps = 0.0;
    for (final a in plan.actions) {
      if (a.stream.type != 'audio' || a.kind == StreamActionKind.drop) {
        continue;
      }
      if (a.kind == StreamActionKind.copy) {
        bps += (a.stream.bitRate ?? 128000).toDouble();
        continue;
      }
      final c = CodecCatalog.byId(a.targetCodec ?? '');
      if (c != null && c.lossless) {
        bps += (a.stream.channels ?? 2) *
            (a.stream.sampleRate ?? 48000) *
            16.0 *
            0.6;
      } else {
        bps += ((st.audioKbps ?? c?.defaultKbps ?? 128) * 1000).toDouble();
      }
    }
    return bps;
  }

  /// True when a size cap can actually be honoured: it works by setting
  /// the video bitrate, so there has to be a video stream being encoded.
  /// A copied stream keeps whatever size it already has.
  bool sizeCapApplies(ConvertPlan plan) =>
      transcodedVideoCodec(plan) != null;

  /// Video bitrate a size cap leaves once the real audio is paid for.
  int? videoBitrateForSizeCap(ConvertPlan plan) {
    final cap = plan.settings.sizeCapMb;
    final dur = plan.input.durationSeconds;
    if (cap == null || dur == null || dur <= 0) return null;
    if (!sizeCapApplies(plan)) return null;
    final totalBits = cap * 1000.0 * 1000.0 * 8;
    final audioBits = audioBitsPerSecond(plan) * dur;
    // Keep a 3% margin for container overhead.
    final videoBits = (totalBits - audioBits) * 0.97;
    if (videoBits <= 0) return null;
    return (videoBits / dur).round();
  }

  /// Video bitrate implied by a size cap, leaving room for audio.
  static int? bitrateForSizeCap(
      int capMb, double? durationSeconds, int audioKbps) {
    if (durationSeconds == null || durationSeconds <= 0) return null;
    final totalBits = capMb * 1000 * 1000 * 8;
    final audioBits = audioKbps * 1000 * durationSeconds;
    // Keep a 3% margin for container overhead.
    final videoBits = (totalBits - audioBits) * 0.97;
    if (videoBits <= 0) return null;
    return (videoBits / durationSeconds).round();
  }

  // ---- ffmpeg argument builder ----

  List<String> buildArgs(ConvertPlan plan, ContainerSpec target,
      String outputPath, EncoderInventory inv) {
    if (plan.keepsNothing) {
      // Without a single -map, FFmpeg picks streams by its own rules and
      // writes something nobody asked for.
      throw 'Nothing to convert: no stream survives into '
          '${target.label}';
    }
    final st = plan.settings;
    final args = <String>['-y', '-hide_banner'];

    final vaapiNeeded = st.hwAccel &&
        plan.actions.any((a) =>
            a.kind == StreamActionKind.transcode &&
            a.stream.type == 'video' &&
            (inv.hwEncoderFor(a.targetCodec!) ?? '').endsWith('_vaapi'));
    if (vaapiNeeded) {
      args.addAll([
        '-init_hw_device', 'vaapi=va:/dev/dri/renderD128',
        '-filter_hw_device', 'va',
      ]);
    }
    // Trimming before -i seeks fast; -to after it is exact.
    if ((plan.trimStart ?? '').isNotEmpty) {
      args.addAll(['-ss', plan.trimStart!]);
    }
    args.addAll(['-i', plan.input.path]);
    if ((plan.trimEnd ?? '').isNotEmpty) {
      args.addAll(['-to', plan.trimEnd!]);
    }

    // A size cap overrides the rate settings with a computed bitrate.
    String? cappedBitrate;
    if (st.sizeCapMb != null) {
      final bps = st.cappedVideoBps ?? videoBitrateForSizeCap(plan);
      if (bps != null && bps > 0) cappedBitrate = '${(bps / 1000).round()}k';
    }

    var outIndex = 0;
    final codecArgs = <String>[];
    for (final a in plan.actions) {
      if (a.kind == StreamActionKind.drop) continue;
      args.addAll(['-map', '0:${a.stream.index}']);
      final i = outIndex;
      if (a.kind == StreamActionKind.copy) {
        codecArgs.addAll(['-c:$i', 'copy']);
      } else if (a.stream.type == 'video') {
        codecArgs.addAll(_videoArgs(a.targetCodec!, i, st, inv, target,
            cappedBitrate, a.stream, plan));
        codecArgs.addAll(_userOptions(plan, a.stream.index, i));
      } else if (a.stream.type == 'audio') {
        codecArgs.addAll(_audioArgs(a.targetCodec!, i, st, a.stream,
            inv, plan));
        codecArgs.addAll(_userOptions(plan, a.stream.index, i));
      } else {
        codecArgs.addAll(['-c:$i', a.targetCodec ?? 'srt']);
      }
      outIndex++;
    }
    args.addAll(codecArgs);
    args.addAll(target.extraOutputArgs);
    for (final e in plan.muxerOptions.entries) {
      if (e.value.trim().isNotEmpty) args.addAll(['-${e.key}', e.value]);
    }
    args.addAll(['-progress', 'pipe:1', '-nostats']);
    args.add(outputPath);
    return args;
  }

  /// What a rigid format needs before it will accept a frame.
  ({List<String> filters, List<String> args}) _adaptationFor(
      String codecId, StreamInfo? source, ContainerSpec target) {
    switch (codecId) {
      case 'dvvideo':
        // DV is only defined at NTSC and PAL geometry; anything else is
        // rejected outright. Pick whichever matches the source rate.
        final ntsc = (source?.fps ?? 30) >= 27;
        return (
          filters: [
            ntsc ? 'scale=720:480' : 'scale=720:576',
            ntsc ? 'fps=30000/1001' : 'fps=25',
            ntsc ? 'format=yuv411p' : 'format=yuv420p',
          ],
          args: const <String>[],
        );
      case 'dnxhd':
        // Plain DNxHD only accepts a handful of broadcast profiles.
        // DNxHR takes any even frame size, so use it and round up.
        return (
          filters: ['scale=trunc(iw/2)*2:trunc(ih/2)*2', 'format=yuv422p'],
          args: const ['-profile:v', 'dnxhr_hq'],
        );
      case 'prores':
        return (filters: ['format=yuv422p10le'], args: const <String>[]);
      case 'rawvideo':
        // QuickTime stores uncompressed video packed, not planar: with
        // yuv420p FFmpeg still exits 0 but warns the file "will be
        // unreadable", and it is.
        final packed = target.id == 'mov' || target.id == 'mp4';
        return (
          filters: [packed ? 'format=uyvy422' : 'format=yuv420p'],
          args: const <String>[],
        );
      default:
        return (filters: const <String>[], args: const <String>[]);
    }
  }

  /// Filter chain for a transcoded video stream, VAAPI-aware.
  List<String> _filterChain(TranscodeSettings st, bool vaapi,
      {List<String> extra = const []}) {
    final chain = [...st.filters.chain(), ...extra];
    if (vaapi) {
      // Software filters run before the frame is uploaded to the GPU.
      return [...chain, 'format=nv12', 'hwupload'];
    }
    return chain;
  }

  List<String> _videoArgs(String codecId, int i, TranscodeSettings st,
      EncoderInventory inv, ContainerSpec target, String? cappedBitrate,
      StreamInfo? source, ConvertPlan plan) {
    final c = CodecCatalog.byId(codecId) ??
        CodecCatalog.generic(codecId, 'video', codecId);
    final hwEnc = st.hwAccel ? inv.hwEncoderFor(codecId) : null;
    final encoderName = encoderNameFor(codecId, st, inv) ?? c.encoder;
    final family = hwEnc == null ? null : hwFamilies[hwEnc.split('_').last];
    final scale = qualityScale(codecId, st, inv);
    final quality = st.crf ?? scale.$3;
    final useBitrate = cappedBitrate != null ||
        st.mode == RateMode.constantBitrate ||
        !scale.$4;
    final rate = cappedBitrate ?? st.videoBitrate;

    // Some formats only accept particular frame sizes, rates or pixel
    // layouts. Rather than refusing them, give them what they need.
    final adapt = _adaptationFor(codecId, source, target);
    final filters = [
      ..._filterChain(st, hwEnc != null && hwEnc.endsWith('_vaapi'),
          extra: adapt.filters),
    ];
    final out = <String>[
      if (filters.isNotEmpty) ...['-filter:$i', filters.join(',')],
      ...adapt.args,
    ];

    // Pick a pixel format from the ones this encoder actually lists, so
    // RGB or palettised sources (GIF, PNG) and unusual depths are
    // converted to something it will accept — and nothing is converted
    // when the source format is already fine.
    if (adapt.filters.isEmpty) {
      final caps = plan.encoderCaps[encoderName] as EncoderCaps?;
      final chosen = caps == null
          ? null
          : pickPixelFormat(caps.pixelFormats, source?.pixFmt);
      if (chosen != null) {
        out.addAll(['-pix_fmt:$i', chosen]);
      } else if (caps == null &&
          !c.lossless &&
          c.encoder != 'gif' &&
          (source?.pixFmt != null) &&
          !source!.pixFmt!.startsWith('yuv')) {
        // Capabilities not loaded (a bare unit test): keep the old guard.
        out.addAll(['-pix_fmt:$i', 'yuv420p']);
      }
    }

    if (hwEnc != null && family != null) {
      out.addAll(['-c:$i', hwEnc]);
      if (useBitrate) {
        out.addAll(['-b:$i', rate]);
        if (family.id == 'nvenc') out.addAll(['-maxrate:$i', rate]);
      } else {
        switch (family.id) {
          case 'nvenc':
            out.addAll(
                ['-preset', 'p5', '-rc:v', 'vbr', '-cq', '$quality', '-b:$i', '0']);
            break;
          case 'qsv':
            out.addAll(['-global_quality', '$quality']);
            break;
          case 'vaapi':
            out.addAll(['-qp', '$quality']);
            break;
          case 'amf':
            out.addAll(['-rc', 'cqp', '-qp_i', '$quality', '-qp_p', '$quality']);
            break;
          default:
            out.addAll(['-q:$i', '$quality']);
        }
      }
      return out;
    }

    // Software encoders.
    final encoder =
        CodecCatalog.availableEncoder(c, inv.encoders) ?? c.encoder;
    out.addAll(['-c:$i', encoder]);
    switch (encoder) {
      case 'libx264':
      case 'libx264rgb':
        out.addAll(['-preset', 'medium']);
        out.addAll(useBitrate
            ? ['-b:$i', rate, '-maxrate:$i', rate, '-bufsize:$i', _double(rate)]
            : ['-crf', '$quality']);
        break;
      case 'libx265':
        out.addAll(['-preset', 'medium']);
        if (target.id == 'mp4' || target.id == 'mov') {
          out.addAll(['-tag:$i', 'hvc1']); // Apple players need this
        }
        out.addAll(useBitrate ? ['-b:$i', rate] : ['-crf', '$quality']);
        break;
      case 'libsvtav1':
        out.addAll(['-preset', '8']);
        out.addAll(useBitrate ? ['-b:$i', rate] : ['-crf', '$quality']);
        break;
      case 'libaom-av1':
        out.addAll(['-cpu-used', '6']);
        out.addAll(useBitrate ? ['-b:$i', rate] : ['-crf', '$quality', '-b:$i', '0']);
        break;
      case 'libvpx-vp9':
        out.addAll(['-row-mt', '1']);
        out.addAll(
            useBitrate ? ['-b:$i', rate] : ['-crf', '$quality', '-b:$i', '0']);
        break;
      case 'libvpx':
        out.addAll(
            useBitrate ? ['-b:$i', rate] : ['-crf', '$quality', '-b:$i', '0']);
        break;
      case 'libxvid':
      case 'mpeg4':
      case 'mpeg2video':
      case 'mjpeg':
      case 'libtheora':
        out.addAll(useBitrate ? ['-b:$i', rate] : ['-q:$i', '$quality']);
        break;
      case 'prores_ks':
      case 'prores':
      case 'prores_aw':
        out.addAll(['-profile:$i', '3']);
        break;
      case 'dnxhd':
        break; // profile supplied by the adaptation above
      default:
        if (useBitrate && c.bpp > 0 && !c.lossless) out.addAll(['-b:$i', rate]);
    }
    return out;
  }

  /// Options the user set for one stream, in FFmpeg's own names.
  List<String> _userOptions(ConvertPlan plan, int srcIndex, int outIndex) {
    final opts = plan.streamOptions[srcIndex];
    if (opts == null || opts.isEmpty) return const [];
    return [
      for (final e in opts.entries)
        if (e.value.trim().isNotEmpty) ...['-${e.key}:$outIndex', e.value],
    ];
  }

  List<String> _audioArgs(String codecId, int i, TranscodeSettings st,
      StreamInfo source, EncoderInventory inv, ConvertPlan plan) {
    final c = CodecCatalog.byId(codecId) ??
        CodecCatalog.generic(codecId, 'audio', codecId);
    final channels = source.channels ?? 2;
    final overChannelLimit = c.maxChannels > 0 && channels > c.maxChannels;
    final encoderName = encoderNameFor(codecId, st, inv) ?? c.encoder;
    final caps = plan.encoderCaps[encoderName] as EncoderCaps?;
    // Encoders publish the sample rates they accept; move to the nearest
    // rather than letting FFmpeg refuse the job.
    final rate = caps == null
        ? null
        : pickSampleRate(caps.sampleRates, source.sampleRate);
    return [
      '-c:$i', c.encoder,
      // Stereo-only encoders (MP3, MP2, WMA) reject surround outright.
      if (overChannelLimit) ...['-ac:$i', '${c.maxChannels}'],
      // FFmpeg refuses its experimental encoders without this.
      if (c.experimental) ...['-strict', '-2'],
      if (rate != null) ...['-ar:$i', '$rate'],
      // libopus rejects layouts like 5.1(side) outright — and
      // -mapping_family does not help. Normalising the layout to one it
      // recognises does.
      if (c.encoder == 'libopus' && channels > 2) ...[
        '-filter:$i', 'aformat=channel_layouts=7.1|5.1|quad|stereo|mono',
        '-mapping_family:$i', '1',
      ],
      if (!c.lossless) ...['-b:$i', '${st.audioKbps ?? c.defaultKbps}k'],
    ];
  }

  static String _double(String rate) {
    final n = parseBitrate(rate);
    if (n == null) return rate;
    return n >= 1e6
        ? '${(n * 2 / 1e6).toStringAsFixed(0)}M'
        : '${(n * 2 / 1e3).round()}k';
  }
}
