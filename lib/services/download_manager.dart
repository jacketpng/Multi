import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/download.dart';
import '../models/tool.dart';
import 'browser_profiles.dart';
import 'engine_options.dart';
import 'link_scraper.dart';
import 'presets.dart';
import 'tool_manager.dart';
import 'url_router.dart';

/// Splits a shell-style argument string, respecting single/double quotes.
List<String> splitExtraArgs(String s) {
  final out = <String>[];
  final cur = StringBuffer();
  String? quote;
  for (final ch in s.split('')) {
    if (quote != null) {
      if (ch == quote) {
        quote = null;
      } else {
        cur.write(ch);
      }
    } else if (ch == '"' || ch == "'") {
      quote = ch;
    } else if (ch == ' ' || ch == '\t' || ch == '\n') {
      if (cur.isNotEmpty) {
        out.add(cur.toString());
        cur.clear();
      }
    } else {
      cur.write(ch);
    }
  }
  if (cur.isNotEmpty) out.add(cur.toString());
  return out;
}

class DownloadManager extends ChangeNotifier {
  final ToolManager tools;
  late final UrlRouter router = UrlRouter(tools);
  final LinkScraper scraper = LinkScraper();

  final List<DownloadTask> tasks = [];
  final Map<int, List<ScrapedLink>> scrapedLinks = {};
  int _nextId = 1;
  int maxConcurrent = 3;
  String? downloadDir;
  SharedPreferences? _prefs;

  /// Hook wired in main.dart: called with the media files a finished
  /// task produced when the user asked for convert-after-download.
  void Function(List<String> files, String targetContainerId)?
      onConvertRequested;

  DownloadManager(this.tools);

  Future<void> init() async {
    _prefs = await SharedPreferences.getInstance();
    maxConcurrent = _prefs?.getInt('maxConcurrent') ?? 3;
    librewolfManualPath = _prefs?.getString('librewolfProfilePath');
    final savedCookies = _prefs?.getString('defaultCookieSource');
    if (savedCookies != null) {
      defaultCookieSource = CookieSource.values.firstWhere(
          (c) => c.name == savedCookies,
          orElse: () => CookieSource.none);
    }
    downloadDir = _prefs?.getString('downloadDir');
    if (downloadDir == null) {
      final dl = await getDownloadsDirectory();
      downloadDir = p.join(
          dl?.path ?? p.join(Platform.environment['HOME'] ?? '.', 'Downloads'),
          'Multi');
    }
    notifyListeners();
  }

  /// Lets widgets that mutate task options in place request a rebuild.
  void touch() => notifyListeners();

  void setDownloadDir(String dir) {
    downloadDir = dir;
    _prefs?.setString('downloadDir', dir);
    notifyListeners();
  }

  /// Pull every link out of a block of text.
  ///
  /// Copying a few links at once usually means copying whatever was
  /// around them too — newlines, commas, quotes, a trailing full stop.
  /// This finds the URLs in all of that, in the order they appear, and
  /// drops repeats.
  static List<String> extractUrls(String text) {
    final found = <String>[];
    final seen = <String>{};
    final re = RegExp(r'''(?:https?://|magnet:\?)[^\s'"<>\)\]\}\\]+''');
    for (final m in re.allMatches(text)) {
      var url = m.group(0)!;
      // Trailing punctuation belongs to the sentence, not the link.
      while (url.isNotEmpty && '.,;:!?'.contains(url[url.length - 1])) {
        url = url.substring(0, url.length - 1);
      }
      if (url.length < 12) continue;
      if (seen.add(url)) found.add(url);
    }
    return found;
  }

  /// Add everything in a pasted block, one task per link.
  ///
  /// Returns how many were added. Falls back to treating the whole
  /// string as one link when no URL pattern matches, so nothing typed
  /// by hand is silently swallowed.
  Future<int> addUrls(String text) async {
    final urls = extractUrls(text);
    if (urls.isEmpty) {
      final single = text.trim();
      if (single.isEmpty) return 0;
      await addUrl(single);
      return 1;
    }
    // Add them all before resolving, so the list fills in at once and
    // the analyses run one after another rather than all at the host.
    for (final url in urls) {
      await addUrl(url);
    }
    return urls.length;
  }

  /// Tasks that have been analysed and are waiting on a Start press.
  int get readyCount =>
      tasks.where((t) => t.status == TaskStatus.ready).length;

  /// Start every task that is ready to go. Anything still waiting on a
  /// cookie choice, an engine choice or a file selection is left alone
  /// — those need an answer, and Multi does not answer for the user.
  int startAll() {
    var started = 0;
    // Oldest first, so the queue runs in the order they were added.
    for (final task in tasks.reversed.toList()) {
      if (task.status != TaskStatus.ready) continue;
      task.status = TaskStatus.queued;
      task.statusLine = 'Queued…';
      started++;
    }
    if (started > 0) {
      notifyListeners();
      _pump();
    }
    return started;
  }

