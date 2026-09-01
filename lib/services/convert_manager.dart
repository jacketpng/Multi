import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../models/convert.dart';
import '../models/tool.dart';
import 'convert_planner.dart';
import 'ffmpeg_repair.dart';
import 'media_analysis.dart';
import 'settings.dart';
import 'tool_manager.dart';


/// Runs planned ffmpeg jobs sequentially and reports progress. Also
/// discovers which hardware encoders this machine can use.
class ConvertManager extends ChangeNotifier {
  final ToolManager tools;
  late final ConvertPlanner planner = ConvertPlanner(tools);
  late final MediaAnalysis analysis =
      MediaAnalysis(() => tools.pathFor(ToolId.ffmpeg) ?? 'ffmpeg');
  final List<ConvertJob> jobs = [];

  final Map<int, Process> _procs = {};
  int _nextId = 1;
  bool _running = false;

  EncoderInventory inventory = EncoderInventory.empty;
  bool _hwDetected = false;

  /// Saved defaults, injected from main.dart.
  Settings? settings;

  /// Files a finished download handed over, waiting for the Convert
  /// page to open them with the full plan UI. Each carries the target
  /// container the download asked for.
  final List<({String path, String containerId})> pendingFromDownloads = [];

  void queueFromDownload(String path, String containerId) {
    if (pendingFromDownloads.any((e) => e.path == path)) return;
    pendingFromDownloads.add((path: path, containerId: containerId));
    notifyListeners();
  }

  ({String path, String containerId})? takePendingFromDownload() {
    if (pendingFromDownloads.isEmpty) return null;
    final next = pendingFromDownloads.removeAt(0);
    notifyListeners();
    return next;
  }

  ConvertManager(this.tools) {
    // ffmpeg may not be resolved yet when the UI first asks for
    // detection; retry whenever the tool manager reports progress.
    tools.addListener(_onToolsChanged);
    _onToolsChanged();
  }

  void _onToolsChanged() {
    if (!_hwDetected && tools.pathFor(ToolId.ffmpeg) != null) {
      ensureHwDetected();
    }
  }

  /// Parse `ffmpeg -encoders` once, work out which hardware encoder
  /// families are plausible on this machine, then prove each family
  /// with a real 0.2s test encode. An encoder that exists in the ffmpeg
  /// build can still fail at runtime (missing driver, no GPU access —
  /// "Error parsing global options: Input/output error"), so only
  /// families that actually encode are offered.
  Future<void> ensureHwDetected() async {
    if (_hwDetected) return;
    final ffmpeg = tools.pathFor(ToolId.ffmpeg);
    if (ffmpeg == null) return;
    _hwDetected = true;
    try {
      final r = await Process.run(ffmpeg, ['-hide_banner', '-encoders'])
          .timeout(const Duration(seconds: 20));
      final parsed = EncoderInventory.parse(r.stdout as String);
      final candidates = <String>[];
      if (Platform.isMacOS) {
        candidates.add('videotoolbox');
      } else if (Platform.isWindows) {
        candidates.addAll(['nvenc', 'qsv', 'amf']);
      } else {
        if (await File('/dev/dri/renderD128').exists()) {
          candidates.add('vaapi');
        }
        if (await File('/dev/nvidia0').exists() ||
            await File('/proc/driver/nvidia/version').exists()) {
          candidates.insert(0, 'nvenc');
        }
      }
      // Probe every codec separately. A GPU routinely supports some and
      // not others (this one does H.264 and HEVC over VAAPI but not VP9
      // or AV1), so proving one codec says nothing about the rest —
      // assuming otherwise produced commands that failed at runtime.
      final proven = <String>{};
      final families = <String>[];
      for (final family in candidates) {
        var anyWorked = false;
        for (final codec in const ['h264', 'hevc', 'av1', 'vp9']) {
          final encoder = '${codec}_$family';
          if (!parsed.encoders.contains(encoder)) continue;
          if (await _smokeTest(ffmpeg, family, encoder)) {
            proven.add(encoder);
            anyWorked = true;
          }
        }
        if (anyWorked) families.add(family);
      }
      inventory = EncoderInventory(
        encoders: parsed.encoders,
        codecOf: parsed.codecOf,
        kindOf: parsed.kindOf,
        hwFamilies: families,
        provenHwEncoders: proven,
      );
    } catch (_) {
      inventory = EncoderInventory.empty;
    }
    notifyListeners();
  }

