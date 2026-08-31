import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:path/path.dart' as p;

import '../models/convert.dart';
import 'codec_catalog.dart';
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
    video: {
      'mpeg4', 'h264', 'mjpeg', 'huffyuv', 'ffv1', 'utvideo', 'magicyuv',
      'rawvideo', 'dvvideo', 'mpeg2video', 'wmv2'
    },
    audio: {'mp3', 'ac3', 'pcm_s16le', 'aac', 'mp2', 'wmav2'},
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
    label: 'FLAC',
    extension: 'flac',
    audioOnly: true,
    audio: {'flac'},
    audioTarget: 'flac',
  ),
  ContainerSpec(
    id: 'wav',
    label: 'WAV',
    extension: 'wav',
    audioOnly: true,
    audio: {'pcm_s16le', 'pcm_s24le', 'pcm_f32le'},
    audioTarget: 'pcm_s16le',
  ),
  ContainerSpec(
    id: 'ac3',
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

  /// Hardware families proven to work here, best first.
  final List<String> hwFamilies;

  const EncoderInventory({
    this.encoders = const {},
    this.codecOf = const {},
    this.kindOf = const {},
    this.hwFamilies = const [],
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

  /// Best hardware encoder for a codec, or null.
  String? hwEncoderFor(String codecId) {
    for (final family in hwFamilies) {
      final name = '${codecId}_$family';
      if (encoders.contains(name)) return name;
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
  ConvertPlanner(this.tools);

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
    plan.actions = [
      for (final s in plan.input.streams)
        _action(s, plan.selection[s.index] ?? 'drop', target, plan.settings,
            dur, inventory),
    ];
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
        'audio' => '${target.label} holds no audio',
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
        // The cap decides the bitrate outright.
        return st.sizeCapMb! * 1000 * 1000;
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
        final factor =
            math.pow(2, (scale.$3 - quality) / 6.0).toDouble();
        rate = c.bpp * width * height * fps * factor;
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
    args.addAll(['-i', plan.input.path]);

    // A size cap overrides the rate settings with a computed bitrate.
    String? cappedBitrate;
    if (st.sizeCapMb != null) {
      final audioKbps = st.audioKbps ??
          CodecCatalog.byId(target.audioTarget)?.defaultKbps ??
          128;
      final bps = bitrateForSizeCap(
          st.sizeCapMb!, plan.input.durationSeconds, audioKbps);
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
        codecArgs.addAll(
            _videoArgs(a.targetCodec!, i, st, inv, target, cappedBitrate));
      } else if (a.stream.type == 'audio') {
        codecArgs.addAll(_audioArgs(a.targetCodec!, i, st));
      } else {
        codecArgs.addAll(['-c:$i', a.targetCodec ?? 'srt']);
      }
      outIndex++;
    }
    args.addAll(codecArgs);
    args.addAll(target.extraOutputArgs);
    args.addAll(['-progress', 'pipe:1', '-nostats']);
    args.add(outputPath);
    return args;
  }

  /// Filter chain for a transcoded video stream, VAAPI-aware.
  List<String> _filterChain(TranscodeSettings st, bool vaapi) {
    final chain = st.filters.chain();
    if (vaapi) {
      // Software filters run before the frame is uploaded to the GPU.
      return [...chain, 'format=nv12', 'hwupload'];
    }
    return chain;
  }

  List<String> _videoArgs(String codecId, int i, TranscodeSettings st,
      EncoderInventory inv, ContainerSpec target, String? cappedBitrate) {
    final c = CodecCatalog.byId(codecId) ??
        CodecCatalog.generic(codecId, 'video', codecId);
    final hwEnc = st.hwAccel ? inv.hwEncoderFor(codecId) : null;
    final family = hwEnc == null ? null : hwFamilies[hwEnc.split('_').last];
    final scale = qualityScale(codecId, st, inv);
    final quality = st.crf ?? scale.$3;
    final useBitrate = cappedBitrate != null ||
        st.mode == RateMode.constantBitrate ||
        !scale.$4;
    final rate = cappedBitrate ?? st.videoBitrate;

    final filters = _filterChain(st, hwEnc != null && hwEnc.endsWith('_vaapi'));
    final out = <String>[
      if (filters.isNotEmpty) ...['-filter:$i', filters.join(',')],
    ];

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
      default:
        if (useBitrate && c.bpp > 0 && !c.lossless) out.addAll(['-b:$i', rate]);
    }
    return out;
  }

  List<String> _audioArgs(String codecId, int i, TranscodeSettings st) {
    final c = CodecCatalog.byId(codecId) ??
        CodecCatalog.generic(codecId, 'audio', codecId);
    return [
      '-c:$i', c.encoder,
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
