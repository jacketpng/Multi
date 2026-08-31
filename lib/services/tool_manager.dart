import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive_io.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../models/tool.dart';
import '../util/platform.dart';

class ReleaseInfo {
  final String tag;

  /// Change marker used for update comparison. Equals [tag] for versioned
  /// releases; for rolling releases (BtbN 'latest') it is the asset's
  /// updated_at timestamp.
  final String marker;
  final String downloadUrl;

  ReleaseInfo(
      {required this.tag, required this.marker, required this.downloadUrl});
}

/// Downloads, installs, updates, and locates the bundled CLI tools.
///
/// Layout: `<app support>/tools/<tool>/<exe>`, plus tools/manifest.json
/// recording what is installed. If a managed copy is unavailable the
/// manager falls back to a system copy found on PATH.
class ToolManager extends ChangeNotifier {
  final Map<ToolId, ToolStatus> _status = {
    for (final t in ToolId.values) t: const ToolStatus(),
  };
  final Map<ToolId, String> _exePaths = {};
  final Map<ToolId, Map<String, String>> _extraPaths = {};
  Map<String, dynamic> _manifest = {};
  late final Directory _toolsDir;
  bool _initialized = false;
  bool _checking = false;

  bool get initialized => _initialized;
  bool get checking => _checking;

  /// True once first-run setup has settled: every tool has been checked
  /// and is either usable or known to be unavailable here. The
  /// onboarding screen waits on this.
  bool get setupComplete {
    if (!_initialized || _checking) return false;
    return ToolId.values.every((id) => switch (_status[id]!.kind) {
          ToolStatusKind.unknown ||
          ToolStatusKind.checking ||
          ToolStatusKind.downloading ||
          ToolStatusKind.installing =>
            false,
          _ => true,
        });
  }

  /// Tools that are usable right now.
  int get readyCount => ToolId.values
      .where((id) => _exePaths[id] != null)
      .length;

  /// Whether anything is missing or errored after setup.
  bool get hasProblems => ToolId.values.any((id) =>
      _status[id]!.kind == ToolStatusKind.missing ||
      _status[id]!.kind == ToolStatusKind.error);
  ToolStatus statusOf(ToolId id) => _status[id]!;
  String? pathFor(ToolId id) => _exePaths[id];
  Directory get toolsDir => _toolsDir;

  /// ffprobe ships alongside ffmpeg.
  String? get ffprobePath =>
      _extraPaths[ToolId.ffmpeg]?['ffprobe${PlatformUtil.exeSuffix}'] ??
      _extraPaths[ToolId.ffmpeg]?['ffprobe'] ??
      _sibling(ToolId.ffmpeg, 'ffprobe');

  String? _sibling(ToolId id, String name) {
    final exe = _exePaths[id];
    if (exe == null) return null;
    final candidate = p.join(p.dirname(exe), '$name${PlatformUtil.exeSuffix}');
    return File(candidate).existsSync() ? candidate : null;
  }

  File get _manifestFile => File(p.join(_toolsDir.path, 'manifest.json'));

  Future<void> init({bool checkForUpdates = true}) async {
    final support = await getApplicationSupportDirectory();
    _toolsDir = Directory(p.join(support.path, 'tools'));
    await _toolsDir.create(recursive: true);
    if (await _manifestFile.exists()) {
      try {
        _manifest =
            jsonDecode(await _manifestFile.readAsString()) as Map<String, dynamic>;
      } catch (_) {
        _manifest = {};
      }
    }
    // Resolve whatever is already installed so the app is usable
    // immediately; update checks then run in the background.
    for (final spec in toolSpecs) {
      await _resolveExisting(spec);
    }
    _initialized = true;
    notifyListeners();
    if (checkForUpdates) unawaited(checkAndUpdateAll());
  }

  Future<void> _resolveExisting(ToolSpec spec) async {
    final entry = _manifest[spec.id.key] as Map<String, dynamic>?;
    if (entry != null) {
      final exe = entry['exe'] as String?;
      if (exe != null && await File(exe).exists()) {
        _exePaths[spec.id] = exe;
        _extraPaths[spec.id] = {
          for (final e in ((entry['extras'] as Map<String, dynamic>?) ?? {}).entries)
            e.key: e.value as String
        };
        _set(
            spec.id,
            ToolStatus(
              kind: ToolStatusKind.ready,
              installedVersion: entry['version'] as String?,
              installedTag: entry['marker'] as String?,
            ));
        return;
      }
    }
    // PATH fallback.
    final sys = await PlatformUtil.which(spec.exeName);
    if (sys != null) {
      _exePaths[spec.id] = sys;
      final v = await _probeVersion(spec, sys);
      _set(
          spec.id,
          ToolStatus(
              kind: ToolStatusKind.usingSystem,
              installedVersion: v,
              message: 'Using system copy at $sys'));
    } else {
      _set(spec.id, const ToolStatus(kind: ToolStatusKind.missing));
    }
  }