  /// Prove one specific hardware encoder by really encoding with it.
  Future<bool> _smokeTest(
      String ffmpeg, String family, String encoder) async {
    final args = <String>[
      '-v', 'error',
      if (family == 'vaapi') ...[
        '-init_hw_device', 'vaapi=va:/dev/dri/renderD128',
        '-filter_hw_device', 'va',
      ],
      '-f', 'lavfi', '-i', 'testsrc2=d=0.2:s=192x108:r=10',
      if (family == 'vaapi') ...['-vf', 'format=nv12,hwupload'],
      '-c:v', encoder,
      '-f', 'null', '-',
    ];
    try {
      final r = await Process.run(ffmpeg, args)
          .timeout(const Duration(seconds: 20));
      return r.exitCode == 0;
    } catch (_) {
      return false;
    }
  }

  String outputPathFor(ProbeResult input, ContainerSpec target,
      {String? outputDir}) {
    final dir = outputDir ?? p.dirname(input.path);
    final base = p.basenameWithoutExtension(input.path);
    var candidate = p.join(dir, '$base.${target.extension}');
    var n = 1;
    while (File(candidate).existsSync() || candidate == input.path) {
      candidate = p.join(dir, '$base (converted${n > 1 ? ' $n' : ''}).${target.extension}');
      n++;
    }
    return candidate;
  }

  /// Plan a conversion with the saved defaults applied.
  ConvertPlan planWithDefaults(ProbeResult input, ContainerSpec target) {
    final plan = planner.plan(input, target,
        inventory: inventory,
        preferHardware: settings?.preferHardware ?? true);
    settings?.applyTo(plan.settings);
    // A hardware family without constant quality has to use bitrate.
    final videoCodec = plan.actions
        .where((a) =>
            a.kind == StreamActionKind.transcode && a.stream.type == 'video')
        .map((a) => a.targetCodec)
        .firstOrNull;
    if (plan.settings.hwAccel && videoCodec != null) {
      final fam = inventory.hwFamilyFor(videoCodec);
      if (fam != null && !fam.supportsConstantQuality) {
        plan.settings.mode = RateMode.constantBitrate;
      }
    }
    if ((settings?.matchOriginalSize ?? true) &&
        plan.settings.mode == RateMode.constantQuality) {
      final q = planner.qualityMatchingOriginalSize(plan, target, inventory);
      if (q != null) plan.settings.crf = q;
    }
    planner.recompute(plan, target, inventory);
    return plan;
  }

  /// Plan, then ask FFmpeg what the chosen encoders accept so the UI can
  /// offer exactly their options and the arguments can be tailored.
  Future<ConvertPlan> planWithCapabilities(
      ProbeResult input, ContainerSpec target) async {
    await ensureHwDetected();
    final plan = planWithDefaults(input, target);
    await planner.loadCapabilities(plan, target, inventory);
    planner.recompute(plan, target, inventory);
    return plan;
  }

  /// Reload capabilities after a codec change, then recompute.
  Future<void> refreshCapabilities(
      ConvertPlan plan, ContainerSpec target) async {
    await planner.loadCapabilities(plan, target, inventory);
    planner.recompute(plan, target, inventory);
    notifyListeners();
  }

  ConvertJob enqueue(ConvertPlan plan, ContainerSpec target) {
    final out = outputPathFor(plan.input, target, outputDir: plan.outputDir);
    final twoPass = plan.settings.twoPass &&
        planner.twoPassApplies(plan, inventory);
    final job = ConvertJob(
      id: _nextId++,
      plan: plan,
      outputPath: out,
      args: planner.buildArgs(plan, target, out, inventory,
          pass: twoPass ? 1 : 0),
    );
    job.passes = twoPass ? 2 : 1;
    jobs.insert(0, job);
    notifyListeners();
    _pump();
    return job;
  }

  ContainerSpec targetOf(ConvertPlan plan) => containerSpecs.firstWhere(
      (c) => c.id == plan.targetContainer,
      orElse: () => containerSpecs.first);