  /// Entry point for the URL bar: route the URL, fetch preview info
  /// (formats, sizes, samples), then wait for the user to press Start.
  Future<void> addUrl(String url) async {

    url = url.trim();
    if (url.isEmpty) return;
    final host = Uri.tryParse(url)?.host ?? '';
    final options = DownloadOptions(
      preset: Presets.recommendedFor(host),
      outputDir: downloadDir,
      cookieSource: defaultCookieSource,
    );
    final task = DownloadTask(
        id: _nextId++, url: url, engine: Engine.ytDlp, options: options);
    tasks.insert(0, task);

    // Sites like Instagram refuse to show anything to a logged-out
    // visitor, so previewing first would just fail (and announce us as
    // a scraper). Stop and let the user pick cookies before Multi makes
    // any request at all.
    if (Presets.cookiesRecommendedFor(host) &&
        options.cookieSource == CookieSource.none) {
      task.status = TaskStatus.needsCookies;
      task.statusLine =
          '$host only shows content to logged-in visitors — choose cookies '
          'before Multi looks at the page';
      notifyListeners();
      return;
    }

    task.status = TaskStatus.resolving;
    task.statusLine = 'Deciding how to download…';
    notifyListeners();
    await _resolveAndPreview(task);
  }

  /// Continue a task that was waiting on a cookie choice.
  Future<void> continueAfterCookies(DownloadTask task) async {
    if (task.status != TaskStatus.needsCookies) return;
    task.status = TaskStatus.resolving;
    task.statusLine = 'Deciding how to download…';
    notifyListeners();
    await _resolveAndPreview(task);
  }

  Future<void> _resolveAndPreview(DownloadTask task) async {
    final url = task.url;
    RouteDecision decision;
    try {
      decision = await router.route(url, onStatus: (s) {
        task.statusLine = s;
        notifyListeners();
      });
    } catch (e) {
      task.status = TaskStatus.failed;
      task.statusLine = 'Could not analyze URL: $e';
      notifyListeners();
      return;
    }
    if (task.status == TaskStatus.canceled) return;

    if (decision.kind == RouteKind.unsupported) {
      // Nothing claims it and it isn't a file: don't guess an engine.
      task.status = TaskStatus.needsEngine;
      task.statusLine = decision.reason;
      notifyListeners();
      return;
    }

    task.engine = decision.engine!;
    task.statusLine = decision.reason;
    notifyListeners();
    await _fetchPreview(task);
    if (task.status == TaskStatus.canceled) return;
    task.status = TaskStatus.ready;
    notifyListeners();
  }

  /// Fetch formats / samples / file info so the user can pick before
  /// anything downloads.
  Future<void> _fetchPreview(DownloadTask task) async {
    switch (task.engine) {
      case Engine.ytDlp:
        task.statusLine = 'Fetching available formats…';
        notifyListeners();
        try {
          task.preview = await _ytDlpPreview(task);
          final f = task.preview!.formats.length;
          task.statusLine = f > 0
              ? '$f formats available — pick one, or use Best'
              : 'Ready';
        } catch (e) {
          task.statusLine =
              'Could not fetch format list ($e) — Best will be used';
        }
        break;
      case Engine.galleryDl:
        // Previewing means a full extra enumeration pass. On sites that
        // gate content behind a login it fails outright and doubles the
        // request load on exactly the hosts most likely to rate-limit,
        // so skip it there and go straight to ready.
        final host = Uri.tryParse(task.url)?.host ?? '';
        if (Presets.cookiesRecommendedFor(host)) {
          task.statusLine =
              'Ready — $host is not previewed, so nothing is requested until you press Start';
          break;
        }
        task.statusLine = 'Peeking at the gallery…';
        notifyListeners();
        try {
          task.preview = await _galleryPreview(task);
          final n = task.preview!.sampleItems.length;
          task.statusLine = n > 0
              ? 'Gallery reachable — sample of $n items below'
              : 'Ready';
        } catch (e) {
          task.statusLine = 'Could not preview gallery ($e)';
        }
        break;
      case Engine.aria2:
        task.statusLine = 'Asking the server about the file…';
        notifyListeners();
        try {
          task.preview = await _directPreview(task.url);
          final pv = task.preview!;
          task.statusLine = [
            if (pv.fileName != null) pv.fileName!,
            if (pv.fileSize != null) _human(pv.fileSize!),
            if (pv.contentType != null) pv.contentType!,
          ].join(' · ');
          if (task.statusLine.isEmpty) task.statusLine = 'Ready';
        } catch (_) {
          task.statusLine = 'Server gave no file info — ready to download';
        }
        break;
    }
  }

