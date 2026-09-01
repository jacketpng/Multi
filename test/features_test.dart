// A stress harness reports by printing; that is its whole job.
// ignore_for_file: avoid_print
@Tags(['stress'])
library;

import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:multi/models/convert.dart';
import 'package:multi/models/tool.dart';
import 'package:multi/services/convert_manager.dart';
import 'package:multi/services/convert_planner.dart';
import 'package:multi/services/media_analysis.dart';
import 'package:multi/services/download_manager.dart';
import 'package:multi/services/tool_manager.dart';
import 'package:path/path.dart' as p;

/// End-to-end checks for the features added on top of the converter:
/// subtitles, audio shaping and loudness, language filtering, black-bar
/// detection, two-pass, metadata, stream order and GIF.
///
/// Everything here runs the real FFmpeg and reads the real result back.
/// A claim that is not measured is not made.
/// Scratch space for the files these tests generate. Outside the
/// repository, and rebuilt from scratch on every run.
final work = Platform.environment['MULTI_TEST_WORK'] ??
    p.join(Directory.systemTemp.path, 'multi-feature-test');

late ToolManager tools;
late ConvertPlanner planner;
late MediaAnalysis analysis;
late EncoderInventory inventory;
late String ffmpeg;
late Directory outDir;

final failures = <String>[];
var checks = 0;

void check(bool ok, String label, [String detail = '']) {
  checks++;
  if (!ok) failures.add('$label${detail.isEmpty ? '' : ' — $detail'}');
  print('  ${ok ? 'ok  ' : 'FAIL'} $label${detail.isEmpty ? '' : '  ($detail)'}');
}

ContainerSpec spec(String id) => containerSpecs.firstWhere((c) => c.id == id);

Future<ProcessResult> ff(List<String> args, {int seconds = 180}) =>
    Process.run(ffmpeg, ['-hide_banner', ...args])
        .timeout(Duration(seconds: seconds));

Future<ProbeResult?> probeOrNull(String path) async {
  try {
    return await planner.probe(path);
  } catch (_) {
    return null;
  }
}

/// Build the plan's command, run it, and probe what came out.
Future<({bool ok, String error, ProbeResult? probe, int size, String path,
        List<String> args})>
    run(ConvertPlan plan, ContainerSpec target, String label,
        {int pass = 0}) async {
  final out = p.join(outDir.path,
      '${label.replaceAll(RegExp(r'[^A-Za-z0-9_.-]'), '_')}.${target.extension}');
  final args = planner.buildArgs(plan, target, out, inventory, pass: pass);
  final r = await ff(args, seconds: 300);
  if (r.exitCode != 0) {
    return (
      ok: false,
      error: (r.stderr as String)
          .trim()
          .split('\n')
          .where((l) => l.contains('rror') || l.contains('Invalid'))
          .join(' | '),
      probe: null,
      size: 0,
      path: out,
      args: args,
    );
  }
  final probed = await probeOrNull(out);
  return (
    ok: probed != null && File(out).existsSync() && File(out).lengthSync() > 0,
    error: '',
    probe: probed,
    size: File(out).existsSync() ? File(out).lengthSync() : 0,
    path: out,
    args: args,
  );
}

/// ffprobe JSON for one field, via the planner's own probe where it can,
/// and a direct call where the model does not carry it.
Future<String> ffprobeField(String path, List<String> entries) async {
  final r = await Process.run(tools.ffprobePath!, [
    '-v', 'quiet', '-of', 'default=nw=1:nk=1',
    '-show_entries', entries.join(''),
    path,
  ]);
  return (r.stdout as String).trim();
}

String srt(String text) => '''
1
00:00:00,500 --> 00:00:07,500
$text

''';

void main() {
  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    const channel = MethodChannel('plugins.flutter.io/path_provider');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel,
            (call) async => '/home/mattpng/.local/share/dev.multi.multi');
    tools = ToolManager();
    await tools.init(checkForUpdates: false);
    planner = ConvertPlanner(tools);
    ffmpeg = tools.pathFor(ToolId.ffmpeg)!;
    analysis = MediaAnalysis(() => ffmpeg);
    outDir = Directory('$work/out')..createSync(recursive: true);

    final r = await ff(['-encoders']);
    final parsed = EncoderInventory.parse(r.stdout as String);
    final hw = <String>[];
    if (File('/dev/dri/renderD128').existsSync()) hw.add('vaapi');
    final proven = <String>{};
    for (final family in hw) {
      for (final codec in const ['h264', 'hevc', 'av1', 'vp9']) {
        final enc = '${codec}_$family';
        if (!parsed.encoders.contains(enc)) continue;
        final t = await ff([
          '-v', 'error',
          '-init_hw_device', 'vaapi=va:/dev/dri/renderD128',
          '-filter_hw_device', 'va',
          '-f', 'lavfi', '-i', 'testsrc2=d=0.2:s=192x108:r=10',
          '-vf', 'format=nv12,hwupload',
          '-c:v', enc, '-f', 'null', '-',
        ]);
        if (t.exitCode == 0) proven.add(enc);
      }
    }
    inventory = EncoderInventory(
        encoders: parsed.encoders,
        codecOf: parsed.codecOf,
        kindOf: parsed.kindOf,
        hwFamilies: hw,
        provenHwEncoders: proven);

    await buildSources();
  });

  test('every new feature, against real files', () async {
    await testBlackBars();
    await testAudioShape();
    await testLoudness();
    await testVbr();
    await testSubtitleFormats();
    await testBurnIn();
    await testSubtitleExtraction();
    await testLanguageFilter();
    await testMetadataAndOrder();
    await testTwoPass();
    await testGif();
    await testLiveProgress();
    testUrlSplitting();

    print('\n===== FEATURE SUMMARY =====');
    print('checks run: $checks');
    print('failures:   ${failures.length}');
    for (final f in failures) {
      print('  ✗ $f');
    }
    expect(failures, isEmpty);
  }, timeout: const Timeout(Duration(minutes: 45)));
}