  /// Measure the black bars around the picture and put the result in
  /// the plan's crop filter. Nothing is applied if there are none.
  Future<CropResult?> detectCrop(ConvertPlan plan,
      {void Function(String status)? onStatus,
      bool Function()? isCanceled}) async {
    final result = await analysis.detectCrop(plan.input,
        onStatus: onStatus, isCanceled: isCanceled);

    final f = plan.settings.filters;
    if (result == null) {
      f.cropSummary = 'FFmpeg could not read the edges of this file.';
      f.cropDetected = false;
      notifyListeners();
      return null;
    }
    f.cropSummary = result.summary;
    if (result.isFullFrame) {
      f.cropDetected = false;
      if (f.crop.isNotEmpty) f.crop = '';
    } else {
      f.crop = result.filterValue;
      f.cropDetected = true;
    }
    planner.recompute(plan, targetOf(plan), inventory);
    notifyListeners();
    return result;
  }

  /// Find out how much headroom the audio has, so peak normalisation
  /// has a real number to work from rather than a guess.
  Future<double?> measurePeak(ConvertPlan plan,
      {void Function(String status)? onStatus}) async {
    final db = await analysis.measurePeak(plan.input, onStatus: onStatus);
    plan.settings.measuredPeakDb = db;
    notifyListeners();
    return db;
  }


  /// Convert-after-download entry: probe a file and enqueue it with the
  /// default remux-first plan for the given container id.
  Future<void> enqueueByPath(String path, String containerId) async {
    final target = containerSpecs.firstWhere((c) => c.id == containerId,
        orElse: () => containerSpecs.first);
    await ensureHwDetected();
    try {
      final probe = await planner.probe(path);
      enqueue(planWithDefaults(probe, target), target);
    } catch (e) {
      // Surface the failure as a failed job so it isn't silent.
      final job = ConvertJob(
        id: _nextId++,
        plan: ConvertPlan(
            input: ProbeResult(
                path: path, container: p.extension(path), streams: []),
            targetContainer: containerId,
            selection: {}),
        outputPath: '',
        args: const [],
      );
      job.status = JobStatus.failed;
      job.statusLine = 'Could not read ${p.basename(path)}: $e';
      jobs.insert(0, job);
      notifyListeners();
    }
  }

  void cancel(ConvertJob job) {
    if (job.status == JobStatus.running) {
      _procs[job.id]?.kill();
      job.status = JobStatus.canceled;
      job.statusLine = 'Canceled';
    } else if (job.status == JobStatus.queued) {
      job.status = JobStatus.canceled;
      job.statusLine = 'Canceled';
    }
    notifyListeners();
  }

  void remove(ConvertJob job) {
    if (job.status == JobStatus.running) cancel(job);
    jobs.remove(job);
    notifyListeners();
  }

  void _pump() {
    if (_running) return;
    ConvertJob? next;
    for (final j in jobs.reversed) {
      if (j.status == JobStatus.queued) {
        next = j;
        break;
      }
    }
    if (next != null) unawaited(_run(next));
  }

  /// Run one FFmpeg invocation, streaming its -progress output into the
  /// job so the UI can show real figures rather than a spinner.
  Future<int> _runOnce(ConvertJob job, String ffmpeg, List<String> args,
      double totalSeconds) async {
    job.log.add('\$ ffmpeg ${args.join(' ')}');
    Process proc;
    try {
      proc = await Process.start(ffmpeg, args);
    } catch (e) {
      job.statusLine = 'Failed to start: $e';
      return -1;
    }
    _procs[job.id] = proc;

    proc.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((line) {
      final eq = line.indexOf('=');
      if (eq <= 0) return;
      final key = line.substring(0, eq);
      final value = line.substring(eq + 1).trim();
      switch (key) {
        // out_time_ms has always actually been microseconds.
        case 'out_time_ms':
        case 'out_time_us':
          final us = double.tryParse(value) ?? 0;
          job.outSeconds = us / 1e6;
          if (totalSeconds > 0) {
            final fraction = (us / (totalSeconds * 1e6)).clamp(0.0, 1.0);
            job.progress = job.passes > 1
                ? ((job.pass - 1) + fraction) / job.passes
                : fraction;
          }
        case 'total_size':
          job.outputBytes = int.tryParse(value);
        case 'bitrate':
          job.bitrate = value == 'N/A' ? null : value;
        case 'frame':
          job.frame = int.tryParse(value);
        case 'speed':
          job.speed = value == 'N/A' ? null : value;
          final factor = double.tryParse(value.replaceAll('x', ''));
          final done = job.outSeconds;
          if (factor != null && factor > 0 && totalSeconds > 0 && done != null) {
            final remainingThisPass = (totalSeconds - done).clamp(0, double.infinity);
            final remainingPasses = job.passes - job.pass;
            job.etaSeconds =
                (remainingThisPass + remainingPasses * totalSeconds) / factor;
          }
        case 'progress':
          break;
      }
      job.statusLine = _progressLine(job);
      notifyListeners();
    });
    proc.stderr
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((line) {
      if (line.trim().isEmpty) return;
      job.log.add(line);
      if (job.log.length > 300) job.log.removeRange(0, job.log.length - 300);
    });

    final code = await proc.exitCode;
    _procs.remove(job.id);
    return code;
  }

