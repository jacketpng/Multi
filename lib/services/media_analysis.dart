import 'dart:io';

import 'package:path/path.dart' as p;

import '../models/convert.dart';
import 'convert_planner.dart';

/// Things Multi has to measure rather than guess.
///
/// Black bars, loudness and what a subtitle track actually contains are
/// all properties of the file in front of you. Reading them from FFmpeg
/// is the only honest way to act on them, so that is what this does.
class MediaAnalysis {
  final String Function() ffmpegPath;
  MediaAnalysis(this.ffmpegPath);

  static final _cropLine = RegExp(r'crop=(\d+):(\d+):(-?\d+):(-?\d+)');
  static final _volumeLine = RegExp(r'max_volume:\s*(-?[\d.]+) dB');

  /// Detect the black borders around the picture.
  ///
  /// A single reading is not trustworthy: a film that opens on a fade
  /// from black reports the whole frame as border, and a 2.39:1 film
  /// with one bright full-height shot reports no border at all. So this
  /// samples across the whole runtime and keeps the *largest* picture
  /// any sample saw, stopping once several consecutive samples have
  /// stopped changing it.
  ///
  /// Returns null when nothing was found or the file has no video.
  Future<CropResult?> detectCrop(
    ProbeResult input, {
    void Function(String status)? onStatus,
    bool Function()? isCanceled,
    int limit = 24,
    int maxSamples = 24,
    int stableRuns = 3,
    double sampleSeconds = 2,
  }) async {
    StreamInfo? video;
    for (final s in input.streams) {
      if (s.type == 'video' && !s.attachedPic) {
        video = s;
        break;
      }
    }
    if (video == null || video.width == null || video.height == null) {
      return null;
    }
    final ffmpeg = ffmpegPath();
    final duration = input.durationSeconds ?? 0;

    // Where to look. Short clips are scanned end to end; longer ones
    // get evenly spread samples, skipping the very start and end where
    // fades and logos live.
    final points = <double>[];
    if (duration <= 0 || duration <= sampleSeconds * 3) {
      points.add(0);
    } else {
      final first = duration * 0.03;
      final last = duration * 0.97 - sampleSeconds;
      final span = (last - first).clamp(0.0, double.infinity);
      final n = maxSamples.clamp(1, 64);
      for (var i = 0; i < n; i++) {
        points.add(first + (n == 1 ? 0 : span * i / (n - 1)));
      }
    }

    int? left, top, right, bottom;
    var stable = 0;
    var used = 0;
    for (final at in points) {
      if (isCanceled?.call() ?? false) break;
      used++;
      onStatus?.call(
          'Looking for black bars — sample $used of ${points.length}');
      final args = <String>[
        '-hide_banner',
        if (at > 0) ...['-ss', at.toStringAsFixed(2)],
        '-i', input.path,
        if (duration > 0) ...['-t', sampleSeconds.toStringAsFixed(2)],
        '-map', '0:${video.index}',
        '-vf', 'cropdetect=limit=$limit:round=2:reset=0',
        '-f', 'null', '-',
      ];
      String err;
      try {
        final r = await Process.run(ffmpeg, args)
            .timeout(const Duration(seconds: 90));
        err = r.stderr as String;
      } catch (_) {
        continue;
      }
      final matches = _cropLine.allMatches(err).toList();
      if (matches.isEmpty) continue;
      final m = matches.last;
      final w = int.parse(m.group(1)!);
      final h = int.parse(m.group(2)!);
      final x = int.parse(m.group(3)!);
      final y = int.parse(m.group(4)!);
      // cropdetect reports -1 for "no idea" on an entirely black window.
      if (w <= 0 || h <= 0 || x < 0 || y < 0) continue;

      final before = [left, top, right, bottom];
      left = left == null ? x : (x < left ? x : left);
      top = top == null ? y : (y < top ? y : top);
      right = right == null ? x + w : (x + w > right ? x + w : right);
      bottom = bottom == null ? y + h : (y + h > bottom ? y + h : bottom);
      final grew = before[0] != left ||
          before[1] != top ||
          before[2] != right ||
          before[3] != bottom;
      stable = grew ? 0 : stable + 1;

      // Once the picture has stopped growing for a few samples in a
      // row, more looking will not change the answer.
      if (used >= 4 && stable >= stableRuns) break;
      // Nothing left to find: the whole frame is already picture.
      if (left == 0 &&
          top == 0 &&
          right == video.width &&
          bottom == video.height) {
        break;
      }
    }
    if (left == null || top == null || right == null || bottom == null) {
      return null;
    }
    // Encoders want even dimensions; round outwards so nothing is lost.
    var x = left - (left.isOdd ? 1 : 0);
    var y = top - (top.isOdd ? 1 : 0);
    if (x < 0) x = 0;
    if (y < 0) y = 0;
    var w = right - x;
    var h = bottom - y;
    if (w.isOdd) w += 1;
    if (h.isOdd) h += 1;
    if (x + w > video.width!) w = video.width! - x;
    if (y + h > video.height!) h = video.height! - y;

    return CropResult(
      width: w,
      height: h,
      x: x,
      y: y,
      sourceWidth: video.width!,
      sourceHeight: video.height!,
      samples: used,
    );
  }