String src(String name) => p.join(work, name);

Future<void> buildSources() async {
  Directory(work).createSync(recursive: true);
  File(src('eng.srt')).writeAsStringSync(srt('ENGLISH SUBTITLE'));
  File(src('jpn.srt')).writeAsStringSync(srt('JAPANESE SUBTITLE'));
  File(src('spa.srt')).writeAsStringSync(srt('SPANISH SUBTITLE'));
  File(src('fra.srt')).writeAsStringSync(srt('FRENCH SUBTITLE'));

  // A 640x360 picture inside a 640x480 frame: 60 px of black top and
  // bottom, which is exactly what the detector should report.
  await ff([
    '-y', '-f', 'lavfi', '-i', 'testsrc2=d=8:s=640x360:r=25',
    '-vf', 'pad=640:480:0:60',
    '-c:v', 'libx264', '-preset', 'veryfast', '-pix_fmt', 'yuv420p',
    src('letterbox.mp4'),
  ]);
  // No bars at all — the detector has to say so rather than inventing a crop.
  await ff([
    '-y', '-f', 'lavfi', '-i', 'testsrc2=d=6:s=320x240:r=25',
    '-c:v', 'libx264', '-preset', 'veryfast', '-pix_fmt', 'yuv420p',
    src('full.mp4'),
  ]);
  // Deliberately quiet audio, so normalisation has something to do.
  await ff([
    '-y', '-f', 'lavfi', '-i', 'testsrc2=d=8:s=320x240:r=25',
    '-f', 'lavfi', '-i', 'sine=f=440:d=8',
    '-af', 'volume=-20dB',
    '-c:v', 'libx264', '-preset', 'veryfast', '-pix_fmt', 'yuv420p',
    '-c:a', 'aac', src('quiet.mp4'),
  ]);
  // 5.1, for the channel controls.
  await ff([
    '-y', '-f', 'lavfi', '-i', 'testsrc2=d=6:s=320x240:r=25',
    '-f', 'lavfi', '-i', 'sine=f=440:d=6',
    '-c:v', 'libx264', '-preset', 'veryfast', '-pix_fmt', 'yuv420p',
    '-af', 'pan=5.1|c0=c0|c1=c0|c2=c0|c3=c0|c4=c0|c5=c0',
    '-c:a', 'ac3', src('surround.mkv'),
  ]);
  // Three languages of audio, four of subtitles.
  await ff([
    '-y',
    '-f', 'lavfi', '-i', 'testsrc2=d=8:s=320x240:r=25',
    '-f', 'lavfi', '-i', 'sine=f=440:d=8',
    '-f', 'lavfi', '-i', 'sine=f=660:d=8',
    '-f', 'lavfi', '-i', 'sine=f=880:d=8',
    '-i', src('eng.srt'), '-i', src('jpn.srt'),
    '-i', src('spa.srt'), '-i', src('fra.srt'),
    '-map', '0:v', '-map', '1:a', '-map', '2:a', '-map', '3:a',
    '-map', '4', '-map', '5', '-map', '6', '-map', '7',
    '-c:v', 'libx264', '-preset', 'veryfast', '-pix_fmt', 'yuv420p',
    '-c:a', 'aac', '-c:s', 'srt',
    '-metadata:s:a:0', 'language=eng',
    '-metadata:s:a:1', 'language=jpn',
    '-metadata:s:a:2', 'language=spa',
    '-metadata:s:s:0', 'language=eng',
    '-metadata:s:s:1', 'language=jpn',
    '-metadata:s:s:2', 'language=spa',
    '-metadata:s:s:3', 'language=fra',
    src('multilang.mkv'),
  ]);
  // Audio that is actually hard to compress, so a quality setting has
  // something to bite on. A pure sine encodes identically at every
  // setting and would prove nothing.
  await ff([
    '-y', '-f', 'lavfi', '-i', 'testsrc2=d=8:s=160x120:r=25',
    '-f', 'lavfi', '-i', 'anoisesrc=d=8:c=pink:a=0.4',
    '-c:v', 'libx264', '-preset', 'veryfast', '-pix_fmt', 'yuv420p',
    '-c:a', 'aac', '-b:a', '192k', src('rich.mp4'),
  ]);
  print('sources built in $work');

}

// ---------------------------------------------------------------- crop

Future<void> testBlackBars() async {
  print('\n--- BLACK BARS (cropdetect) ---');
  final probe = await planner.probe(src('letterbox.mp4'));
  final crop = await analysis.detectCrop(probe);
  check(crop != null, 'letterboxed file reports a crop');
  if (crop == null) return;
  print('    ${crop.summary}');
  check(!crop.isFullFrame, 'bars are found', crop.filterValue);
  check((crop.width - 640).abs() <= 2 && (crop.height - 360).abs() <= 4,
      'crop size matches the picture', '${crop.width}x${crop.height}');
  check(crop.x == 0 && (crop.y - 60).abs() <= 2, 'crop offset matches',
      '${crop.x},${crop.y}');
  check(crop.samples >= 4, 'more than one place was looked at',
      '${crop.samples} samples');

  // A file with no bars must not be cropped at all.
  final fullProbe = await planner.probe(src('full.mp4'));
  final none = await analysis.detectCrop(fullProbe);
  check(none != null && none.isFullFrame, 'a full frame reports no bars',
      none?.filterValue ?? 'null');

  // And the crop actually reaches the output.
  final target = spec('mp4');
  final plan = planner.plan(probe, target, inventory: inventory);
  plan.selection[probe.streams.first.index] = 'h264';
  plan.settings.filters.crop = crop.filterValue;
  plan.settings.hwAccelUserSet = true;
  plan.settings.hwAccel = false;
  planner.recompute(plan, target, inventory);
  final r = await run(plan, target, 'cropped');
  check(r.ok, 'cropped conversion runs', r.error);
  final v = r.probe?.streams.firstWhere((s) => s.type == 'video');
  check(v?.height == crop.height && v?.width == crop.width,
      'output has the bars removed', '${v?.width}x${v?.height}');
}

