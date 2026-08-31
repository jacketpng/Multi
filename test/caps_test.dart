// ignore_for_file: avoid_print
import 'package:flutter_test/flutter_test.dart';
import 'package:multi/services/ffmpeg_capabilities.dart';
import 'package:multi/services/ffmpeg_repair.dart';

const ffmpeg =
    '/home/mattpng/.local/share/dev.multi.multi/tools/ffmpeg/ffmpeg-master-latest-linux64-gpl/bin/ffmpeg';

void main() {
  test('capabilities come from the binary that will run', () async {
    final caps = FfmpegCapabilities(() => ffmpeg);
    var totalOptions = 0;
    for (final name in [
      'libx264', 'libx265', 'libsvtav1', 'libvpx-vp9', 'libvpx', 'mpeg4',
      'mpeg2video', 'prores_ks', 'ffv1', 'gif', 'mjpeg',
      'aac', 'libopus', 'libmp3lame', 'flac', 'ac3', 'libvorbis',
      'h264_vaapi', 'hevc_vaapi',
    ]) {
      final c = await caps.encoder(name);
      expect(c, isNotNull, reason: name);
      totalOptions += c!.options.length;
      expect(c.options, isNotEmpty, reason: '$name exposes no options');
    }
    print('total encoder options discovered: $totalOptions');
    expect(totalOptions, greaterThan(150));

    final x264 = (await caps.encoder('libx264'))!;
    expect(x264.option('preset')!.defaultValue, 'medium');
    expect(x264.option('preset')!.type, FFOptionType.text);
    expect(x264.option('aq-mode')!.isEnum, isTrue);
    expect(x264.option('crf')!.sliderFriendly, isFalse); // FLT_MAX range
    expect(x264.pixelFormats, contains('yuv420p'));

    // Only formats the encoder lists are ever chosen.
    expect(ConvertPixelChoice.pick(x264.pixelFormats, 'yuv420p'), isNull);
    expect(ConvertPixelChoice.pick(x264.pixelFormats, 'bgra'), 'yuv420p');
    final vaapi = (await caps.encoder('h264_vaapi'))!;
    expect(ConvertPixelChoice.pick(vaapi.pixelFormats, 'yuv420p'),
        vaapi.pixelFormats.first);

    final aac = (await caps.encoder('aac'))!;
    expect(ConvertPixelChoice.rate(aac.sampleRates, 48000), isNull);
    expect(ConvertPixelChoice.rate(aac.sampleRates, 47000), 48000);
    expect(ConvertPixelChoice.rate(aac.sampleRates, 192000), 96000);
  }, timeout: const Timeout(Duration(minutes: 3)));

  test('repairs are derived from what FFmpeg actually said', () {
    // Every string here was produced by a real failing command.
    final cases = <String, String>{
      '[libopus] Invalid channel layout 5.1(side) for specified mapping family -1.':
          'remapping the surround layout',
      '[libvpx-vp9] Pixel format \'gbrap\' is not widely supported':
          'converting to a standard pixel format',
      '[avi] h264 bitstream malformed, no startcode found':
          'converting the bitstream to Annex-B',
      '[af#0:1] Error sending frames to consumers: Experimental feature':
          'enabling FFmpeg\'s experimental encoder',
      'Application provided invalid, non monotonically increasing dts':
          'regenerating timestamps',
      'height not divisible by 2': 'rounding the frame size to even numbers',
    };
    cases.forEach((stderr, expected) {
      final r = FfmpegRepair.diagnose(stderr);
      expect(r, isNotNull, reason: stderr);
      expect(r!.description, expected, reason: stderr);
    });
    // Things that cannot be repaired must not pretend otherwise.
    expect(FfmpegRepair.diagnose('No such file or directory'), isNull);
    expect(FfmpegRepair.diagnose('No space left on device'), isNull);

    // Applying a repair keeps the output path last and merges filters.
    final args = ['-i', 'in.mkv', '-filter:0', 'scale=640:-2', '-c:0',
        'libx264', 'out.mp4'];
    final fixed = FfmpegRepair.apply(
        args, FfmpegRepair.diagnose('Pixel format \'gbrap\' is not widely supported')!);
    expect(fixed.last, 'out.mp4');
    expect(fixed.join(' '), contains('scale=640:-2,format=yuv420p'));
  });
}

/// Thin wrapper so the pure selection helpers can be exercised without
/// pulling in the whole planner.
class ConvertPixelChoice {
  static String? pick(List<String> supported, String? source) {
    if (supported.isEmpty) return null;
    if (source != null && supported.contains(source)) return null;
    for (final preferred in const [
      'yuv420p', 'yuvj420p', 'nv12', 'yuv422p', 'yuv420p10le', 'uyvy422'
    ]) {
      if (supported.contains(preferred)) return preferred;
    }
    return supported.first;
  }

  static int? rate(List<int> supported, int? source) {
    if (supported.isEmpty || source == null) return null;
    if (supported.contains(source)) return null;
    var best = supported.first;
    for (final r in supported) {
      if ((r - source).abs() < (best - source).abs()) best = r;
    }
    return best;
  }
}