  Future<MediaPreview> _ytDlpPreview(DownloadTask task) async {
    final exe = tools.pathFor(ToolId.ytDlp);
    if (exe == null) throw 'yt-dlp not installed';
    final r = await Process.run(exe, [
      '-J',
      '--no-warnings',
      '--playlist-items', '1',
      ..._cookieArgs(task, browserSupported: true),
      task.url,
    ]).timeout(const Duration(seconds: 90));
    if (r.exitCode != 0) {
      final err = (r.stderr as String).trim().split('\n').lastOrNull ?? '';
      throw err.replaceFirst(RegExp(r'^ERROR:\s*'), '');
    }
    var j = jsonDecode(r.stdout as String) as Map<String, dynamic>;
    final preview = MediaPreview();
    if (j['_type'] == 'playlist') {
      preview.playlistCount =
          (j['playlist_count'] ?? j['n_entries'] ?? j['entries']?.length) as int?;
      final entries = (j['entries'] as List?) ?? [];
      if (entries.isEmpty) throw 'Empty playlist';
      preview.title = j['title'] as String?;
      j = entries.first as Map<String, dynamic>;
      preview.title ??= j['title'] as String?;
    } else {
      preview.title = j['title'] as String?;
    }
    preview.uploader = (j['uploader'] ?? j['channel']) as String?;
    preview.thumbnailUrl = j['thumbnail'] as String?;
    preview.durationSeconds = (j['duration'] as num?)?.toDouble();
    final dur = preview.durationSeconds;
    for (final f in ((j['formats'] as List?) ?? []).cast<Map<String, dynamic>>()) {
      final proto = (f['protocol'] as String?) ?? '';
      if (proto.startsWith('mhtml')) continue; // storyboard images
      final tbr = (f['tbr'] as num?)?.toDouble();
      var size = (f['filesize'] as num?)?.toInt();
      var estimated = false;
      if (size == null) {
        size = (f['filesize_approx'] as num?)?.toInt();
        estimated = size != null;
      }
      if (size == null && tbr != null && dur != null) {
        size = (tbr * 1000 / 8 * dur).round();
        estimated = true;
      }
      preview.formats.add(MediaFormat(
        id: f['format_id'] as String,
        ext: (f['ext'] as String?) ?? '',
        vcodec: (f['vcodec'] as String?) ?? 'none',
        acodec: (f['acodec'] as String?) ?? 'none',
        width: (f['width'] as num?)?.toInt(),
        height: (f['height'] as num?)?.toInt(),
        fps: (f['fps'] as num?)?.toDouble(),
        tbr: tbr,
        filesize: size,
        sizeIsEstimate: estimated,
        note: (f['format_note'] as String?) ?? '',
        language: f['language'] as String?,
      ));
    }
    // Best-looking formats last in yt-dlp order; show best first.
    preview.formats = preview.formats.reversed.toList();
    task.title = preview.title;
    return preview;
  }

  Future<MediaPreview> _galleryPreview(DownloadTask task) async {
    final exe = tools.pathFor(ToolId.galleryDl);
    if (exe == null) throw 'gallery-dl not installed';
    final r = await Process.run(exe, [
      '--simulate',
      '--range', '1-8',
      ..._cookieArgs(task, browserSupported: true),
      task.url,
    ]).timeout(const Duration(seconds: 60));
    if (r.exitCode != 0) throw 'gallery-dl could not read the page';
    final preview = MediaPreview();
    preview.sampleItems = (r.stdout as String)
        .split('\n')
        .map((l) => l.trim().replaceFirst(RegExp(r'^#\s*'), ''))
        .where((l) => l.isNotEmpty)
        .map(p.basename)
        .toList();
    return preview;
  }

  Future<MediaPreview> _directPreview(String url) async {
    final preview = MediaPreview();
    if (url.startsWith('magnet:')) {
      preview.fileName = 'Magnet link (BitTorrent)';
      return preview;
    }
    final resp = await http.head(Uri.parse(url), headers: {
      'User-Agent': 'Mozilla/5.0 (X11; Linux x86_64; rv:141.0) Gecko/20100101 Firefox/141.0',
    }).timeout(const Duration(seconds: 20));
    final disposition = resp.headers['content-disposition'];
    final m = disposition == null
        ? null
        : RegExp('filename\\*?=(?:UTF-8\'\')?"?([^";]+)')
            .firstMatch(disposition);
    preview.fileName = m?.group(1) ??
        p.basename(Uri.parse(url).path.isEmpty ? url : Uri.parse(url).path);
    preview.fileSize = int.tryParse(resp.headers['content-length'] ?? '');
    preview.contentType = resp.headers['content-type']?.split(';').first;
    return preview;
  }

  /// Scan a page for file links and offer them as an aria2 checklist.
  /// Only ever run at the user's request — never as a silent fallback.
  Future<void> scanPageForFiles(DownloadTask task) async {
    task.status = TaskStatus.resolving;
    task.statusLine = 'Collecting file links from the page…';
    notifyListeners();
    try {
      final links = await scraper.scrape(task.url);
      if (links.isEmpty) {
        task.status = TaskStatus.needsEngine;
        task.statusLine = 'No links to actual files were found on that page.';
        notifyListeners();
        return;
      }
      scrapedLinks[task.id] = links;
      task.engine = Engine.aria2;
      task.status = TaskStatus.awaitingChoice;
      task.statusLine =
          '${links.length} file links found — choose which to download';
    } catch (e) {
      task.status = TaskStatus.needsEngine;
      task.statusLine = 'Link scan failed: $e';
    }
    notifyListeners();
  }

  /// Force a specific engine, overriding the automatic decision.
  Future<void> useEngine(DownloadTask task, Engine engine) async {
    task.engine = engine;
    task.preview = null;
    task.chosenFormat = null;
    task.chosenFormatLabel = null;
    task.status = TaskStatus.resolving;
    task.statusLine = 'Using ${engine.displayName}…';
    notifyListeners();
    await _fetchPreview(task);
    if (task.status == TaskStatus.canceled) return;
    task.status = TaskStatus.ready;
    notifyListeners();
  }