// --------------------------------------------------------------- audio

Future<void> testAudioShape() async {
  print('\n--- AUDIO: RATE AND CHANNELS ---');
  final probe = await planner.probe(src('surround.mkv'));
  final target = spec('m4a');

  final plan = planner.plan(probe, target, inventory: inventory);
  await planner.loadCapabilities(plan, target, inventory);
  plan.settings.audioSampleRate = 22050;
  plan.settings.audioChannels = 2;
  planner.recompute(plan, target, inventory);
  final r = await run(plan, target, 'rate_channels');
  check(r.ok, 'rate + channel override runs', r.error);
  final a = r.probe?.streams.firstWhere((s) => s.type == 'audio');
  check(a?.sampleRate == 22050, 'sample rate is what was asked for',
      '${a?.sampleRate}');
  check(a?.channels == 2, 'channel count is what was asked for',
      '${a?.channels}');

  // Left alone, nothing is resampled and the channels survive.
  final keep = planner.plan(probe, target, inventory: inventory);
  await planner.loadCapabilities(keep, target, inventory);
  planner.recompute(keep, target, inventory);
  final r2 = await run(keep, target, 'rate_channels_keep');
  final a2 = r2.probe?.streams.firstWhere((s) => s.type == 'audio');
  check(r2.ok, 'default audio conversion runs', r2.error);
  check(a2?.channels == 6, 'surround survives by default', '${a2?.channels}');

  // A stereo-only encoder still gets a downmix rather than an error.
  final mp3 = spec('mp3');
  final toMp3 = planner.plan(probe, mp3, inventory: inventory);
  await planner.loadCapabilities(toMp3, mp3, inventory);
  planner.recompute(toMp3, mp3, inventory);
  final r3 = await run(toMp3, mp3, 'surround_to_mp3');
  check(r3.ok, '5.1 into MP3 runs', r3.error);
  final a3 = r3.probe?.streams.firstWhere((s) => s.type == 'audio');
  check(a3?.channels == 2, '5.1 is downmixed for MP3', '${a3?.channels}');
}

Future<double?> integratedLoudness(String path) async {
  final r = await ff([
    '-i', path, '-map', '0:a:0',
    '-af', 'loudnorm=print_format=json', '-f', 'null', '-',
  ]);
  final m = RegExp(r'"input_i"\s*:\s*"(-?[\d.]+)"')
      .firstMatch(r.stderr as String);
  return m == null ? null : double.tryParse(m.group(1)!);
}

Future<double?> maxVolume(String path) async {
  final r = await ff([
    '-i', path, '-map', '0:a:0', '-af', 'volumedetect', '-f', 'null', '-',
  ]);
  final m = RegExp(r'max_volume:\s*(-?[\d.]+) dB')
      .firstMatch(r.stderr as String);
  return m == null ? null : double.tryParse(m.group(1)!);
}

/// Audio-only conversions of a file whose audio the target could copy
/// need the copy overridden, or none of these settings can reach it.
ConvertPlan reencodedAudioPlan(ProbeResult probe, ContainerSpec target) {
  final plan = planner.plan(probe, target, inventory: inventory);
  for (final s in probe.streams) {
    if (s.type == 'audio' && plan.selection[s.index] == 'copy') {
      plan.selection[s.index] = target.audioTarget;
    }
  }
  return plan;
}

Future<void> testLoudness() async {
  print('\n--- AUDIO: LOUDNESS ---');
  final probe = await planner.probe(src('quiet.mp4'));
  final target = spec('m4a');

  final before = await integratedLoudness(src('quiet.mp4'));
  final peakBefore = await analysis.measurePeak(probe);
  final peakIndependent = await maxVolume(src('quiet.mp4'));
  print('    source: ${before?.toStringAsFixed(1)} LUFS, '
      'peak ${peakBefore?.toStringAsFixed(1)} dBFS');
  check(
      peakBefore != null &&
          peakIndependent != null &&
          (peakBefore - peakIndependent).abs() < 0.05,
      'the peak Multi measures is the peak FFmpeg reports',
      '${peakBefore?.toStringAsFixed(1)} vs '
          '${peakIndependent?.toStringAsFixed(1)}');

  // Copying the audio means none of this can apply, and Multi has to
  // not pretend otherwise.
  final copyPlan = planner.plan(probe, target, inventory: inventory);
  copyPlan.settings.normalize = AudioNormalize.loudnorm;
  planner.recompute(copyPlan, target, inventory);
  final copied = await run(copyPlan, target, 'copied_audio');

  check(
      copyPlan.actions.any((a) =>
          a.stream.type == 'audio' && a.kind == StreamActionKind.copy),
      'AAC into M4A is a copy by default');
  check(!copied.args.any((a) => a.contains('loudnorm')),
      'no loudness filter is emitted for a copied track');

  // EBU R128 to -16 LUFS.
  final plan = reencodedAudioPlan(probe, target);
  await planner.loadCapabilities(plan, target, inventory);
  plan.settings.normalize = AudioNormalize.loudnorm;
  plan.settings.loudnessTarget = -16;
  planner.recompute(plan, target, inventory);

  final r = await run(plan, target, 'loudnorm');
  check(r.ok, 'loudnorm conversion runs', r.error);
  check(r.args.any((a) => a.contains('loudnorm=I=-16')),
      'the loudnorm filter is in the command');
  check(r.args.any((a) => a.contains('aresample=')),
      'the rate loudnorm forces is put back');
  final after = await integratedLoudness(r.path);
  print('    loudnorm result: ${after?.toStringAsFixed(1)} LUFS');
  check(after != null && (after + 16).abs() < 1.5,
      'output really is near -16 LUFS', '${after?.toStringAsFixed(1)}');

  // Peak normalisation, using the measurement.
  final peakPlan = reencodedAudioPlan(probe, target);

  await planner.loadCapabilities(peakPlan, target, inventory);
  peakPlan.settings.normalize = AudioNormalize.peak;
  peakPlan.settings.measuredPeakDb = peakBefore;
  planner.recompute(peakPlan, target, inventory);
  final r2 = await run(peakPlan, target, 'peaknorm');
  check(r2.ok, 'peak normalisation runs', r2.error);
  final peakAfter = await maxVolume(r2.path);
  print('    peak result: ${peakAfter?.toStringAsFixed(1)} dBFS');
  check(peakAfter != null && peakAfter.abs() < 1.5,
      'output peaks just below full scale',
      '${peakAfter?.toStringAsFixed(1)} dBFS');

  // Nothing selected means nothing is touched.
  final plain = reencodedAudioPlan(probe, target);

  await planner.loadCapabilities(plain, target, inventory);
  planner.recompute(plain, target, inventory);
  final r3 = await run(plain, target, 'noloudness');
  check(!r3.args.any((a) => a.contains('loudnorm') || a.contains('volume=')),
      'no loudness filter appears when none was asked for');

  // A plain gain moves the level by exactly that much.
  final gain = reencodedAudioPlan(probe, target);

  await planner.loadCapabilities(gain, target, inventory);
  gain.settings.gainDb = 6;
  planner.recompute(gain, target, inventory);
  final r4 = await run(gain, target, 'gain6');
  final gained = await maxVolume(r4.path);
  final base = await maxVolume(r3.path);
  check(r4.ok, '+6 dB gain runs', r4.error);
  check(gained != null && base != null && (gained - base - 6).abs() < 1.0,
      '+6 dB really is 6 dB louder',
      '${base?.toStringAsFixed(1)} -> ${gained?.toStringAsFixed(1)}');
}