  /// The loudest sample in the first audio track, in dBFS.
  ///
  /// Negative means there is headroom: -6 dB means the track can be
  /// turned up by 6 dB before anything clips.
  Future<double?> measurePeak(ProbeResult input,
      {void Function(String status)? onStatus}) async {
    final hasAudio = input.streams.any((s) => s.type == 'audio');
    if (!hasAudio) return null;
    onStatus?.call('Measuring how loud the audio actually is…');
    try {
      final r = await Process.run(ffmpegPath(), [
        '-hide_banner',
        '-i', input.path,
        '-map', '0:a:0',
        '-af', 'volumedetect',
        '-f', 'null', '-',
      ]).timeout(const Duration(minutes: 10));
      final m = _volumeLine.firstMatch(r.stderr as String);
      if (m == null) return null;
      return double.tryParse(m.group(1)!);
    } catch (_) {
      return null;
    }
  }

  /// Write each text subtitle track out as its own file next to the
  /// output, named with its language when it has one.
  ///
  /// Image-based tracks are skipped: they are pictures, and there is no
  /// text in them to write.
  Future<List<String>> extractSubtitles(
    ProbeResult input,
    String format, {
    String? outputDir,
    List<int>? onlyStreams,
    void Function(String status)? onStatus,
  }) async {
    final dir = outputDir ?? p.dirname(input.path);
    final base = p.basenameWithoutExtension(input.path);
    final ext = switch (format) {
      'ass' => 'ass',
      'webvtt' => 'vtt',
      _ => 'srt',
    };
    final encoder = switch (format) {
      'ass' => 'ass',
      'webvtt' => 'webvtt',
      _ => 'srt',
    };
    final written = <String>[];
    final subs = input.streams.where((s) =>
        s.type == 'subtitle' &&
        !ConvertPlanner.isImageSubtitle(s.codec) &&
        (onlyStreams == null || onlyStreams.contains(s.index)));
    for (final s in subs) {
      final tag = s.language == null || s.language!.isEmpty
          ? '${s.index}'
          : s.language!;
      var out = p.join(dir, '$base.$tag.$ext');
      var n = 2;
      while (File(out).existsSync()) {
        out = p.join(dir, '$base.$tag.$n.$ext');
        n++;
      }
      onStatus?.call('Writing ${p.basename(out)}…');
      try {
        final r = await Process.run(ffmpegPath(), [
          '-y', '-hide_banner',
          '-i', input.path,
          '-map', '0:${s.index}',
          '-c:s', encoder,
          out,
        ]).timeout(const Duration(minutes: 10));
        if (r.exitCode == 0 &&
            File(out).existsSync() &&
            File(out).lengthSync() > 0) {
          written.add(out);
        } else {
          try {
            File(out).deleteSync();
          } catch (_) {}
        }
      } catch (_) {}
    }
    return written;
  }
}

/// What cropdetect found, and how sure it is.
class CropResult {
  final int width, height, x, y;
  final int sourceWidth, sourceHeight;

  /// How many places in the file were looked at to reach this.
  final int samples;

  const CropResult({
    required this.width,
    required this.height,
    required this.x,
    required this.y,
    required this.sourceWidth,
    required this.sourceHeight,
    required this.samples,
  });

  bool get isFullFrame => width >= sourceWidth && height >= sourceHeight;

  /// The crop filter's own argument form.
  String get filterValue => '$width:$height:$x:$y';

  int get barsTop => y;
  int get barsBottom => sourceHeight - height - y;
  int get barsLeft => x;
  int get barsRight => sourceWidth - width - x;

  String get summary {
    if (isFullFrame) {
      return 'No black bars — the picture already fills the frame '
          '(checked $samples places in the file).';
    }
    final parts = <String>[
      if (barsTop + barsBottom > 0) '${barsTop + barsBottom} px top and bottom',
      if (barsLeft + barsRight > 0) '${barsLeft + barsRight} px left and right',
    ];
    return '$sourceWidth×$sourceHeight → $width×$height, removing '
        '${parts.join(' and ')} (checked $samples places in the file).';
  }
}