  /// Called by the link picker with the user's selection.
  void startScrapedTask(DownloadTask task) {
    final links = scrapedLinks[task.id] ?? [];
    final chosen = links.where((l) => l.selected).map((l) => l.url).toList();
    if (chosen.isEmpty) return;
    task.directUrls = chosen;
    task.status = TaskStatus.queued;
    task.statusLine = '${chosen.length} files queued for aria2';
    notifyListeners();
    _pump();
  }

  void startTask(DownloadTask task) {
    if (task.status != TaskStatus.ready) return;
    task.status = TaskStatus.queued;
    task.statusLine = 'Queued…';
    notifyListeners();
    _pump();
  }

  void cancelTask(DownloadTask task) {
    if (task.status == TaskStatus.running) {
      for (final proc in task.processes) {
        proc.kill();
      }
      task.process?.kill();
      task.status = TaskStatus.canceled;
      task.statusLine = 'Canceled';
    } else if (task.status != TaskStatus.done &&
        task.status != TaskStatus.failed) {
      task.status = TaskStatus.canceled;
      task.statusLine = 'Canceled';
    }
    notifyListeners();
  }

  void removeTask(DownloadTask task) {
    if (task.status == TaskStatus.running) cancelTask(task);
    tasks.remove(task);
    scrapedLinks.remove(task.id);
    notifyListeners();
  }

  void retryTask(DownloadTask task) {
    if (task.status != TaskStatus.failed && task.status != TaskStatus.canceled) {
      return;
    }
    task.progress = null;
    task.filesDone = 0;
    task.log.clear();
    task.outputFiles.clear();
    task.parts.clear();
    task.partsTotal = null;
    task.lastItemNum = null;
    task.multiplePosts = false;
    task.status = TaskStatus.queued;
    task.statusLine = 'Retrying…';
    notifyListeners();
    _pump();
  }

  int get _runningCount =>
      tasks.where((t) => t.status == TaskStatus.running).length;

  void _pump() {
    for (final t in tasks.reversed) {
      if (_runningCount >= maxConcurrent) break;
      if (t.status == TaskStatus.queued) {
        unawaited(_run(t));
      }
    }
  }

  ToolId _toolFor(Engine e) => switch (e) {
        Engine.ytDlp => ToolId.ytDlp,
        Engine.galleryDl => ToolId.galleryDl,
        Engine.aria2 => ToolId.aria2,
      };

  /// Most items downloaded at the same time by one task. Configurable
  /// on the Settings page.
  static const defaultMaxParallelItems = 5;
  int maxParallelItems = defaultMaxParallelItems;

  /// How many parallel worker processes the Speed preset should split
  /// this task into. Neither yt-dlp nor gallery-dl downloads multiple
  /// items concurrently on its own, but both support interleaved slice
  /// ranges (yt-dlp `-I k::n`, gallery-dl `--range k::n`), so worker k
  /// of n takes every n-th item — n workers means n items in flight.
  /// Sharding is skipped when the user set their own item range, or
  /// uses a download archive (concurrent writes to one archive file are
  /// not safe).
  @visibleForTesting
  int shardCountFor(DownloadTask task) {
    if (task.options.preset != PresetId.speed) return 1;
    String optValue(String id) =>
        ((task.options.values[id] as String?) ?? '').trim();
    final extra = task.options.extraArgs;
    switch (task.engine) {
      case Engine.ytDlp:
        final count = task.preview?.playlistCount ?? 0;
        if (count < 2) return 1; // single video: nothing to split
        if (optValue('playlistItems').isNotEmpty ||
            optValue('archive').isNotEmpty ||
            optValue('maxDownloads').isNotEmpty) {
          return 1;
        }
        if (extra.contains('--playlist-items') ||
            RegExp(r'(^|\s)-I(\s|$)').hasMatch(extra) ||
            extra.contains('--download-archive')) {
          return 1;
        }
        return count.clamp(2, maxParallelItems);
      case Engine.galleryDl:
        // The preview samples up to 8 items; fewer means a small
        // gallery that isn't worth splitting.
        final sampled = task.preview?.sampleItems.length ?? 0;
        if (sampled < 2) return 1;
        if (optValue('range').isNotEmpty || optValue('archive').isNotEmpty) {
          return 1;
        }
        if (extra.contains('--range') ||
            extra.contains('--download-archive')) {
          return 1;
        }
        return sampled.clamp(2, maxParallelItems);
      case Engine.aria2:
        return 1; // aria2 parallelizes on its own
    }
  }