  Future<String?> _probeVersion(ToolSpec spec, String exe) async {
    try {
      final r = await Process.run(exe, spec.versionArgs)
          .timeout(const Duration(seconds: 15));
      final out = '${r.stdout}\n${r.stderr}';
      return spec.versionPattern.firstMatch(out)?.group(1);
    } catch (_) {
      return null;
    }
  }

  /// Launch-time update pass: check every tool, install what's missing,
  /// update what's stale. Failures are per-tool and non-fatal.
  Future<void> checkAndUpdateAll() async {
    if (_checking) return;
    _checking = true;
    notifyListeners();
    await Future.wait(toolSpecs.map(_checkAndUpdate));
    _checking = false;
    notifyListeners();
  }

  Future<void> updateOne(ToolId id) =>
      _checkAndUpdate(toolSpecs.firstWhere((s) => s.id == id));

  /// Path to Homebrew, if it is installed.
  static Future<String?> homebrewPath() async {
    if (!Platform.isMacOS && !Platform.isLinux) return null;
    for (final candidate in [
      '/opt/homebrew/bin/brew', // Apple Silicon
      '/usr/local/bin/brew', // Intel
      '/home/linuxbrew/.linuxbrew/bin/brew',
    ]) {
      if (await File(candidate).exists()) return candidate;
    }
    return PlatformUtil.which('brew');
  }

  /// Install a tool through Homebrew, for the platforms where nobody
  /// ships a portable binary Multi could fetch itself (aria2 and
  /// ImageMagick on macOS). Saves the user a trip to the terminal.
  Future<void> installWithHomebrew(ToolId id) async {
    final spec = toolSpecs.firstWhere((s) => s.id == id);
    final formula = spec.brewFormula;
    if (formula == null) return;
    final brew = await homebrewPath();
    if (brew == null) {
      _set(
          spec.id,
          _status[id]!.copyWith(
              kind: ToolStatusKind.missing,
              message: 'Homebrew is not installed — see brew.sh'));
      return;
    }
    _set(
        spec.id,
        _status[id]!.copyWith(
            kind: ToolStatusKind.installing,
            message: 'Installing $formula with Homebrew — this can take '
                'a few minutes'));
    try {
      final r = await Process.run(brew, ['install', formula])
          .timeout(const Duration(minutes: 20));
      if (r.exitCode != 0) {
        throw (r.stderr as String).trim().split('\n').last;
      }
    } catch (e) {
      _set(
          spec.id,
          _status[id]!.copyWith(
              kind: ToolStatusKind.error, message: 'brew install failed: $e'));
      return;
    }
    await _resolveExisting(spec);
  }

  Future<void> _checkAndUpdate(ToolSpec spec) async {
    final source = spec.sourceForThisPlatform;
    final current = _status[spec.id]!;
    if (source == null) {
      // No bundled build for this platform: keep the PATH copy if any.
      if (_exePaths[spec.id] == null) {
        _set(
            spec.id,
            ToolStatus(
                kind: ToolStatusKind.missing,
                message: spec.unavailableHint ??
                    'No build available for this platform'));
      }
      return;
    }
    _set(spec.id, current.copyWith(kind: ToolStatusKind.checking));
    ReleaseInfo release;
    try {
      release = await _latestRelease(source);
    } catch (e) {
      // Offline or rate-limited: keep whatever works.
      final k = _exePaths[spec.id] != null
          ? (_isManaged(spec.id) ? ToolStatusKind.ready : ToolStatusKind.usingSystem)
          : ToolStatusKind.error;
      _set(spec.id,
          current.copyWith(kind: k, message: 'Update check failed: $e'));
      return;
    }

    final installedMarker =
        (_manifest[spec.id.key] as Map<String, dynamic>?)?['marker'] as String?;
    if (installedMarker == release.marker && _isManaged(spec.id)) {
      _set(
          spec.id,
          current.copyWith(
              kind: ToolStatusKind.ready, latestTag: release.tag));
      return;
    }

    try {
      await _install(spec, source, release);
    } catch (e) {
      final k = _exePaths[spec.id] != null
          ? (_isManaged(spec.id) ? ToolStatusKind.ready : ToolStatusKind.usingSystem)
          : ToolStatusKind.error;
      _set(spec.id, current.copyWith(kind: k, message: 'Install failed: $e'));
    }
  }

  bool _isManaged(ToolId id) {
    final exe = _exePaths[id];
    return exe != null && p.isWithin(_toolsDir.path, exe);
  }

