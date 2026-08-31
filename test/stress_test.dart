// A stress harness reports by printing; that is its whole job.
// ignore_for_file: avoid_print
@Tags(['stress'])
library;

import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:multi/models/convert.dart';
import 'package:multi/models/tool.dart';
import 'package:multi/services/convert_planner.dart';
import 'package:multi/services/ffmpeg_capabilities.dart';
import 'package:multi/services/ffmpeg_repair.dart';
import 'package:multi/services/image_service.dart';
import 'package:multi/services/tool_manager.dart';
import 'package:path/path.dart' as p;

/// Drives the real planner and argument builder against real media, runs
/// the FFmpeg commands it produces, and checks the results. This is the
/// end-to-end check the unit tests cannot give: the unit tests prove the
/// plan says the right thing, this proves FFmpeg agrees.
const media =
    '/tmp/claude-1000/-home-mattpng-multi/ce88ce18-cefa-4f18-829b-fe7fb146113e/scratchpad/stress';

late ToolManager tools;
late ConvertPlanner planner;
late EncoderInventory inventory;
late Directory outDir;

final failures = <String>[];
var checks = 0;

void check(bool ok, String label, [String detail = '']) {
  checks++;
  if (!ok) failures.add('$label${detail.isEmpty ? '' : ' — $detail'}');
}

ContainerSpec spec(String id) =>
    containerSpecs.firstWhere((c) => c.id == id);

Future<ProbeResult?> probeOrNull(String path) async {
  try {
    return await planner.probe(path);
  } catch (_) {
    return null;
  }
}

/// Run a plan for real and report what came out.
Future<Map<String, dynamic>> runPlan(
    ConvertPlan plan, ContainerSpec target, String label) async {
  final out = p.join(outDir.path,
      '${label.replaceAll(RegExp(r'[^A-Za-z0-9_.-]'), '_')}.${target.extension}');
  final args = planner.buildArgs(plan, target, out, inventory);
  final r = await Process.run(tools.pathFor(ToolId.ffmpeg)!, args)
      .timeout(const Duration(seconds: 120));
  if (r.exitCode != 0) {
    return {
      'ok': false,
      'error': (r.stderr as String)
          .trim()
          .split('\n')
          .where((l) => l.contains('rror') || l.contains('Invalid'))
          .join(' | '),
      'args': args.join(' '),
    };
  }
  final probed = await probeOrNull(out);
  return {
    'ok': probed != null && File(out).lengthSync() > 0,
    'probe': probed,
    'size': File(out).existsSync() ? File(out).lengthSync() : 0,
    'path': out,
  };
}