  Future<void> _run(DownloadTask task) async {
    final exe = tools.pathFor(_toolFor(task.engine));
    if (exe == null) {
      task.status = TaskStatus.failed;
      task.statusLine =
          '${task.engine.displayName} is not installed yet — check the Tools page';
      notifyListeners();
      return;
    }
    task.status = TaskStatus.running;
    task.statusLine = 'Starting…';
    // Show a bar per item from the first frame, before any output.
    task.partsTotal ??= switch (task.engine) {
      Engine.ytDlp => task.preview?.playlistCount,
      Engine.aria2 => task.directUrls?.length,
      Engine.galleryDl => null,
    };
    notifyListeners();

    final outDir = task.options.outputDir ?? downloadDir ?? '.';
    await Directory(outDir).create(recursive: true);

    final shards = shardCountFor(task);
    List<List<String>> argSets;
    File? inputFile;
    try {
      switch (task.engine) {
        case Engine.ytDlp:
          argSets = [
            for (var k = 1; k <= shards; k++)
              _ytDlpArgs(task, outDir,
                  shard: shards > 1 ? '$k::$shards' : null),
          ];
          break;
        case Engine.galleryDl:
          argSets = [
            for (var k = 1; k <= shards; k++)
              _galleryDlArgs(task, outDir,
                  shard: shards > 1 ? '$k::$shards' : null),
          ];
          break;
        case Engine.aria2:
          final (args, file) = await _aria2Args(task, outDir);
          argSets = [args];
          inputFile = file;
          break;
      }
    } catch (e) {
      task.status = TaskStatus.failed;
      task.statusLine = '$e';
      notifyListeners();
      return;
    }

    void handleLine(String line) {
      if (line.trim().isEmpty) return;
      task.addLog(line);
      parseProgressLine(task, line);
      notifyListeners();
    }

    if (argSets.length > 1) {
      task.addLog(
          '⇉ Speed preset: splitting into ${argSets.length} parallel ${task.engine.displayName} workers (every ${argSets.length}th item each)');
    }
    task.processes.clear();
    for (final args in argSets) {
      task.addLog('\$ ${p.basename(exe)} ${args.join(' ')}');
      Process proc;
      try {
        proc = await Process.start(exe, args, workingDirectory: outDir);
      } catch (e) {
        for (final started in task.processes) {
          started.kill();
        }
        task.status = TaskStatus.failed;
        task.statusLine = 'Failed to start: $e';
        notifyListeners();
        return;
      }
      task.processes.add(proc);
      proc.stdout
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen(handleLine);
      proc.stderr
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen(handleLine);
    }
    task.process = task.processes.first;

    final codes =
        await Future.wait(task.processes.map((proc) => proc.exitCode));
    await inputFile?.delete().catchError((_) => inputFile!);
    if (task.status == TaskStatus.canceled) {
      notifyListeners();
      _pump();
      return;
    }
    final failures = codes.where((c) => c != 0).length;
    if (failures == 0) {
      task.status = TaskStatus.done;
      task.progress = 1;
      task.statusLine = task.filesDone > 1
          ? 'Done — ${task.filesDone} files'
          : 'Done';
      _maybeConvertAfter(task);
    } else {
      task.status = TaskStatus.failed;
      final lastError = task.log.lastWhere(
          (l) => l.contains('ERROR') || l.toLowerCase().contains('error'),
          orElse: () => 'Exited with code ${codes.firstWhere((c) => c != 0)}');
      task.statusLine = codes.length > 1
          ? '$failures of ${codes.length} workers failed (${task.filesDone} files downloaded) — $lastError'
          : lastError;
      final hint = _loginWallHint(task, lastError);
      if (hint != null) task.statusLine = '${task.statusLine}\n$hint';
    }
    notifyListeners();
    _pump();
  }

  /// Turn a "you are not logged in" style failure into advice. Sites
  /// like Instagram bounce anonymous requests to their home or login
  /// page, often only after the first handful of files.
  @visibleForTesting
  String? loginWallHintFor(DownloadTask task, String error) =>
      _loginWallHint(task, error);

  String? _loginWallHint(DownloadTask task, String error) {
    final e = error.toLowerCase();
    final walled = e.contains('redirect to home page') ||
        e.contains('login required') ||
        e.contains('login_required') ||
        e.contains('rate limit') ||
        e.contains('rate-limit') ||
        e.contains('http error 401') ||
        e.contains('http error 403') ||
        e.contains('http error 429') ||
        e.contains('sign in to confirm');
    if (!walled) return null;
    final host = Uri.tryParse(task.url)?.host ?? 'this site';
    final noCookies = task.options.cookieSource == CookieSource.none;
    final notGentle = task.options.preset != PresetId.gentle;
    return [
      '$host blocked the request',
      if (task.filesDone > 0) ' after ${task.filesDone} files',
      '. ',
      if (noCookies)
        'Set cookies in Options — it only serves logged-in visitors. '
      else
        'Your cookies may have expired — sign in again in your browser. ',
      if (notGentle) 'The “Low profile” preset also helps avoid tripping limits.',
    ].join();
  }

  static const _convertibleExts = {
    'mp4', 'mkv', 'webm', 'avi', 'mov', 'flv', 'ts', 'm2ts', 'wmv', '3gp',
    'mp3', 'm4a', 'flac', 'opus', 'ogg', 'wav', 'aac', 'weba',
  };

  void _maybeConvertAfter(DownloadTask task) {
    final target = task.options.convertTo;
    if (target == null || onConvertRequested == null) return;
    final files = task.outputFiles
        .where((f) => _convertibleExts
            .contains(p.extension(f).replaceFirst('.', '').toLowerCase()))
        .where((f) => File(f).existsSync())
        .toList();
    if (files.isEmpty) {
      task.statusLine = 'Done — nothing convertible for $target';
      return;
    }
    task.statusLine =
        'Done — sending ${files.length == 1 ? p.basename(files.first) : '${files.length} files'} to Convert';
    onConvertRequested!(files, target);
  }