Future<void> testVbr() async {
  print('\n--- AUDIO: VBR ---');
  final probe = await planner.probe(src('rich.mp4'));
  final target = spec('mp3');

  if (!inventory.encoders.contains('libmp3lame')) {
    print('    libmp3lame not in this build — skipped');
    return;
  }
  final sizes = <double, int>{};
  for (final q in const [0.0, 9.0]) {
    final plan = planner.plan(probe, target, inventory: inventory);
    await planner.loadCapabilities(plan, target, inventory);
    plan.settings.audioVbr = true;
    plan.settings.audioVbrQuality = q;
    planner.recompute(plan, target, inventory);
    final r = await run(plan, target, 'vbr_q${q.round()}');
    check(r.ok, 'VBR q=${q.round()} runs', r.error);
    check(r.args.contains('-q:0') && r.args.contains('${q.round()}'),
        'VBR quality reaches LAME as -q', r.args.join(' '));
    check(!r.args.contains('-b:0'), 'no fixed bitrate is sent alongside VBR');
    sizes[q] = r.size;
  }
  print('    q=0 ${sizes[0.0]} bytes, q=9 ${sizes[9.0]} bytes');
  check((sizes[0.0] ?? 0) > (sizes[9.0] ?? 0) * 1.5,
      'the VBR quality scale actually changes the size',
      '${sizes[0.0]} vs ${sizes[9.0]}');
}

// ----------------------------------------------------------- subtitles

Future<void> testSubtitleFormats() async {
  print('\n--- SUBTITLES: FORMAT CONVERSION ---');
  final probe = await planner.probe(src('multilang.mkv'));
  final subIndices = [
    for (final s in probe.streams)
      if (s.type == 'subtitle') s.index,
  ];
  check(subIndices.length == 4, 'the test file has four subtitle tracks',
      '${subIndices.length}');

  final mkv = spec('mkv');
  for (final format in const ['subrip', 'ass', 'webvtt']) {
    final plan = planner.plan(probe, mkv, inventory: inventory);
    for (final i in subIndices) {
      plan.selection[i] = format;
    }
    planner.recompute(plan, mkv, inventory);
    final r = await run(plan, mkv, 'subs_$format');
    check(r.ok, 'MKV subtitles as $format runs', r.error);
    final got = r.probe?.streams
        .where((s) => s.type == 'subtitle')
        .map((s) => s.codec)
        .toSet();
    final expected = switch (format) {
      'ass' => 'ass',
      'webvtt' => 'webvtt',
      _ => 'subrip',
    };
    check(got != null && got.length == 1 && got.first == expected,
        'output subtitles really are $expected', '$got');
  }

  // MP4 can only hold its own timed text, so that is what it must get.
  final mp4 = spec('mp4');
  final toMp4 = planner.plan(probe, mp4, inventory: inventory);
  planner.recompute(toMp4, mp4, inventory);
  final r = await run(toMp4, mp4, 'subs_mp4');
  check(r.ok, 'subtitles into MP4 run', r.error);
  final codecs =
      r.probe?.streams.where((s) => s.type == 'subtitle').map((s) => s.codec);
  check(codecs != null && codecs.isNotEmpty && codecs.every((c) => c == 'mov_text'),
      'MP4 gets mov_text', '$codecs');

  // Image subtitles are pictures: no text format is offered for them.
  //
  // FFmpeg refuses to make one ("subtitle encoding currently only
  // possible from text to text or bitmap to bitmap"), so there is no
  // way to generate a real PGS or VobSub track here. What can be
  // checked is the decision Multi makes about one, which is what these
  // do — against a stream description rather than a file.
  final image = imageSubSource();
  final imageSub = image.streams.firstWhere((s) => s.type == 'subtitle');
  check(ConvertPlanner.isImageSubtitle(imageSub.codec),
      'a dvd_subtitle track is recognised as image-based', imageSub.codec);
  final imagePlan = planner.plan(image, mkv, inventory: inventory);
  check(imagePlan.selection[imageSub.index] == 'copy',
      'an image subtitle is copied into MKV rather than converted');
  final imageToMp4 = planner.plan(image, mp4, inventory: inventory);
  check(imageToMp4.selection[imageSub.index] == 'drop',
      'an image subtitle is dropped from MP4, which cannot hold it');
  check(
      planner
          .encodableFor(mkv, 'subtitle', inventory)
          .every((c) => !ConvertPlanner.isImageSubtitle(c.id)),
      'no image format is offered as a subtitle target');
}