  Future<ReleaseInfo> _latestRelease(InstallSource source) async {
    if (source.githubRepo == null) {
      // Non-GitHub source (evermeet ffmpeg for macOS).
      final info = await http
          .get(Uri.parse('https://evermeet.cx/ffmpeg/info/ffmpeg/release'))
          .timeout(const Duration(seconds: 20));
      final j = jsonDecode(info.body) as Map<String, dynamic>;
      return ReleaseInfo(
          tag: j['version'] as String,
          marker: j['version'] as String,
          downloadUrl: source.latestUrl!);
    }
    final endpoint = source.releaseTag == 'latest'
        ? 'https://api.github.com/repos/${source.githubRepo}/releases/latest'
        : 'https://api.github.com/repos/${source.githubRepo}/releases/tags/${source.releaseTag}';
    final r = await http.get(Uri.parse(endpoint), headers: {
      'Accept': 'application/vnd.github+json',
      'User-Agent': 'multi-app'
    }).timeout(const Duration(seconds: 20));
    if (r.statusCode != 200) {
      throw 'GitHub API ${r.statusCode}';
    }
    final j = jsonDecode(r.body) as Map<String, dynamic>;
    final tag = j['tag_name'] as String;
    final cleanTag = tag.replaceFirst(RegExp(r'^(v|release-)'), '');
    final wantName = source.assetName!.replaceAll('{tag}', cleanTag);
    final assets = (j['assets'] as List).cast<Map<String, dynamic>>();
    final asset = assets.firstWhere((a) => a['name'] == wantName,
        orElse: () => throw 'Asset $wantName not found in $tag');
    // Rolling releases keep the same tag; the asset timestamp is the
    // real change marker there.
    final marker = source.releaseTag == 'latest' && tag == 'latest'
        ? '$tag@${asset['updated_at']}'
        : tag;
    return ReleaseInfo(
        tag: tag,
        marker: marker,
        downloadUrl: asset['browser_download_url'] as String);
  }