  /// Cached LibreWolf lookup — the filesystem scan shouldn't repeat on
  /// every argument build. Call [rescanBrowserProfiles] to refresh.
  BrowserProfile? _librewolf;
  bool _librewolfScanned = false;

  /// A profile directory the user pasted in. Auto-detection is only a
  /// convenience; when this is set it wins.
  String? librewolfManualPath;

  /// What auto-detection found, if anything (shown as a suggestion).
  BrowserProfile? get librewolfDetected {
    if (!_librewolfScanned) {
      _librewolfScanned = true;
      _librewolf = BrowserProfiles.findLibrewolf();
    }
    return _librewolf;
  }

  /// The profile actually used: the pasted path if valid, else whatever
  /// was detected.
  BrowserProfile? get librewolfProfile =>
      BrowserProfiles.resolveManualPath(librewolfManualPath) ??
      librewolfDetected;

  /// Why a pasted path isn't usable, or null when it is (or is empty).
  String? get librewolfManualPathError {
    final path = librewolfManualPath?.trim();
    if (path == null || path.isEmpty) return null;
    if (!Directory(path).existsSync()) return 'That folder does not exist.';
    if (BrowserProfiles.resolveManualPath(path) == null) {
      return 'No cookies.sqlite or profiles.ini in that folder — paste the '
          'profile\'s Root Directory from about:profiles.';
    }
    return null;
  }

  void setLibrewolfManualPath(String? path) {
    final clean = (path ?? '').trim();
    librewolfManualPath = clean.isEmpty ? null : clean;
    if (librewolfManualPath == null) {
      _prefs?.remove('librewolfProfilePath');
    } else {
      _prefs?.setString('librewolfProfilePath', librewolfManualPath!);
    }
    notifyListeners();
  }

  void rescanBrowserProfiles() {
    _librewolfScanned = false;
    _librewolf = null;
    notifyListeners();
  }

  /// Cookie source applied to new tasks, remembered between runs so the
  /// choice only has to be made once.
  CookieSource defaultCookieSource = CookieSource.none;

  void setDefaultCookieSource(CookieSource source) {
    defaultCookieSource = source;
    _prefs?.setString('defaultCookieSource', source.name);
    notifyListeners();
  }

  List<String> _cookieArgs(DownloadTask task, {required bool browserSupported}) {
    final o = task.options;
    switch (o.cookieSource) {
      case CookieSource.none:
        return [];
      case CookieSource.file:
        if (o.cookieFilePath == null) return [];
        return browserSupported
            ? ['--cookies', o.cookieFilePath!]
            : ['--load-cookies', o.cookieFilePath!];
      case CookieSource.librewolf:
        // Not a browser either tool knows, but its profile is Firefox's
        // format, so hand over the located profile directory.
        if (!browserSupported) return [];
        final profile = librewolfProfile;
        if (profile == null) return [];
        return ['--cookies-from-browser', 'firefox:${profile.path}'];
      default:
        if (!browserSupported) return [];
        return ['--cookies-from-browser', o.cookieSource.browserKey!];
    }
  }

  List<String> _optionArgs(DownloadTask task) {
    final defs = EngineOptions.forEngine(task.engine);
    return [
      for (final d in defs)
        // The format picker / format preset overrides the quality dropdown.
        if (!(task.engine == Engine.ytDlp &&
            d.id == 'format' &&
            (task.chosenFormat != null || task.formatSort != null)))
          ...d.args(task.options.values[d.id]),
    ];
  }

  List<String> _ytDlpArgs(DownloadTask task, String outDir, {String? shard}) {
    final ffmpegDir = tools.pathFor(ToolId.ffmpeg);
    return [
      if (shard != null) ...['-I', shard],
      '--newline',
      // --print implies --quiet, which hides the progress bar; force it
      // back on or no PROG lines are ever emitted.
      '--progress',
      '--no-simulate',
      '--progress-template',
      'download:PROG|%(progress._percent_str)s|%(progress._speed_str)s|%(progress._eta_str)s|%(info.playlist_index)s|%(info.playlist_count)s|%(info.title)s',
      '--print', 'before_dl:TITLE|%(title)s',
      '--print', 'after_move:FILE|%(filepath)s',
      '-P', outDir,
      if (ffmpegDir != null) ...['--ffmpeg-location', p.dirname(ffmpegDir)],
      if (task.chosenFormat != null) ...['-f', task.chosenFormat!],
      if (task.formatSort != null) ...['-S', task.formatSort!],
      ...Presets.argsFor(Engine.ytDlp, task.options.preset),
      ..._optionArgs(task),
      ..._cookieArgs(task, browserSupported: true),
      ...splitExtraArgs(task.options.extraArgs),
      task.url,
    ];
  }