  /// The one-line summary under the progress bar.
  String _progressLine(ConvertJob job) {
    final parts = <String>[];
    if (job.progress != null) {
      parts.add('${(job.progress! * 100).toStringAsFixed(0)}%');
    }
    parts.add(job.plan.isPureRemux ? 'remuxing' : 'converting');
    if (job.passes > 1) parts.add('pass ${job.pass} of ${job.passes}');
    final detail = <String>[
      if (job.speed != null) job.speed!,
      if (job.etaSeconds != null) '${formatDuration(job.etaSeconds!)} left',
      if (job.bitrate != null) job.bitrate!,
      if (job.outputBytes != null) _human(job.outputBytes!),
    ];
    return '${parts.join(' — ')}${detail.isEmpty ? '' : ' · ${detail.join(' · ')}'}';
  }

  /// '1:02:03', '4:07' or '12s'.
  static String formatDuration(double seconds) {
    if (!seconds.isFinite || seconds < 0) return '—';
    final total = seconds.round();
    final h = total ~/ 3600, m = (total % 3600) ~/ 60, s = total % 60;
    if (h > 0) {
      return '$h:${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
    }
    if (m > 0) return '$m:${s.toString().padLeft(2, '0')}';
    return '${s}s';
  }

  Future<void> _run(ConvertJob job) async {
    final ffmpeg = tools.pathFor(ToolId.ffmpeg);
    if (ffmpeg == null) {
      job.status = JobStatus.failed;
      job.statusLine = 'FFmpeg is not installed yet — check the Tools page';
      notifyListeners();
      return;
    }
    _running = true;
    job.status = JobStatus.running;
    job.statusLine = 'Starting…';
    job.pass = job.passes > 1 ? 1 : 0;
    notifyListeners();

    final target = targetOf(job.plan);
    final totalSeconds = _plannedSeconds(job.plan);

    var code = await _runOnce(job, ffmpeg, job.args, totalSeconds);

    // The first pass only gathers statistics; the second does the work.
    if (code == 0 && job.passes > 1 && job.status != JobStatus.canceled) {
      job.pass = 2;
      job.args
        ..clear()
        ..addAll(planner.buildArgs(
            job.plan, target, job.outputPath, inventory, pass: 2));
      job.log.add('\n== pass 2 of 2');
      code = await _runOnce(job, ffmpeg, job.args, totalSeconds);
    }

    // If FFmpeg refused for a reason with a known remedy, apply it and
    // run again rather than handing the user an error to research.
    if (code != 0 && job.status != JobStatus.canceled) {
      final repaired = await _tryRepair(job, ffmpeg);
      if (repaired != null) {
        code = repaired;
      }
    }

    if (job.status != JobStatus.canceled) {
      if (code == 0) {
        job.status = JobStatus.done;
        job.progress = 1;
        job.etaSeconds = null;
        var line = 'Done → ${p.basename(job.outputPath)}';
        try {
          final size = await File(job.outputPath).length();
          line += ' (${_human(size)})';
        } catch (_) {}
        if (job.plan.extractSubtitles) {
          try {
            final written = await analysis.extractSubtitles(
              job.plan.input,
              job.plan.extractSubtitleFormat,
              outputDir: p.dirname(job.outputPath),
            );
            job.sidecarFiles.addAll(written);
            if (written.isNotEmpty) {
              line += ' · ${written.length} subtitle '
                  '${written.length == 1 ? 'file' : 'files'} written';
            }
          } catch (e) {
            line += ' · could not write the subtitle files: $e';
          }
        }
        // Only ever delete the source after the output exists and is
        // not the source itself, so a failed or in-place conversion can
        // never destroy the original.
        if (job.plan.settings.deleteSourceWhenDone) {
          final src = File(job.plan.input.path);
          final out = File(job.outputPath);
          try {
            if (await out.exists() &&
                await out.length() > 0 &&
                !p.equals(out.path, src.path)) {
              await src.delete();
              line += ' · original deleted';
            }
          } catch (e) {
            line += ' · could not delete the original: $e';
          }
        }
        if (job.repairedWith.isNotEmpty) {
          line += ' · adapted automatically: ${job.repairedWith.join(', ')}';
        }
        job.statusLine = line;
      } else {
        job.status = JobStatus.failed;
        job.statusLine = job.log.lastWhere(
            (l) => l.contains('Error') || l.contains('Invalid'),
            orElse: () => 'ffmpeg exited with code $code');
        if (job.plan.settings.hwAccel) {
          job.statusLine =
              '${job.statusLine} — hardware encoder failed; try again with hardware acceleration off';
        }
      }
    } else {
      // Clean up the partial output of a canceled job.
      try {
        final f = File(job.outputPath);
        if (await f.exists()) await f.delete();
      } catch (_) {}
    }
    await _cleanPassLogs(job);
    _running = false;
    notifyListeners();
    _pump();
  }