/// A file with a picture-based subtitle track, described rather than
/// generated — see the note in [testSubtitleFormats].
ProbeResult imageSubSource() => ProbeResult(
      path: src('multilang.mkv'),
      container: 'matroska',
      durationSeconds: 8,
      streams: [
        StreamInfo(
            index: 0,
            type: 'video',
            codec: 'h264',
            width: 320,
            height: 240,
            fps: 25),
        StreamInfo(index: 1, type: 'audio', codec: 'aac', channels: 1),
        StreamInfo(
            index: 2,
            type: 'subtitle',
            codec: 'dvd_subtitle',
            language: 'eng'),
      ],
    );


Future<void> testBurnIn() async {
  print('\n--- SUBTITLES: BURN-IN ---');
  final probe = await planner.probe(src('multilang.mkv'));
  final target = spec('mp4');
  final video = probe.streams.firstWhere((s) => s.type == 'video');
  final sub = probe.streams.firstWhere((s) => s.type == 'subtitle');

  // Reference: same encode, no subtitles painted on.
  final plain = planner.plan(probe, target, inventory: inventory);
  plain.selection[video.index] = 'h264';
  plain.settings.hwAccelUserSet = true;
  plain.settings.hwAccel = false;
  for (final s in probe.streams) {
    if (s.type == 'subtitle') plain.selection[s.index] = 'drop';
  }
  await planner.loadCapabilities(plain, target, inventory);
  planner.recompute(plain, target, inventory);
  final ref = await run(plain, target, 'burn_reference');
  check(ref.ok, 'reference encode runs', ref.error);

  final burn = planner.plan(probe, target, inventory: inventory);
  burn.selection[video.index] = 'h264';
  burn.settings.hwAccelUserSet = true;
  burn.settings.hwAccel = false;
  burn.settings.burnInSubtitle = sub.index;
  for (final s in probe.streams) {
    if (s.type == 'subtitle') burn.selection[s.index] = 'drop';
  }
  await planner.loadCapabilities(burn, target, inventory);
  planner.recompute(burn, target, inventory);
  final r = await run(burn, target, 'burn_text');
  check(r.ok, 'text burn-in runs', r.error);
  check(r.args.any((a) => a.contains('subtitles=')),
      'the subtitles filter is in the command');
  check(r.probe?.streams.every((s) => s.type != 'subtitle') ?? false,
      'no subtitle track is left once it is burned in');

  // The picture must actually be different.
  final cmp = await ff([
    '-i', r.path, '-i', ref.path, '-lavfi', 'psnr', '-f', 'null', '-',
  ]);
  final psnr = RegExp(r'average:([\d.]+)').firstMatch(cmp.stderr as String);
  final db = psnr == null ? null : double.tryParse(psnr.group(1)!);
  print('    burned vs plain: ${db?.toStringAsFixed(1)} dB PSNR');
  check(db != null && db < 45,
      'burning in visibly changes the frames', '${db?.toStringAsFixed(1)} dB');

  // Burning in cannot be done on a copied stream, and Multi says so.
  final copyPlan = planner.plan(probe, spec('mkv'), inventory: inventory);
  copyPlan.settings.burnInSubtitle = sub.index;
  check(planner.burnInNeedsTranscode(copyPlan),
      'burn-in on a copied video is reported as needing a re-encode');
  copyPlan.selection[video.index] = 'h264';
  check(!planner.burnInNeedsTranscode(copyPlan),
      'and stops being reported once the video is re-encoded');

  // Picture subtitles cannot go through libass, so they are painted on
  // with overlay in a filter graph instead. FFmpeg will not create a
  // PGS or VobSub track to test against (see testSubtitleFormats), so
  // what is checked here is the graph Multi builds, plus that FFmpeg
  // accepts a graph of exactly that shape.
  final image = imageSubSource();
  final imageVideo = image.streams.firstWhere((s) => s.type == 'video');
  final imageSub = image.streams.firstWhere((s) => s.type == 'subtitle');
  final overlay = planner.plan(image, target, inventory: inventory);
  overlay.selection[imageVideo.index] = 'h264';
  overlay.selection[imageSub.index] = 'drop';
  overlay.settings.hwAccelUserSet = true;
  overlay.settings.hwAccel = false;
  overlay.settings.burnInSubtitle = imageSub.index;
  planner.recompute(overlay, target, inventory);
  final graph = planner.complexGraph(
      overlay, target, overlay.actions.first, inventory);
  print('    image burn-in graph: ${graph?.graph}');
  check(graph != null, 'an image subtitle produces a filter graph');
  check(graph?.graph.contains('[0:0][0:2]overlay') ?? false,
      'the graph overlays the subtitle stream onto the video',
      graph?.graph ?? '');
  check(graph?.label == '[vout]', 'and hands the result to a mapped label',
      graph?.label ?? '');

  // The same graph shape, with a second video standing in for the
  // subtitle track, so the syntax itself is proven against FFmpeg.
  final shape = await ff([
    '-y',
    '-f', 'lavfi', '-i', 'testsrc2=d=1:s=320x240:r=10',
    '-f', 'lavfi', '-i', 'testsrc2=d=1:s=64x64:r=10',
    '-filter_complex', '[0:0][1:0]overlay[vout]',
    '-map', '[vout]', '-c:0', 'libx264', '-preset', 'ultrafast',
    '-f', 'null', '-',
  ]);
  check(shape.exitCode == 0, 'FFmpeg accepts a graph of that shape',
      (shape.stderr as String).split('\n').last);
}