  List<String> _galleryDlArgs(DownloadTask task, String outDir,
      {String? shard}) {
    return [
      if (shard != null) ...['--range', shard],
      '--directory', outDir,
      // {count} is the number of files in the current post/album, which
      // many extractors provide — it turns the progress bar from a
      // guess into a real fraction. Endless feeds report None, and we
      // fall back to an honest file count.
      '--Print', 'MULTI|{num}|{count}|{filename}.{extension}',
      ...Presets.argsFor(Engine.galleryDl, task.options.preset),
      ..._optionArgs(task),
      ..._cookieArgs(task, browserSupported: true),
      ...splitExtraArgs(task.options.extraArgs),
      task.url,
    ];
  }

  Future<(List<String>, File?)> _aria2Args(
      DownloadTask task, String outDir) async {
    File? inputFile;
    final urls = task.directUrls;
    final args = [
      '--dir=$outDir',
      '--summary-interval=1',
      '--console-log-level=warn',
      '--download-result=full',
      ...Presets.argsFor(Engine.aria2, task.options.preset),
      ..._optionArgs(task),
      ..._cookieArgs(task, browserSupported: false),
      ...splitExtraArgs(task.options.extraArgs),
    ];
    if (urls != null && urls.length > 1) {
      // aria2 treats several URL arguments as mirrors of one file; a
      // list of different files must go through an input file.
      final tmp = await Directory.systemTemp.createTemp('multi-aria2');
      inputFile = File(p.join(tmp.path, 'input.txt'));
      await inputFile.writeAsString(urls.join('\n'));
      args.addAll(['--input-file', inputFile.path]);
    } else {
      args.add(urls?.first ?? task.url);
    }
    return (args, inputFile);
  }

  static bool _isSet(String v) =>
      v.isNotEmpty && v != 'NA' && v != 'None';

  /// An explicit `--range` gives a firm upper bound on the file count,
  /// which is a perfectly good denominator when the extractor offers no
  /// {count} of its own. Handles '1-50', '50', and '10-20'.
  @visibleForTesting
  static int? rangeLimit(String? range) {
    final r = range?.trim();
    if (r == null || r.isEmpty || r.contains(',') || r.contains('::')) {
      return null;
    }
    final m = RegExp(r'^(\d+)\s*-\s*(\d+)$').firstMatch(r);
    if (m != null) {
      final start = int.parse(m.group(1)!), end = int.parse(m.group(2)!);
      return end >= start ? end - start + 1 : null;
    }
    final single = int.tryParse(r);
    return single != null && single > 0 ? 1 : null;
  }

  int? _rangeLimitOf(DownloadTask task) =>
      rangeLimit(task.options.values['range'] as String?);