  /// How long the output will be, which is what progress is measured
  /// against — a trim makes that shorter than the source.
  double _plannedSeconds(ConvertPlan plan) {
    final total = plan.input.durationSeconds ?? 0;
    final start = ConvertPlanner.parseTime(plan.trimStart) ?? 0;
    final end = ConvertPlanner.parseTime(plan.trimEnd);
    final stop = end ?? total;
    final span = stop - start;
    return span > 0 ? span : total;
  }

  /// Two-pass leaves statistics files behind; they are no use to anyone
  /// once the encode is over.
  Future<void> _cleanPassLogs(ConvertJob job) async {
    if (job.passes < 2) return;
    final base = ConvertPlanner.passLogFor(job.outputPath);
    for (final suffix in const ['-0.log', '-0.log.mbtree', '.log', '.log.mbtree']) {
      try {
        final f = File('$base$suffix');
        if (await f.exists()) await f.delete();
      } catch (_) {}
    }
  }

  /// Up to three rounds of read-the-error, fix it, try again.
  Future<int?> _tryRepair(ConvertJob job, String ffmpeg) async {
    var attempts = 0;
    final applied = <String>[];
    while (attempts < 3) {
      final stderr = job.log.reversed.take(40).toList().reversed.join('\n');
      final repair = FfmpegRepair.diagnose(stderr);
      if (repair == null) return null;
      if (applied.contains(repair.description)) return null; // no progress
      applied.add(repair.description);
      attempts++;

      job.args
        ..clear()
        ..addAll(FfmpegRepair.apply(job.args, repair));
      job.statusLine = 'Retrying — ${repair.description}';
      job.log.add('\n== retry $attempts: ${repair.description}');
      job.log.add('\$ ffmpeg ${job.args.join(' ')}');
      notifyListeners();

      try {
        final r = await Process.run(ffmpeg, job.args)
            .timeout(const Duration(minutes: 30));
        for (final line in (r.stderr as String).split('\n')) {
          if (line.trim().isNotEmpty) job.log.add(line);
        }
        if (r.exitCode == 0) {
          job.repairedWith = List.of(applied);
          return 0;
        }
      } catch (e) {
        job.log.add('retry failed: \$e');
        return null;
      }
    }
    return null;
  }

  String _human(int bytes) {
    const units = ['B', 'KB', 'MB', 'GB'];
    var v = bytes.toDouble();
    var i = 0;
    while (v >= 1024 && i < units.length - 1) {
      v /= 1024;
      i++;
    }
    return '${v.toStringAsFixed(v >= 100 || i == 0 ? 0 : 1)} ${units[i]}';
  }

  @override
  void dispose() {
    tools.removeListener(_onToolsChanged);
    super.dispose();
  }
}