  Future<void> _install(
      ToolSpec spec, InstallSource source, ReleaseInfo release) async {
    final dir = Directory(p.join(_toolsDir.path, spec.exeName));
    final cleanTag = release.tag.replaceFirst(RegExp(r'^(v|release-)'), '');

    _set(
        spec.id,
        _status[spec.id]!.copyWith(
            kind: ToolStatusKind.downloading,
            latestTag: release.tag,
            progress: 0));
    final payload = await _download(release.downloadUrl, (p) {
      _set(spec.id,
          _status[spec.id]!.copyWith(kind: ToolStatusKind.downloading, progress: p));
    });

    _set(spec.id, _status[spec.id]!.copyWith(kind: ToolStatusKind.installing));
    // Install into a fresh directory, then swap.
    final staging = Directory('${dir.path}.new');
    if (await staging.exists()) await staging.delete(recursive: true);
    await staging.create(recursive: true);

    final exeName = '${spec.exeName}${PlatformUtil.exeSuffix}';
    final extras = <String, String>{};
    String exePath;
    switch (source.archive) {
      case ArchiveKind.none:
        exePath = p.join(staging.path, exeName);
        await File(exePath).writeAsBytes(payload);
        break;
      case ArchiveKind.zip:
        final archive = ZipDecoder().decodeBytes(payload);
        String? findAndWrite(String innerTemplate, String outName) {
          final inner = innerTemplate.replaceAll('{tag}', cleanTag);
          final f = archive.files.where((f) =>
              f.isFile && (f.name == inner || p.basename(f.name) == inner));
          if (f.isEmpty) return null;
          final out = p.join(staging.path, outName);
          File(out)
            ..createSync(recursive: true)
            ..writeAsBytesSync(f.first.content as List<int>);
          return out;
        }

        exePath = findAndWrite(source.innerPath ?? exeName, exeName) ??
            (throw 'Executable ${source.innerPath} not found in archive');
        for (final e in source.extraInner.entries) {
          final path = findAndWrite(e.value, p.basename(e.value));
          if (path != null) extras[p.basename(e.value)] = path;
        }
        break;
      case ArchiveKind.tarXz:
      case ArchiveKind.sevenZip:
        // Every desktop OS ships a capable tar: GNU tar on Linux,
        // bsdtar on macOS and Windows 10+ (which also reads 7z). Much
        // faster and lighter than decoding these archives in Dart.
        final ext = source.archive == ArchiveKind.sevenZip ? '7z' : 'tar.xz';
        final archiveFile = File(p.join(staging.path, 'pkg.$ext'));
        await archiveFile.writeAsBytes(payload);
        final r = await Process.run(
            'tar', ['-xf', archiveFile.path, '-C', staging.path]);
        if (r.exitCode != 0) throw 'tar extraction failed: ${r.stderr}';
        await archiveFile.delete();

        Future<String?> find(String innerTemplate) async {
          final inner = innerTemplate.replaceAll('{tag}', cleanTag);
          final exact = File(p.join(staging.path, inner));
          if (await exact.exists()) return exact.path;
          final found = await staging
              .list(recursive: true)
              .where((e) =>
                  e is File && p.basename(e.path) == p.basename(inner))
              .cast<File>()
              .toList();
          return found.isEmpty ? null : found.first.path;
        }

        exePath = await find(source.innerPath ?? exeName) ??
            (throw 'Executable ${source.innerPath} not found in archive');
        for (final e in source.extraInner.entries) {
          final path = await find(e.value);
          if (path != null) extras[p.basename(e.value)] = path;
        }
        break;
      case ArchiveKind.appImage:
        // Extract the AppImage so it runs without FUSE.
        final img = File(p.join(staging.path, 'tool.AppImage'));
        await img.writeAsBytes(payload);
        await Process.run('chmod', ['+x', img.path]);
        final r = await Process.run(img.path, ['--appimage-extract'],
            workingDirectory: staging.path);
        if (r.exitCode != 0) throw 'AppImage extraction failed: ${r.stderr}';
        await img.delete();
        exePath = p.join(staging.path, 'squashfs-root', 'AppRun');
        if (!await File(exePath).exists()) {
          throw 'AppRun missing after AppImage extraction';
        }
        break;
    }

    // macOS ffmpeg from evermeet ships ffprobe as a separate zip.
    if (spec.id == ToolId.ffmpeg && Platform.isMacOS && source.githubRepo == null) {
      final probeBytes = await _download(
          'https://evermeet.cx/ffmpeg/getrelease/ffprobe/zip', (_) {});
      final probeArchive = ZipDecoder().decodeBytes(probeBytes);
      final f = probeArchive.files.firstWhere(
          (f) => f.isFile && p.basename(f.name) == 'ffprobe',
          orElse: () => throw 'ffprobe not in evermeet zip');
      final out = p.join(staging.path, 'ffprobe');
      File(out).writeAsBytesSync(f.content as List<int>);
      extras['ffprobe'] = out;
    }

    if (!Platform.isWindows) {
      for (final path in [exePath, ...extras.values]) {
        await Process.run('chmod', ['+x', path]);
        if (Platform.isMacOS) {
          // Anything downloaded carries com.apple.quarantine, and
          // Gatekeeper refuses to execute a quarantined unsigned binary
          // ("cannot be opened because the developer cannot be
          // verified"). Clearing it is what lets a freshly fetched tool
          // run without the user being sent to System Settings.
          await Process.run('xattr', ['-d', 'com.apple.quarantine', path])
              .catchError((_) => ProcessResult(0, 0, '', ''));
        }
      }
    }

    // Swap staging into place.
    if (await dir.exists()) await dir.delete(recursive: true);
    await staging.rename(dir.path);
    String rebase(String path) =>
        p.join(dir.path, p.relative(path, from: staging.path));
    exePath = rebase(exePath);
    extras.updateAll((k, v) => rebase(v));

    _exePaths[spec.id] = exePath;
    _extraPaths[spec.id] = extras;
    final version = await _probeVersion(spec, exePath);

    _manifest[spec.id.key] = {
      'marker': release.marker,
      'tag': release.tag,
      'version': version,
      'exe': exePath,
      'extras': extras,
    };
    await _manifestFile.writeAsString(jsonEncode(_manifest));
    _set(
        spec.id,
        ToolStatus(
          kind: ToolStatusKind.ready,
          installedVersion: version,
          installedTag: release.marker,
          latestTag: release.tag,
        ));
  }

  Future<List<int>> _download(
      String url, void Function(double?) onProgress) async {
    final client = http.Client();
    try {
      final req = http.Request('GET', Uri.parse(url))
        ..headers['User-Agent'] = 'multi-app'
        ..followRedirects = true;
      final resp = await client.send(req).timeout(const Duration(minutes: 2));
      if (resp.statusCode != 200) throw 'HTTP ${resp.statusCode} for $url';
      final total = resp.contentLength;
      final bytes = BytesBuilder(copy: false);
      await for (final chunk in resp.stream) {
        bytes.add(chunk);
        onProgress(total != null && total > 0 ? bytes.length / total : null);
      }
      return bytes.takeBytes();
    } finally {
      client.close();
    }
  }

  void _set(ToolId id, ToolStatus s) {
    _status[id] = s;
    notifyListeners();
  }
}