Future<void> testSubtitleExtraction() async {
  print('\n--- SUBTITLES: SIDECAR FILES ---');
  final probe = await planner.probe(src('multilang.mkv'));
  final dir = Directory('$work/subs')..createSync(recursive: true);
  for (final f in dir.listSync()) {
    f.deleteSync();
  }
  final written = await analysis.extractSubtitles(probe, 'subrip',
      outputDir: dir.path);
  check(written.length == 4, 'one file per text subtitle track',
      '${written.length}');
  check(written.every((f) => File(f).lengthSync() > 0),
      'each sidecar file has something in it');
  check(written.any((f) => f.contains('.eng.')) &&
          written.any((f) => f.contains('.fra.')),
      'files are named by language', written.map(p.basename).join(', '));
  final text = File(written.first).readAsStringSync();
  check(text.contains('SUBTITLE'), 'the text really came out',
      text.split('\n').take(4).join(' / '));

  final ass = await analysis.extractSubtitles(probe, 'ass', outputDir: dir.path);
  check(ass.every((f) => f.endsWith('.ass')), 'ASS sidecars get the .ass name');
  check(
      ass.isNotEmpty &&
          File(ass.first).readAsStringSync().contains('[Script Info]'),
      'and really are ASS files');

  // Image-based tracks are skipped rather than written empty.
  final none = await analysis.extractSubtitles(imageSubSource(), 'subrip',
      outputDir: dir.path, onlyStreams: [2]);
  check(none.isEmpty, 'image subtitles produce no sidecar file',
      '${none.length}');
}


// ------------------------------------------------------------ language

Future<void> testLanguageFilter() async {
  print('\n--- LANGUAGE FILTER ---');
  final probe = await planner.probe(src('multilang.mkv'));
  final target = spec('mkv');
  final plan = planner.plan(probe, target, inventory: inventory);

  check(plan.languagesPresent.length == 4,
      'four languages are found', '${plan.languagesPresent}');

  planner.applyLanguageFilter(plan, target, {'eng'}, inventory);
  final r = await run(plan, target, 'lang_eng');
  check(r.ok, 'English-only conversion runs', r.error);
  final kept = r.probe?.streams ?? [];
  final audio = kept.where((s) => s.type == 'audio').toList();
  final subs = kept.where((s) => s.type == 'subtitle').toList();
  check(audio.length == 1 && audio.first.language == 'eng',
      'only the English audio survives',
      audio.map((s) => s.language).join(','));
  check(subs.length == 1 && subs.first.language == 'eng',
      'only the English subtitles survive',
      subs.map((s) => s.language).join(','));
  check(kept.any((s) => s.type == 'video'),
      'video is untouched by a language filter');

  // Two languages.
  planner.applyLanguageFilter(plan, target, {'eng', 'jpn'}, inventory);
  final r2 = await run(plan, target, 'lang_eng_jpn');
  final langs = (r2.probe?.streams ?? [])
      .where((s) => s.type == 'audio' || s.type == 'subtitle')
      .map((s) => s.language)
      .toSet();
  check(r2.ok, 'two-language conversion runs', r2.error);
  check(langs.length == 2 && langs.contains('eng') && langs.contains('jpn'),
      'exactly the two chosen languages survive', '$langs');

  // Clearing it puts everything back.
  planner.applyLanguageFilter(plan, target, {}, inventory);
  final restored = plan.actions
      .where((a) =>
          (a.stream.type == 'audio' || a.stream.type == 'subtitle') &&
          a.kind != StreamActionKind.drop)
      .length;
  check(restored == 7, 'clearing the filter restores every track',
      '$restored of 7');
}

// ---------------------------------------------------- metadata / order

Future<void> testMetadataAndOrder() async {
  print('\n--- METADATA, FLAGS AND ORDER ---');
  final probe = await planner.probe(src('multilang.mkv'));
  final target = spec('mkv');
  final plan = planner.plan(probe, target, inventory: inventory);
  final audio = probe.streams.where((s) => s.type == 'audio').toList();

  plan.fileTitle = 'Multi test file';
  plan.metaFor(audio[1].index)
    ..title = 'Commentary'
    ..language = 'jpn'
    ..isDefault = true;
  plan.metaFor(audio[0].index).forced = true;
  planner.recompute(plan, target, inventory);
  final r = await run(plan, target, 'metadata');
  check(r.ok, 'metadata conversion runs', r.error);

  final title = await ffprobeField(r.path, ['format_tags=title']);
  check(title == 'Multi test file', 'the file title is written', title);

  final names = await ffprobeField(r.path, ['stream_tags=title']);
  check(names.contains('Commentary'), 'the track name is written', names);

  final dispositions = await Process.run(tools.ffprobePath!, [
    '-v', 'quiet', '-of', 'csv=p=0',
    '-show_entries', 'stream=index,codec_type:stream_disposition=default,forced',
    r.path,
  ]);
  final lines = (dispositions.stdout as String).trim().split('\n');
  print('    dispositions: ${lines.join(' | ')}');
  // The second audio track is output stream 2 (video, audio, audio…).
  check(lines.length > 2 && lines[2].endsWith('1,0'),
      'the chosen track is marked default', lines.length > 2 ? lines[2] : '');
  check(lines.length > 1 && lines[1].endsWith('0,1'),
      'the other one is forced and no longer default',
      lines.length > 1 ? lines[1] : '');
  check(lines.length > 3 && lines[3].endsWith('0,0'),
      'a track nobody mentioned keeps neither flag',
      lines.length > 3 ? lines[3] : '');

  // Other flags on a track survive being made non-default.
  final hi = planner.plan(probe, target, inventory: inventory);
  final firstAudio = probe.streams.firstWhere((s) => s.type == 'audio');
  final second = probe.streams.where((s) => s.type == 'audio').elementAt(1);
  final withFlags = StreamInfo(
    index: firstAudio.index,
    type: 'audio',
    codec: firstAudio.codec,
    channels: firstAudio.channels,
    disposition: const {'default', 'hearing_impaired'},
  );
  hi.metaFor(second.index).isDefault = true;
  final args = planner
      .buildArgs(hi, target, '${outDir.path}/flags.mkv', inventory)
      .join(' ');
  final keptFlags = planner
      .buildArgs(
          ConvertPlan(
              input: ProbeResult(
                  path: probe.path,
                  container: 'matroska',
                  durationSeconds: 8,
                  streams: [withFlags, second]),
              targetContainer: 'mkv',
              selection: {withFlags.index: 'copy', second.index: 'copy'})
            ..actions = [
              StreamAction(
                  stream: withFlags,
                  kind: StreamActionKind.copy,
                  reason: ''),
              StreamAction(
                  stream: second, kind: StreamActionKind.copy, reason: ''),
            ]
            ..metaFor(second.index).isDefault = true,
          target,
          '${outDir.path}/flags2.mkv',
          inventory)
      .join(' ');
  check(args.contains('-disposition:'), 'a disposition change is written',
      args.split('-disposition:').skip(1).join(' | '));
  check(keptFlags.contains('hearing_impaired'),
      'a flag nobody touched survives losing default',
      keptFlags.split('-disposition:').skip(1).join(' | '));
  check(!keptFlags.contains('hearing_impaired+default') &&
          !keptFlags.contains('default+hearing_impaired'),
      'and default really is gone from it');


  // Order: put the first audio track ahead of the video.
  final ordered = planner.plan(probe, target, inventory: inventory);
  final video = probe.streams.firstWhere((s) => s.type == 'video');
  ordered.streamOrder = [
    audio[0].index,
    video.index,
    for (final s in probe.streams)
      if (s.index != audio[0].index && s.index != video.index) s.index,
  ];
  planner.recompute(ordered, target, inventory);
  final first = planner.orderedActions(ordered).first;
  check(first.stream.type == 'audio', 'the plan puts audio first',
      first.stream.type);
  final r2 = await run(ordered, target, 'reordered');
  check(r2.ok, 'reordered conversion runs', r2.error);
  check(r2.probe?.streams.first.type == 'audio',
      'the output really starts with the audio track',
      '${r2.probe?.streams.first.type}');
}