  @visibleForTesting
  void parseProgressLine(DownloadTask task, String line) {
    switch (task.engine) {
      case Engine.ytDlp:
        if (line.startsWith('TITLE|')) {
          final t = line.substring(6).trim();
          if (_isSet(t)) task.title = t;
        } else if (line.startsWith('FILE|')) {
          final path = line.substring(5).trim();
          if (_isSet(path)) {
            task.outputFiles.add(path);
            task.filesDone++;
          }
        } else if (line.startsWith('PROG|')) {
          // PROG|percent|speed|eta|playlist_index|playlist_count|title
          // (title may itself contain '|', so it soaks up the rest).
          final parts = line.split('|');
          if (parts.length >= 4) {
            final pct =
                double.tryParse(parts[1].replaceAll('%', '').trim());
            final speed = parts[2].trim();
            final eta = parts[3].trim();
            final idx = parts.length > 4 ? parts[4].trim() : '';
            final count = parts.length > 5 ? parts[5].trim() : '';
            final itemTitle =
                parts.length > 6 ? parts.sublist(6).join('|').trim() : '';
            final inPlaylist = _isSet(idx) && _isSet(count);
            if (inPlaylist) {
              // Track each video's own progress (parallel workers
              // interleave their lines) and aggregate the overall bar.
              final part = task.parts.putIfAbsent(
                  idx, () => DownloadPart(key: idx));
              if (pct != null) part.percent = pct.round();
              if (_isSet(itemTitle)) part.title = itemTitle;
              if (speed.isNotEmpty && speed != 'Unknown') part.speed = speed;
              part.eta = (eta.isNotEmpty && eta != 'Unknown') ? eta : null;
              final total = int.tryParse(count) ?? 0;
              if (total > 0) {
                task.partsTotal = total;
                final sum = task.parts.values
                    .fold<double>(0, (a, b) => a + b.fraction);
                task.progress = (sum / total).clamp(0.0, 1.0);
              }
              task.statusLine = [
                '${task.partsDone}/$count videos',
                if (task.partsActive > 0)
                  '${task.partsActive} downloading',
              ].join(' · ');
            } else {
              if (pct != null) task.progress = pct / 100;
              task.statusLine = [
                if (pct != null) '${pct.toStringAsFixed(1)}%',
                if (speed.isNotEmpty && speed != 'Unknown') speed,
                if (eta.isNotEmpty && eta != 'Unknown') 'ETA $eta',
              ].join(' · ');
            }
          }
        } else if (line.startsWith('[Merger]')) {
          task.statusLine = 'Merging streams…';
        } else if (line.startsWith('[ExtractAudio]')) {
          task.statusLine = 'Extracting audio…';
        }
        break;
      case Engine.galleryDl:
        // gallery-dl emits, per file: a MULTI| line from --Print with
        // {num}/{count}, then the saved path ('# path' when the file was
        // skipped as already present). There is no byte-level progress
        // to read, so the bar counts whole files.
        if (line.startsWith('MULTI|')) {
          final parts = line.split('|');
          if (parts.length >= 3) {
            final num = int.tryParse(parts[1].trim());
            final count = int.tryParse(parts[2].trim());
            // {count} covers the current post/album. Once a second post
            // starts (num restarts) the run's total is unknowable, so
            // stop claiming one rather than showing a bar that resets.
            if (num != null && task.lastItemNum != null &&
                num <= task.lastItemNum!) {
              task.multiplePosts = true;
            }
            task.lastItemNum = num;
            if (!task.multiplePosts && count != null && count > 0) {
              task.partsTotal = count;
            } else {
              task.partsTotal = null;
            }
          }
          break;
        }
        final skipped = line.startsWith('#');
        if (skipped || !line.startsWith('[')) {
          final path = line.replaceFirst(RegExp(r'^#\s*'), '').trim();
          if (path.isEmpty) break;
          task.filesDone++;
          if (!skipped) task.outputFiles.add(path);
          task.title ??= Uri.tryParse(task.url)?.host;
          final total = task.partsTotal ?? _rangeLimitOf(task);
          if (total != null && total > 0) {
            task.progress = (task.filesDone / total).clamp(0.0, 1.0);
            task.statusLine =
                '${task.filesDone} of $total files — ${p.basename(path)}';
          } else {
            // Unknown total: no invented percentage.
            task.progress = null;
            task.statusLine =
                '${task.filesDone} files so far — ${p.basename(path)}';
          }
        }
        break;
      case Engine.aria2:
        // Status lines carry one bracket group per active download:
        // [#6e2b2f 4.3MiB/10MiB(43%) CN:4 DL:2.1MiB ETA:2s] [#a1b2c3 …]
        final groups = RegExp(r'\[#([0-9a-f]+)[^\[\]]*?\((\d+)%\)')
            .allMatches(line)
            .toList();
        if (groups.isNotEmpty) {
          final dl = RegExp(r'DL:([^\s\]]+)').firstMatch(line);
          for (final g in groups) {
            final part = task.parts
                .putIfAbsent(g.group(1)!, () => DownloadPart(key: g.group(1)!));
            part.percent = int.parse(g.group(2)!);
            if (dl != null) part.speed = '${dl.group(1)}/s';
          }
          final total = task.directUrls?.length ?? 1;
          if (total > 1) {
            // Every file's progress, individually.
            task.partsTotal = total;
            final sum =
                task.parts.values.fold<double>(0, (a, b) => a + b.fraction);
            task.progress = (sum / total).clamp(0.0, 1.0);
            task.statusLine = [
              '${task.partsDone}/$total files',
              if (task.partsActive > 0) '${task.partsActive} downloading',
              if (dl != null) '${dl.group(1)}/s',
            ].join(' · ');
          } else {
            task.progress = int.parse(groups.first.group(2)!) / 100;
            final eta = RegExp(r'ETA:([^\s\]]+)\]').firstMatch(line);
            task.statusLine = [
              '${groups.first.group(2)}%',
              if (dl != null) '${dl.group(1)}/s',
              if (eta != null) 'ETA ${eta.group(1)}',
            ].join(' · ');
          }
        } else if (RegExp(r'^[0-9a-f]{6}\|OK').hasMatch(line.trim())) {
          // --download-result=full summary row: gid|OK  |speed|/path
          final path = line.split('|').last.trim();
          if (path.startsWith('/') || RegExp(r'^[A-Za-z]:').hasMatch(path)) {
            task.outputFiles.add(path);
            task.filesDone++;
          }
        }
        break;
    }
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

  /// Human-readable preview of the exact command a task will run.
  String commandPreview(DownloadTask task) {
    final exe = tools.pathFor(_toolFor(task.engine)) ?? task.engine.displayName;
    final outDir = task.options.outputDir ?? downloadDir ?? '.';
    try {
      final args = switch (task.engine) {
        Engine.ytDlp => _ytDlpArgs(task, outDir),
        Engine.galleryDl => _galleryDlArgs(task, outDir),
        Engine.aria2 => [
            '--dir=$outDir',
            ...Presets.argsFor(Engine.aria2, task.options.preset),
            ..._optionArgs(task),
            ..._cookieArgs(task, browserSupported: false),
            ...splitExtraArgs(task.options.extraArgs),
            if (task.directUrls != null && task.directUrls!.length > 1)
              '(input file with ${task.directUrls!.length} URLs)'
            else
              task.directUrls?.first ?? task.url,
          ],
      };
      return '${p.basename(exe)} ${args.map((a) => a.contains(' ') ? '"$a"' : a).join(' ')}';
    } catch (e) {
      return '$e';
    }
  }

  @override
  void dispose() {
    for (final t in tasks) {
      for (final proc in t.processes) {
        proc.kill();
      }
      t.process?.kill();
    }
    super.dispose();
  }
}