void main() {
  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    const channel = MethodChannel('plugins.flutter.io/path_provider');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async =>
            '/home/mattpng/.local/share/dev.multi.multi');
    tools = ToolManager();
    await tools.init(checkForUpdates: false);
    planner = ConvertPlanner(tools);
    outDir = Directory('$media/out')..createSync(recursive: true);

    // Real encoder inventory, including proven hardware families.
    final r = await Process.run(
        tools.pathFor(ToolId.ffmpeg)!, ['-hide_banner', '-encoders']);
    final parsed = EncoderInventory.parse(r.stdout as String);
    final hw = <String>[];
    if (File('/dev/dri/renderD128').existsSync()) hw.add('vaapi');
    // Prove each hardware encoder individually, exactly as the app does.
    final proven = <String>{};
    for (final family in hw) {
      for (final codec in const ['h264', 'hevc', 'av1', 'vp9']) {
        final enc = '${codec}_$family';
        if (!parsed.encoders.contains(enc)) continue;
        final t = await Process.run(tools.pathFor(ToolId.ffmpeg)!, [
          '-v', 'error',
          if (family == 'vaapi') ...[
            '-init_hw_device', 'vaapi=va:/dev/dri/renderD128',
            '-filter_hw_device', 'va',
          ],
          '-f', 'lavfi', '-i', 'testsrc2=d=0.2:s=192x108:r=10',
          if (family == 'vaapi') ...['-vf', 'format=nv12,hwupload'],
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
    print('ffmpeg encoders: ${parsed.encoders.length}, hw families: $hw');
    print('proven hw encoders: $proven');
  });

  tearDownAll(() {
    print('\n===== STRESS SUMMARY =====');
    print('checks run: $checks');
    print('failures:   ${failures.length}');
    for (final f in failures) {
      print('  FAIL $f');
    }
  });

  test('every source probes, and reports sane stream info', () async {
    final files = Directory(media)
        .listSync()
        .whereType<File>()
        .where((f) => !f.path.endsWith('.srt') && !f.path.endsWith('.png'))
        .toList()
      ..sort((a, b) => a.path.compareTo(b.path));
    print('\n--- PROBE (${files.length} sources) ---');
    for (final f in files) {
      final probe = await probeOrNull(f.path);
      check(probe != null, 'probe ${p.basename(f.path)}');
      if (probe == null) continue;
      final v = probe.streams.where((s) => s.type == 'video').length;
      final a = probe.streams.where((s) => s.type == 'audio').length;
      final s = probe.streams.where((s) => s.type == 'subtitle').length;
      print('  ${p.basename(f.path).padRight(26)} '
          '${probe.durationSeconds?.toStringAsFixed(2) ?? '?'}s  '
          'v:$v a:$a s:$s  ${probe.streams.map((x) => x.codec).join(',')}');
      check(probe.streams.isNotEmpty, 'streams ${p.basename(f.path)}');
    }
  }, timeout: const Timeout(Duration(minutes: 5)));

  test('every source into every container, executed for real', () async {
    final files = Directory(media)
        .listSync()
        .whereType<File>()
        .where((f) => !f.path.endsWith('.srt') && !f.path.endsWith('.png'))
        .toList()
      ..sort((a, b) => a.path.compareTo(b.path));
    print('\n--- CONVERSION MATRIX ---');
    var ran = 0, remux = 0;
    for (final f in files) {
      final probe = await probeOrNull(f.path);
      if (probe == null) continue;
      final name = p.basename(f.path);
      final hasVideo =
          probe.streams.any((s) => s.type == 'video' && !s.attachedPic);
      final row = StringBuffer('  ${name.padRight(26)}');
      for (final target in containerSpecs) {
        // A video-only container cannot be asked of an audio-only file.
        if (!target.audioOnly && !hasVideo) continue;
        final plan = planner.plan(probe, target, inventory: inventory);
        if (plan.keepsNothing) {
          // The app refuses these outright now; make sure it really is
          // an impossible pairing rather than a silent skip.
          check(target.audioOnly && !probe.streams.any((x) => x.type == 'audio'),
              'empty plan should only happen with no audio: $name -> ${target.id}');
          row.write(' -${target.id}');
          continue;
        }
        final res = await runPlan(plan, target, '${name}__${target.id}');
        ran++;
        if (plan.isPureRemux) remux++;
        final ok = res['ok'] == true;
        check(ok, 'convert $name -> ${target.id}',
            (res['error'] ?? '').toString());
        row.write(ok ? ' ${target.id}' : ' !${target.id}');
        if (ok) {
          // The output must contain exactly the streams the plan kept.
          final kept = plan.actions
              .where((a) => a.kind != StreamActionKind.drop)
              .length;
          final got = (res['probe'] as ProbeResult).streams.length;
          check(got == kept, 'stream count $name -> ${target.id}',
              'plan kept $kept, file has $got');
        }
      }
      print(row.toString());
    }
    print('  conversions run: $ran (pure remux: $remux)');
  }, timeout: const Timeout(Duration(minutes: 30)));

  test('every offered codec in every container really encodes', () async {
    final src = (await probeOrNull('$media/01_mp4_h264_aac.mp4'))!;
    final srcSurround = (await probeOrNull('$media/02_mkv_hevc_ac3_51.mkv'))!;
    print('\n--- CODEC MATRIX (curated codecs) ---');
    var ran = 0;
    for (final target in containerSpecs) {
      for (final type in const ['video', 'audio']) {
        if (type == 'video' && target.audioOnly) continue;
        final codecs = planner
            .encodableFor(target, type, inventory)
            .where((c) => c.rank < 900) // curated, not the long tail
            .toList();
        if (codecs.isEmpty) continue;
        final names = <String>[];
        for (final codec in codecs) {
          // Surround source for audio, to exercise channel handling.
          final probe = type == 'audio' ? srcSurround : src;
          final plan = planner.plan(probe, target, inventory: inventory);
          final stream = probe.streams.firstWhere((x) => x.type == type,
              orElse: () => probe.streams.first);
          if (stream.type != type) continue;
          plan.selection[stream.index] = codec.id;
          planner.recompute(plan, target, inventory);
          if (plan.keepsNothing) continue;
          final res =
              await runPlan(plan, target, 'codec_${target.id}_${codec.id}');
          ran++;
          final ok = res['ok'] == true;
          check(ok, 'encode ${codec.id} into ${target.id}',
              (res['error'] ?? '').toString());
          names.add(ok ? codec.id : '!${codec.id}');
        }
        if (names.isNotEmpty) {
          print('  ${target.id.padRight(8)} $type: ${names.join(' ')}');
        }
      }
    }
    print('  codec encodes run: $ran');
  }, timeout: const Timeout(Duration(minutes: 30)));

  test('filters change the picture as described', () async {
    final src = (await probeOrNull('$media/01_mp4_h264_aac.mp4'))!;
    final target = spec('mp4');
    print('\n--- FILTERS ---');
    Future<ProbeResult?> withFilter(
        String label, void Function(VideoFilters f) setup) async {
      final plan = planner.plan(src, target, inventory: inventory);
      plan.selection[0] = 'h264'; // force a re-encode so filters apply
      setup(plan.settings.filters);
      planner.recompute(plan, target, inventory);
      final res = await runPlan(plan, target, 'filter_$label');
      check(res['ok'] == true, 'filter $label',
          (res['error'] ?? '').toString());
      return res['probe'] as ProbeResult?;
    }

    final scaled = await withFilter('scale', (f) => f.scale = '320:-2');
    check(scaled?.streams.first.width == 320, 'scale width',
        'got ${scaled?.streams.first.width}');
    print('  scale=320:-2 -> ${scaled?.streams.first.width}x'
        '${scaled?.streams.first.height}');

    final fps = await withFilter('fps', (f) => f.fps = '10');
    check((fps?.streams.first.fps ?? 0).round() == 10, 'fps',
        'got ${fps?.streams.first.fps}');
    print('  fps=10 -> ${fps?.streams.first.fps?.toStringAsFixed(2)}');

    final cropped = await withFilter('crop', (f) => f.crop = '320:180:0:0');
    check(cropped?.streams.first.width == 320, 'crop width');
    print('  crop -> ${cropped?.streams.first.width}x'
        '${cropped?.streams.first.height}');

    final rotated = await withFilter('rotate', (f) => f.rotate = '90');
    // Rotating 90 swaps the axes.
    check(rotated?.streams.first.width == 360, 'rotate swaps axes',
        'got ${rotated?.streams.first.width}x${rotated?.streams.first.height}');
    print('  rotate 90 -> ${rotated?.streams.first.width}x'
        '${rotated?.streams.first.height}');

    await withFilter('deinterlace', (f) => f.deinterlace = true);
    await withFilter('denoise', (f) => f.denoise = true);
    await withFilter('grayscale', (f) => f.grayscale = true);
    await withFilter('custom', (f) => f.custom = 'eq=contrast=1.2');
    await withFilter('combined', (f) {
      f.scale = '160:-2';
      f.fps = '15';
      f.grayscale = true;
      f.deinterlace = true;
    });
    print('  deinterlace / denoise / grayscale / custom / combined: ok');
  }, timeout: const Timeout(Duration(minutes: 15)));

  test('size caps really land under the cap', () async {
    final src = (await probeOrNull('$media/01_mp4_h264_aac.mp4'))!;
    print('\n--- SIZE CAPS ---');
    for (final target in [spec('mp4'), spec('mkv')]) {
      for (final capMb in [1, 2, 5]) {
        final plan = planner.plan(src, target, inventory: inventory);
        plan.selection[0] = 'h264'; // a cap needs a re-encode
        plan.settings.sizeCapMb = capMb;
        planner.recompute(plan, target, inventory);
        final res = await runPlan(plan, target, 'cap_${target.id}_$capMb');
        final ok = res['ok'] == true;
        check(ok, 'size cap $capMb MB -> ${target.id}',
            (res['error'] ?? '').toString());
        if (!ok) continue;
        final mb = (res['size'] as int) / 1e6;
        // A 1s clip has little room to be wrong, but the cap must hold.
        check(mb <= capMb * 1.15, 'cap $capMb MB respected (${target.id})',
            'produced ${mb.toStringAsFixed(2)} MB');
        print('  ${target.id} cap ${capMb}MB -> ${mb.toStringAsFixed(2)} MB');
      }
    }
  }, timeout: const Timeout(Duration(minutes: 15)));

  test('estimates are in the right ballpark against real output', () async {
    print('\n--- ESTIMATE ACCURACY ---');
    final sources = ['01_mp4_h264_aac.mp4', '03_webm_vp9_opus.webm',
        '05_avi_mpeg4_mp3.avi', '11_mp4_4k.mp4'];
    final ratios = <double>[];
    for (final f in sources) {
      final src = (await probeOrNull('$media/$f'))!;
      for (final codec in ['h264', 'hevc']) {
        final plan = planner.plan(src, spec('mkv'), inventory: inventory);
        final v = src.streams.firstWhere((x) => x.type == 'video');
        plan.selection[v.index] = codec;
        plan.settings.hwAccel = false;
        plan.settings.hwAccelUserSet = true;
        planner.recompute(plan, spec('mkv'), inventory);
        final est = plan.estimatedTotalBytes;
        final res = await runPlan(plan, spec('mkv'), 'est_${f}_$codec');
        if (res['ok'] != true || est == null) continue;
        final actual = res['size'] as int;
        final ratio = est / actual;
        ratios.add(ratio);
        print('  ${f.padRight(24)} $codec  est '
            '${(est / 1e6).toStringAsFixed(2)}MB  actual '
            '${(actual / 1e6).toStringAsFixed(2)}MB  ${ratio.toStringAsFixed(2)}x');
      }
    }
    check(ratios.isNotEmpty, 'estimates produced');
    final worst = ratios.map((r) => r > 1 ? r : 1 / r).reduce((a, b) => a > b ? a : b);
    print('  worst error: ${worst.toStringAsFixed(2)}x over ${ratios.length} runs');
    // The old bits-per-pixel model was 5x out; anything past 3x is a
    // regression worth failing on.
    check(worst < 3.0, 'estimates within 3x', 'worst ${worst.toStringAsFixed(2)}x');
  }, timeout: const Timeout(Duration(minutes: 20)));

  test('hardware encoding produces a real file', () async {
    if (inventory.provenHwEncoders.isEmpty) {
      print('\n--- HARDWARE: none on this machine, skipped ---');
      return;
    }
    print('\n--- HARDWARE (${inventory.provenHwEncoders.join(', ')}) ---');
    final src = (await probeOrNull('$media/01_mp4_h264_aac.mp4'))!;
    for (final codec in ['h264', 'hevc', 'vp9', 'av1']) {
      final enc = inventory.hwEncoderFor(codec);
      final target = codec == 'vp9' || codec == 'av1' ? spec('webm') : spec('mp4');
      final plan = planner.plan(src, target, inventory: inventory);
      plan.selection[0] = codec;
      plan.settings.hwAccel = true;
      plan.settings.hwAccelUserSet = true;
      planner.recompute(plan, target, inventory);
      final res = await runPlan(plan, target, 'hw_$codec');
      final ok = res['ok'] == true;
      // Only codecs with a proven encoder should have been offered
      // hardware; the rest must still succeed in software.
      check(ok, 'hardware-path encode $codec', (res['error'] ?? '').toString());
      print('  $codec: encoder=${enc ?? 'software'} -> ${ok ? 'ok' : 'FAILED'}');
    }
  }, timeout: const Timeout(Duration(minutes: 15)));

  test('deleting the source only happens after a good output', () async {
    print('\n--- DELETE SOURCE SAFETY ---');
    final work = Directory('$media/del')..createSync(recursive: true);
    final copy = File('${work.path}/clip.mp4');
    File('$media/01_mp4_h264_aac.mp4').copySync(copy.path);
    final probe = (await probeOrNull(copy.path))!;
    final plan = planner.plan(probe, spec('mkv'), inventory: inventory);
    plan.settings.deleteSourceWhenDone = true;
    final out = '${work.path}/clip.mkv';
    final args = planner.buildArgs(plan, spec('mkv'), out, inventory);
    final r = await Process.run(tools.pathFor(ToolId.ffmpeg)!, args);
    check(r.exitCode == 0, 'conversion for delete test');
    // Mirrors ConvertManager's guard.
    final okToDelete = File(out).existsSync() &&
        File(out).lengthSync() > 0 &&
        out != copy.path;
    check(okToDelete, 'guard allows deletion when output is good');
    if (okToDelete) copy.deleteSync();
    check(!copy.existsSync(), 'source removed');
    check(File(out).existsSync() && File(out).lengthSync() > 0,
        'output survives');
    print('  output ${File(out).lengthSync()} bytes, source removed: '
        '${!copy.existsSync()}');
    work.deleteSync(recursive: true);
  }, timeout: const Timeout(Duration(minutes: 5)));

  test('image conversion across every format', () async {
    final svc = ImageService(tools);
    print('\n--- IMAGES ---');
    final work = Directory('$media/img')..createSync(recursive: true);
    // A source of each kind ImageMagick will meet.
    for (final srcFmt in ['png', 'jpg', 'webp', 'gif', 'tiff', 'bmp']) {
      final src = '${work.path}/src.$srcFmt';
      final gen = await Process.run(tools.pathFor(ToolId.magick)!,
          ['-size', '160x120', 'gradient:blue-pink', src]);
      check(gen.exitCode == 0, 'generate $srcFmt source');
      if (gen.exitCode != 0) continue;
      final results = <String>[];
      for (final fmt in imageFormats) {
        final settings = ImageSettings()
          ..targetFormat = fmt.id
          ..quality = 80
          ..stripMetadata = true
          ..maxDimension = 100;
        final plan = svc.planFor(src, settings);
        final out = '${work.path}/out_${srcFmt}_to_${fmt.id}.${fmt.id}';
        final r = await Process.run(
            tools.pathFor(ToolId.magick)!, [src, ...plan.args, out]);
        final ok = r.exitCode == 0 &&
            File(out).existsSync() &&
            File(out).lengthSync() > 0;
        check(ok, 'image $srcFmt -> ${fmt.id}',
            (r.stderr as String).trim().split('\n').first);
        results.add(ok ? fmt.id : '!${fmt.id}');
      }
      print('  ${srcFmt.padRight(5)} -> ${results.join(' ')}');
    }
    work.deleteSync(recursive: true);
  }, timeout: const Timeout(Duration(minutes: 15)));

  test('discovered encoder options really reach FFmpeg', () async {
    final src = (await probeOrNull('$media/01_mp4_h264_aac.mp4'))!;
    final target = spec('mp4');
    print('\n--- DISCOVERED OPTIONS ---');
    final plan = planner.plan(src, target, inventory: inventory);
    plan.selection[0] = 'h264';
    plan.settings.hwAccel = false;
    plan.settings.hwAccelUserSet = true;
    planner.recompute(plan, target, inventory);
    await planner.loadCapabilities(plan, target, inventory);

    final encoder =
        planner.encoderNameFor('h264', plan.settings, inventory)!;
    final caps = plan.encoderCaps[encoder] as EncoderCaps?;
    check(caps != null, 'capabilities loaded for $encoder');
    check((caps?.options.length ?? 0) > 20,
        '$encoder exposes a real option list', '${caps?.options.length}');
    print('  $encoder: ${caps!.options.length} options, '
        '${caps.pixelFormats.length} pixel formats');

    // Set a spread of option kinds and prove FFmpeg accepts them.
    plan.streamOptions[0] = {
      'preset': 'veryfast',   // string
      'profile': 'main',      // string
      'g': '48',              // int
      'bf': '2',              // int
      'aq-mode': 'variance',  // enum by name
    };
    plan.muxerOptions['movflags'] = '+faststart';
    final res = await runPlan(plan, target, 'opts_h264');
    check(res['ok'] == true, 'encode with discovered options',
        (res['error'] ?? '').toString());
    if (res['ok'] == true) {
      final probe = res['probe'] as ProbeResult;
      final v = probe.streams.firstWhere((x) => x.type == 'video');
      check(v.profile?.toLowerCase().contains('main') ?? false,
          'the profile option took effect', 'got ${v.profile}');
      print('  set preset/profile/g/bf/aq-mode + movflags -> '
          'output profile ${v.profile}');
    }

    // The same for an audio encoder.
    final aplan = planner.plan(src, spec('m4a'), inventory: inventory);
    final astream = src.streams.firstWhere((x) => x.type == 'audio');
    aplan.selection[astream.index] = 'aac';
    planner.recompute(aplan, spec('m4a'), inventory);
    await planner.loadCapabilities(aplan, spec('m4a'), inventory);
    aplan.streamOptions[astream.index] = {'aac_coder': 'fast'};
    final ares = await runPlan(aplan, spec('m4a'), 'opts_aac');
    check(ares['ok'] == true, 'audio encode with discovered options',
        (ares['error'] ?? '').toString());
    print('  aac with aac_coder=fast -> ${ares['ok'] == true ? 'ok' : 'FAILED'}');
  }, timeout: const Timeout(Duration(minutes: 10)));

  test('trimming keeps only the requested part', () async {
    // A 5s source so a trim is measurable.
    final long = '$media/trim_src.mp4';
    await Process.run(tools.pathFor(ToolId.ffmpeg)!, [
      '-y', '-v', 'error', '-f', 'lavfi', '-i',
      'testsrc2=d=5:s=320x240:r=25', '-c:v', 'libx264', long,
    ]);
    final src = (await probeOrNull(long))!;
    check((src.durationSeconds ?? 0) > 4.5, 'source is 5s');
    print('\n--- TRIM ---');
    final plan = planner.plan(src, spec('mp4'), inventory: inventory);
    plan.trimStart = '00:00:01';
    plan.trimEnd = '00:00:03';
    planner.recompute(plan, spec('mp4'), inventory);
    final res = await runPlan(plan, spec('mp4'), 'trimmed');
    check(res['ok'] == true, 'trimmed conversion',
        (res['error'] ?? '').toString());
    if (res['ok'] == true) {
      final d = (res['probe'] as ProbeResult).durationSeconds ?? 0;
      check(d > 1.5 && d < 2.6, 'trim produced ~2s', 'got ${d.toStringAsFixed(2)}s');
      print('  1s..3s of a 5s file -> ${d.toStringAsFixed(2)}s');
    }
    File(long).deleteSync();
  }, timeout: const Timeout(Duration(minutes: 5)));

  test('a broken command repairs itself and completes', () async {
    print('\n--- SELF-REPAIR ---');
    final src = (await probeOrNull('$media/30_anim.gif'))!;
    final target = spec('webm');
    final plan = planner.plan(src, target, inventory: inventory);
    plan.selection[0] = 'vp9';
    planner.recompute(plan, target, inventory);
    // Deliberately break it the way a real encoder does: strip the
    // pixel-format handling so FFmpeg meets an RGB frame.
    var args = planner.buildArgs(plan, target, '$media/out/repair.webm',
        inventory);
    args = args
        .where((a) => a != '-pix_fmt:0' && a != 'yuv420p')
        .toList();
    args.removeWhere((a) => a.contains('format=yuv420p'));
    final first = await Process.run(tools.pathFor(ToolId.ffmpeg)!, args);
    print('  unrepaired exit: ${first.exitCode}');

    if (first.exitCode != 0) {
      final repair = FfmpegRepair.diagnose(first.stderr as String);
      check(repair != null, 'a repair was found for the real failure');
      print('  diagnosis: ${repair?.description}');
      if (repair != null) {
        final fixed = FfmpegRepair.apply(args, repair);
        final second =
            await Process.run(tools.pathFor(ToolId.ffmpeg)!, fixed);
        check(second.exitCode == 0, 'repaired command succeeds',
            (second.stderr as String).split('\n').first);
        print('  after repair exit: ${second.exitCode}');
      }
    } else {
      print('  (already handled proactively — nothing to repair)');
    }
  }, timeout: const Timeout(Duration(minutes: 10)));
}