// ------------------------------------------------------------ two-pass

Future<void> testTwoPass() async {
  print('\n--- TWO-PASS ---');
  final probe = await planner.probe(src('letterbox.mp4'));
  final target = spec('mp4');
  final plan = planner.plan(probe, target, inventory: inventory);
  plan.selection[probe.streams.first.index] = 'h264';
  plan.settings.hwAccelUserSet = true;
  plan.settings.hwAccel = false;
  plan.settings.mode = RateMode.constantBitrate;
  plan.settings.videoBitrate = '800k';
  plan.settings.twoPass = true;
  await planner.loadCapabilities(plan, target, inventory);
  planner.recompute(plan, target, inventory);

  check(planner.twoPassApplies(plan, inventory),
      'two-pass applies at a fixed bitrate');
  final cq = planner.plan(probe, target, inventory: inventory);
  cq.selection[probe.streams.first.index] = 'h264';
  cq.settings.hwAccelUserSet = true;
  cq.settings.hwAccel = false;
  planner.recompute(cq, target, inventory);
  check(!planner.twoPassApplies(cq, inventory),
      'and does not at constant quality, where there is nothing to aim at');

  final one = await run(plan, target, 'twopass', pass: 1);
  check(one.args.contains('-pass') && one.args.contains('1'),
      'pass 1 says so');
  check(one.args.contains('-an') && one.args.contains('-sn'),
      'pass 1 skips the audio and subtitles it does not need');
  check(one.args.last == ConvertPlanner.nullSink,
      'pass 1 writes nothing', one.args.last);
  final logBase = ConvertPlanner.passLogFor(p.join(outDir.path,
      'twopass.mp4'));
  check(File('$logBase-0.log').existsSync(),
      'pass 1 leaves its statistics behind', logBase);

  final two = await run(plan, target, 'twopass', pass: 2);
  check(two.ok, 'pass 2 runs', two.error);
  check(two.args.contains('-passlogfile'), 'pass 2 reads the statistics back');
  final duration = probe.durationSeconds ?? 8;
  final expected = 800000 * duration / 8;
  final ratio = two.size / expected;
  print('    target ${(expected / 1024).round()} KB, '
      'got ${(two.size / 1024).round()} KB (${ratio.toStringAsFixed(2)}x)');
  check(ratio > 0.7 && ratio < 1.4, 'two-pass lands near the target bitrate',
      '${ratio.toStringAsFixed(2)}x');
}

// ----------------------------------------------------------------- gif

