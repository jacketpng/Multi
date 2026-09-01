import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../models/convert.dart';
import '../models/tool.dart';
import 'tool_manager.dart';

class ImageFormat {
  final String id;
  final String label;
  final bool lossless;
  final bool supportsQuality;
  final bool supportsLosslessMode; // e.g. webp/avif can do both
  const ImageFormat(this.id, this.label,
      {this.lossless = false,
      this.supportsQuality = true,
      this.supportsLosslessMode = false});
}

const imageFormats = <ImageFormat>[
  ImageFormat('jpg', 'JPEG'),
  ImageFormat('png', 'PNG', lossless: true, supportsQuality: false),
  ImageFormat('webp', 'WebP', supportsLosslessMode: true),
  ImageFormat('avif', 'AVIF', supportsLosslessMode: true),
  ImageFormat('gif', 'GIF', lossless: true, supportsQuality: false),
  ImageFormat('tiff', 'TIFF', lossless: true, supportsQuality: false),
  ImageFormat('bmp', 'BMP', lossless: true, supportsQuality: false),
];

class ImageSettings {
  String targetFormat = 'webp';
  int quality = 85;
  bool losslessMode = false;
  bool stripMetadata = false;
  int? maxDimension; // resize so the longest edge fits this
  int? resizePercent;
  String extraArgs = '';
}

class ImageJobItem {
  final String inputPath;
  ImagePlan? plan;
  JobStatus status = JobStatus.queued;
  String statusLine = '';
  String? outputPath;
  ImageJobItem(this.inputPath);
}

/// Plans and runs ImageMagick conversions. Same philosophy as video:
/// explain exactly what will happen to the pixels before doing it.
class ImageService extends ChangeNotifier {
  final ToolManager tools;
  final List<ImageJobItem> items = [];
  bool running = false;

  ImageService(this.tools);

  static const _losslessInputs = {'png', 'gif', 'bmp', 'tiff', 'tif', 'webp'};

  void addFiles(List<String> paths) {
    for (final path in paths) {
      if (items.any((i) => i.inputPath == path)) continue;
      items.add(ImageJobItem(path));
    }
    notifyListeners();
  }

  void remove(ImageJobItem item) {
    items.remove(item);
    notifyListeners();
  }

  void clearFinished() {
    items.removeWhere((i) => i.status == JobStatus.done);
    notifyListeners();
  }

  ImagePlan planFor(String inputPath, ImageSettings s) {
    final inputExt =
        p.extension(inputPath).replaceFirst('.', '').toLowerCase();
    final fmt = imageFormats.firstWhere((f) => f.id == s.targetFormat);
    final losslessSource = _losslessInputs.contains(inputExt);
    final losslessTarget =
        fmt.lossless || (fmt.supportsLosslessMode && s.losslessMode);

    final ops = <String>[];
    final args = <String>['-auto-orient'];
    final sameFormat = inputExt == s.targetFormat ||
        (inputExt == 'jpeg' && s.targetFormat == 'jpg');

    if (sameFormat && s.maxDimension == null && s.resizePercent == null &&
        !s.stripMetadata && s.extraArgs.trim().isEmpty) {
      ops.add('Same format, no edits. File is simply re-saved');
    } else if (sameFormat) {
      ops.add('Kept as ${fmt.label}');
    } else {
      ops.add(losslessSource && !losslessTarget
          ? 'Pixels re-encoded: ${inputExt.toUpperCase()} (lossless) → ${fmt.label} (lossy, q${s.quality})'
          : losslessTarget
              ? 'Pixels re-encoded: ${inputExt.toUpperCase()} → ${fmt.label} (lossless)'
              : 'Pixels re-encoded: ${inputExt.toUpperCase()} → ${fmt.label} (q${s.quality})');
    }
    if (s.resizePercent != null) {
      ops.add('Resized to ${s.resizePercent}%');
      args.addAll(['-resize', '${s.resizePercent}%']);
    } else if (s.maxDimension != null) {
      ops.add('Fit within ${s.maxDimension}×${s.maxDimension}px (never upscaled)');
      args.addAll(['-resize', '${s.maxDimension}x${s.maxDimension}>']);
    }
    if (s.stripMetadata) {
      ops.add('Metadata stripped (EXIF, GPS, color profiles)');
      args.add('-strip');
    }
    if (fmt.supportsLosslessMode && s.losslessMode) {
      args.addAll(['-define', '${fmt.id}:lossless=true']);
    } else if (fmt.supportsQuality || fmt.id == 'jpg') {
      args.addAll(['-quality', '${s.quality}']);
    }
    args.addAll(s.extraArgs.trim().isEmpty
        ? const []
        : s.extraArgs.trim().split(RegExp(r'\s+')));

    return ImagePlan(
      inputPath: inputPath,
      inputFormat: inputExt,
      targetFormat: s.targetFormat,
      losslessSource: losslessSource,
      losslessTarget: losslessTarget,
      operations: ops,
      args: args,
    );
  }

  void planAll(ImageSettings s) {
    for (final item in items) {
      if (item.status == JobStatus.queued) {
        item.plan = planFor(item.inputPath, s);
      }
    }
    notifyListeners();
  }

  Future<void> runAll(ImageSettings s) async {
    if (running) return;
    final magick = tools.pathFor(ToolId.magick);
    if (magick == null) {
      for (final i in items) {
        if (i.status == JobStatus.queued) {
          i.status = JobStatus.failed;
          i.statusLine = 'ImageMagick is not installed yet. Check the Tools page';
        }
      }
      notifyListeners();
      return;
    }
    running = true;
    notifyListeners();
    for (final item in items) {
      if (item.status != JobStatus.queued) continue;
      item.plan ??= planFor(item.inputPath, s);
      final plan = item.plan!;
      final dir = p.dirname(item.inputPath);
      final base = p.basenameWithoutExtension(item.inputPath);
      var out = p.join(dir, '$base.${plan.targetFormat}');
      var n = 1;
      while (File(out).existsSync() || out == item.inputPath) {
        out = p.join(dir, '$base (converted${n > 1 ? ' $n' : ''}).${plan.targetFormat}');
        n++;
      }
      item.status = JobStatus.running;
      item.statusLine = 'Converting…';
      notifyListeners();
      try {
        final r = await Process.run(
            magick, [item.inputPath, ...plan.args, out]);
        if (r.exitCode == 0) {
          item.status = JobStatus.done;
          item.outputPath = out;
          final size = await File(out).length();
          final inSize = await File(item.inputPath).length();
          final delta = inSize > 0 ? (size / inSize * 100).round() : 100;
          item.statusLine = '→ ${p.basename(out)} ($delta% of original size)';
        } else {
          item.status = JobStatus.failed;
          item.statusLine = (r.stderr as String).trim().split('\n').first;
        }
      } catch (e) {
        item.status = JobStatus.failed;
        item.statusLine = '$e';
      }
      notifyListeners();
    }
    running = false;
    notifyListeners();
  }
}
