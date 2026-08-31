/// Reads an FFmpeg failure and works out how to satisfy it.
///
/// Encoders and muxers refuse work for a small, well-known set of
/// reasons — a pixel format they cannot take, a channel layout they do
/// not recognise, a bitstream in the wrong form for the container, an
/// experimental encoder, an odd frame size. Each of those has a
/// mechanical fix, so instead of handing the user an FFmpeg error and
/// asking them to research it, Multi applies the fix and runs again.
library;

/// One thing to change about a failing command.
class Repair {
  /// Human-readable, shown in the job's status line.
  final String description;

  /// Arguments to insert before the output file.
  final List<String> extraArgs;

  /// Filters to append to a video stream's chain.
  final List<String> videoFilters;

  /// Filters to append to an audio stream's chain.
  final List<String> audioFilters;

  const Repair({
    required this.description,
    this.extraArgs = const [],
    this.videoFilters = const [],
    this.audioFilters = const [],
  });
}

class FfmpegRepair {
  /// Work out what would make a failed command succeed. Returns null
  /// when the failure is not something that can be repaired — a missing
  /// file, no disk space, a genuinely impossible request.
  static Repair? diagnose(String stderr) {
    final e = stderr.toLowerCase();

    // An encoder FFmpeg guards behind -strict.
    if (e.contains('experimental') &&
        (e.contains('strict') || e.contains('experimental feature'))) {
      return const Repair(
        description: 'enabling FFmpeg\'s experimental encoder',
        extraArgs: ['-strict', '-2'],
      );
    }

    // Channel layouts the encoder does not recognise (Opus and 5.1(side)
    // being the usual pair).
    if (e.contains('invalid channel layout') ||
        (e.contains('channel layout') && e.contains('not supported'))) {
      return const Repair(
        description: 'remapping the surround layout',
        audioFilters: ['aformat=channel_layouts=7.1|5.1|quad|stereo|mono'],
      );
    }

    // Sample rate the encoder will not take.
    if (e.contains('specified sample rate') ||
        e.contains('invalid sample rate') ||
        (e.contains('sample rate') && e.contains('not supported'))) {
      return const Repair(
        description: 'resampling to 48 kHz',
        extraArgs: ['-ar', '48000'],
      );
    }

    // Pixel format the encoder cannot take.
    if (e.contains('pixel format') &&
        (e.contains('not supported') ||
            e.contains('is not widely supported') ||
            e.contains('invalid pixel format'))) {
      return const Repair(
        description: 'converting to a standard pixel format',
        videoFilters: ['format=yuv420p'],
      );
    }

    // H.264/HEVC copied out of MP4 or MKV into a container that wants
    // Annex-B (MPEG-TS, AVI).
    if (e.contains('bitstream malformed') || e.contains('no startcode')) {
      return const Repair(
        description: 'converting the bitstream to Annex-B',
        extraArgs: ['-bsf:v', 'h264_mp4toannexb'],
      );
    }

    // Encoders that insist on even dimensions.
    if (e.contains('width not divisible by 2') ||
        e.contains('height not divisible by 2') ||
        e.contains('invalid frame size') ||
        e.contains('dimensions not supported')) {
      return const Repair(
        description: 'rounding the frame size to even numbers',
        videoFilters: ['scale=trunc(iw/2)*2:trunc(ih/2)*2'],
      );
    }

    // A muxer that will not take a global header codec.
    if (e.contains('global headers') || e.contains('extradata')) {
      return const Repair(
        description: 'adding global headers',
        extraArgs: ['-flags', '+global_header'],
      );
    }

    // Timestamp problems, common when remuxing odd sources.
    if (e.contains('non monotonically increasing dts') ||
        e.contains('non-monotonous dts') ||
        e.contains('invalid dts') ||
        e.contains('timestamps are unset')) {
      return const Repair(
        description: 'regenerating timestamps',
        extraArgs: ['-fflags', '+genpts', '-avoid_negative_ts', 'make_zero'],
      );
    }

    // Too many streams for the container, or one it cannot take.
    if (e.contains('could not find tag for codec') ||
        e.contains('track 0 codec frame') ||
        e.contains('is not supported in') ) {
      return const Repair(
        description: 're-encoding the stream the container cannot carry',
      );
    }
    return null;
  }

  /// Apply a repair to an existing argument list, keeping it valid:
  /// filters merge into any existing -filter for that stream rather
  /// than replacing it, and the output path stays last.
  static List<String> apply(List<String> args, Repair repair) {
    final out = List<String>.from(args);
    final outputPath = out.removeLast();

    for (final filter in repair.videoFilters) {
      _mergeFilter(out, filter, video: true);
    }
    for (final filter in repair.audioFilters) {
      _mergeFilter(out, filter, video: false);
    }
    if (repair.extraArgs.isNotEmpty) out.addAll(repair.extraArgs);
    out.add(outputPath);
    return out;
  }

  /// Merge a filter into every -filter:N already present, or add one.
  static void _mergeFilter(List<String> args, String filter,
      {required bool video}) {
    var merged = false;
    for (var i = 0; i < args.length - 1; i++) {
      if (!args[i].startsWith('-filter:')) continue;
      // Only touch chains that look like the right media type.
      final isAudioChain = args[i + 1].contains('aformat') ||
          args[i + 1].contains('volume') ||
          args[i + 1].contains('aresample');
      if (video == isAudioChain) continue;
      if (args[i + 1].contains(filter)) {
        merged = true;
        continue;
      }
      args[i + 1] = '${args[i + 1]},$filter';
      merged = true;
    }
    if (!merged) args.addAll([video ? '-vf' : '-af', filter]);
  }
}