Future<void> testGif() async {
  print('\n--- GIF ---');
  final probe = await planner.probe(src('letterbox.mp4'));
  final target = spec('gif');
  final plan = planner.plan(probe, target, inventory: inventory);
  await planner.loadCapabilities(plan, target, inventory);
  planner.recompute(plan, target, inventory);

  final r = await run(plan, target, 'palette');
  check(r.ok, 'GIF conversion runs', r.error);
  check(r.args.contains('-filter_complex'), 'GIF uses a filter graph');
  final graph = r.args[r.args.indexOf('-filter_complex') + 1];
  check(graph.contains('palettegen'), 'a palette is generated from the clip');
  check(graph.contains('paletteuse'), 'and dithered against');
  check(graph.contains('split'), 'the clip is split so both can see it');
  check(r.args.contains('-loop'), 'the loop setting is passed');
  check(r.probe?.streams.first.codec == 'gif', 'the output really is a GIF',
      '${r.probe?.streams.first.codec}');

  // Against FFmpeg's own default: same frames, no palette.
  final g = plan.settings.gif;
  final naive = p.join(outDir.path, 'naive.gif');
  await ff([
    '-y', '-i', src('letterbox.mp4'),
    '-vf', 'fps=${g.fps},scale=${g.width}:-1:flags=lanczos',
    '-c:v', 'gif', '-loop', '0', naive,
  ]);
  final ref = p.join(outDir.path, 'gifref.mkv');
  await ff([
    '-y', '-i', src('letterbox.mp4'),
    '-vf', 'fps=${g.fps},scale=${g.width}:-1:flags=lanczos',
    '-c:v', 'ffv1', ref,
  ]);
  Future<double?> ssim(String a) async {
    final out = await ff(['-i', a, '-i', ref, '-lavfi', 'ssim', '-f', 'null', '-']);
    final m = RegExp(r'All:([\d.]+)').firstMatch(out.stderr as String);
    return m == null ? null : double.tryParse(m.group(1)!);
  }

  final ours = await ssim(r.path);
  final theirs = await ssim(naive);
  final naiveSize = File(naive).lengthSync();
  print('    palette: SSIM ${ours?.toStringAsFixed(4)}, '
      '${(r.size / 1024).round()} KB');
  print('    default: SSIM ${theirs?.toStringAsFixed(4)}, '
      '${(naiveSize / 1024).round()} KB');
  check(ours != null && theirs != null && ours > theirs,
      'a palette built from the clip beats FFmpeg\'s fixed one',
      '${ours?.toStringAsFixed(4)} vs ${theirs?.toStringAsFixed(4)}');

  // The controls do what they say.
  final small = planner.plan(probe, target, inventory: inventory);
  await planner.loadCapabilities(small, target, inventory);
  small.settings.gif
    ..fps = 8
    ..width = 240
    ..maxColors = 32;
  planner.recompute(small, target, inventory);
  final r2 = await run(small, target, 'palette_small');
  check(r2.ok, 'a smaller GIF runs', r2.error);
  check((r2.probe?.streams.first.width ?? 0) == 240,
      'the width control is obeyed', '${r2.probe?.streams.first.width}');
  check(r2.size < r.size,
      'fewer frames, pixels and colours make a smaller file',
      '${r2.size} vs ${r.size}');

  // Audio has nowhere to go in a GIF and is dropped, not fumbled.
  final withAudio = await planner.probe(src('quiet.mp4'));
  final audioPlan = planner.plan(withAudio, target, inventory: inventory);
  await planner.loadCapabilities(audioPlan, target, inventory);
  planner.recompute(audioPlan, target, inventory);
  final r3 = await run(audioPlan, target, 'gif_from_av');
  check(r3.ok, 'a file with audio still converts to GIF', r3.error);
  check(r3.probe?.streams.every((s) => s.type != 'audio') ?? false,
      'no audio ends up in the GIF');
}

// ------------------------------------------------------- live progress

Future<void> testLiveProgress() async {
  print('\n--- LIVE PROGRESS ---');
  final cm = ConvertManager(tools);
  await cm.ensureHwDetected();
  final probe = await cm.planner.probe(src('letterbox.mp4'));
  final target = spec('mp4');
  final plan = await cm.planWithCapabilities(probe, target);
  final videoIndex = probe.streams.first.index;
  plan.selection[videoIndex] = 'h264';
  plan.settings.hwAccelUserSet = true;
  plan.settings.hwAccel = false;
  plan.outputDir = outDir.path;
  // Slow enough that FFmpeg emits more than one progress block, which
  // is the only way to see the figures move rather than just land.
  plan.streamOptions[videoIndex] = {'preset': 'veryslow'};
  cm.planner.recompute(plan, target, cm.inventory);

  final job = cm.enqueue(plan, target);
  var sawSpeed = false, sawBitrate = false, sawSize = false, sawEta = false;
  var sawPartial = false;
  final deadline = DateTime.now().add(const Duration(minutes: 5));
  while (job.status == JobStatus.queued || job.status == JobStatus.running) {
    if (DateTime.now().isAfter(deadline)) break;
    sawSpeed |= job.speed != null;
    sawBitrate |= job.bitrate != null;
    sawSize |= job.outputBytes != null;
    sawEta |= job.etaSeconds != null;
    final pr = job.progress;
    sawPartial |= pr != null && pr > 0 && pr < 1;
    await Future<void>.delayed(const Duration(milliseconds: 30));
  }
  check(job.status == JobStatus.done, 'the job finishes', job.statusLine);
  check(sawSpeed, 'speed is reported while running', '${job.speed}');
  check(sawBitrate, 'bitrate is reported while running', '${job.bitrate}');
  check(sawSize, 'bytes written so far are reported', '${job.outputBytes}');
  check(sawEta, 'an estimated time remaining is reported',
      '${job.etaSeconds}');
  check(sawPartial, 'progress moves rather than jumping to the end');
  check(job.progress == 1, 'progress ends at 100%', '${job.progress}');
  print('    final line: ${job.statusLine}');


  check(ConvertManager.formatDuration(65) == '1:05',
      'durations read like durations', ConvertManager.formatDuration(65));
  check(ConvertManager.formatDuration(3725) == '1:02:05', 'and so do long ones',
      ConvertManager.formatDuration(3725));
  cm.dispose();
}

// ------------------------------------------------------- pasted links

void testUrlSplitting() {
  print('\n--- PASTED LINKS ---');
  final one = DownloadManager.extractUrls('https://example.com/a');
  check(one.length == 1, 'a single link is one job', '$one');

  final many = DownloadManager.extractUrls('''
    https://example.com/one
    https://example.com/two, https://example.com/three.
    look at (https://example.com/four) too
  ''');
  check(many.length == 4, 'four links out of messy text', '$many');
  check(many[1] == 'https://example.com/two',
      'a trailing comma is not part of the link', many[1]);
  check(many[2] == 'https://example.com/three',
      'nor is a full stop', many[2]);
  check(many[3] == 'https://example.com/four',
      'nor a closing bracket', many[3]);

  final dupes = DownloadManager.extractUrls(
      'https://a.com/x https://a.com/x https://a.com/y');
  check(dupes.length == 2, 'the same link twice is one job', '$dupes');

  final magnet = DownloadManager.extractUrls(
      'grab magnet:?xt=urn:btih:abcdef0123456789 please');
  check(magnet.length == 1 && magnet.first.startsWith('magnet:'),
      'magnet links are found too', '$magnet');

  check(DownloadManager.extractUrls('not a link at all').isEmpty,
      'plain prose yields nothing');
}
