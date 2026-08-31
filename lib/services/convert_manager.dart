import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../models/convert.dart';
import '../models/tool.dart';
import 'convert_planner.dart';
import 'settings.dart';
import 'tool_manager.dart';

/// Runs planned ffmpeg jobs sequentially and reports progress. Also
/// discovers which hardware encoders this machine can use.
class ConvertManager extends ChangeNotifier {
  final ToolManager tools;
  late final ConvertPlanner planner = ConvertPlanner(tools);
  final List<ConvertJob> jobs = [];
  final Map<int, Process> _procs = {};
  int _nextId = 1;
  bool _running = false;

  EncoderInventory inventory = EncoderInventory.empty;
  bool _hwDetected = false;

  /// Saved defaults, injected from main.dart.
  Settings? settings;

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
      final proven = <String>[];
      for (final family in candidates) {
        if (await _smokeTest(ffmpeg, family, parsed.encoders)) {
          proven.add(family);
        }
      }
      inventory = EncoderInventory(
        encoders: parsed.encoders,
        codecOf: parsed.codecOf,
        kindOf: parsed.kindOf,
        hwFamilies: proven,
      );
    } catch (_) {
      inventory = EncoderInventory.empty;
    }
    notifyListeners();
  }

  /// Encode a fraction of a second of test video with the family's
  /// H.264 encoder (or whichever codec it has) to /dev/null.
  Future<bool> _smokeTest(
      String ffmpeg, String family, Set<String> available) async {
    final codec = ['h264', 'hevc', 'av1', 'vp9']
        .where((c) => available.contains('${c}_$family'))
        .firstOrNull;
    if (codec == null) return false;
    final encoder = '${codec}_$family';
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

  String outputPathFor(ProbeResult input, ContainerSpec target) {
    final dir = p.dirname(input.path);
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

  ConvertJob enqueue(ConvertPlan plan, ContainerSpec target) {
    final out = outputPathFor(plan.input, target);
    final job = ConvertJob(
      id: _nextId++,
      plan: plan,
      outputPath: out,
      args: planner.buildArgs(plan, target, out, inventory),
    );
    jobs.insert(0, job);
    notifyListeners();
    _pump();
    return job;
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
    notifyListeners();

    job.log.add('\$ ffmpeg ${job.args.join(' ')}');
    Process proc;
    try {
      proc = await Process.start(ffmpeg, job.args);
    } catch (e) {
      job.status = JobStatus.failed;
      job.statusLine = 'Failed to start: $e';
      _running = false;
      notifyListeners();
      _pump();
      return;
    }
    _procs[job.id] = proc;
    final totalUs = (job.plan.input.durationSeconds ?? 0) * 1e6;

    proc.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((line) {
      // -progress pipe:1 emits key=value lines.
      if (line.startsWith('out_time_ms=') || line.startsWith('out_time_us=')) {
        final us = double.tryParse(line.split('=').last) ?? 0;
        if (totalUs > 0) {
          job.progress = (us / totalUs).clamp(0.0, 1.0);
          job.statusLine =
              '${(job.progress! * 100).toStringAsFixed(0)}%${job.plan.isPureRemux ? ' — remuxing' : ' — converting'}';
          notifyListeners();
        }
      } else if (line.startsWith('speed=')) {
        final speed = line.split('=').last.trim();
        if (speed.isNotEmpty && speed != 'N/A' && job.statusLine.contains('%')) {
          job.statusLine = '${job.statusLine.split(' @').first} @ $speed';
          notifyListeners();
        }
      }
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
    if (job.status != JobStatus.canceled) {
      if (code == 0) {
        job.status = JobStatus.done;
        job.progress = 1;
        var line = 'Done → ${p.basename(job.outputPath)}';
        try {
          final size = await File(job.outputPath).length();
          line += ' (${_human(size)})';
        } catch (_) {}
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
    _running = false;
    notifyListeners();
    _pump();
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
