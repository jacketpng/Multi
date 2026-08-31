import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:multi/models/convert.dart';
import 'package:multi/models/download.dart';
import 'package:multi/services/browser_profiles.dart';
import 'package:multi/services/convert_planner.dart';
import 'package:multi/services/download_manager.dart';
import 'package:multi/services/link_scraper.dart';
import 'package:multi/services/presets.dart';
import 'package:multi/services/tool_manager.dart';
import 'package:multi/services/url_router.dart';

void main() {
  group('splitExtraArgs', () {
    test('plain words', () {
      expect(splitExtraArgs('-x --audio-format mp3'),
          ['-x', '--audio-format', 'mp3']);
    });
    test('quoted strings survive', () {
      expect(splitExtraArgs('-o "my file.%(ext)s" --user-agent \'a b\''),
          ['-o', 'my file.%(ext)s', '--user-agent', 'a b']);
    });
    test('empty', () {
      expect(splitExtraArgs('  '), isEmpty);
    });
  });

  group('UrlRouter.quickRoute', () {
    final router = UrlRouter(ToolManager());
    test('video sites go to yt-dlp', () {
      expect(router.quickRoute('https://www.youtube.com/watch?v=x')!.kind,
          RouteKind.ytDlp);
      expect(router.quickRoute('https://youtu.be/x')!.kind, RouteKind.ytDlp);
      expect(router.quickRoute('https://www.twitch.tv/abc')!.kind,
          RouteKind.ytDlp);
    });
    test('gallery sites go to gallery-dl', () {
      expect(router.quickRoute('https://www.instagram.com/p/abc/')!.kind,
          RouteKind.galleryDl);
      expect(router.quickRoute('https://www.pixiv.net/artworks/1')!.kind,
          RouteKind.galleryDl);
      expect(
          router.quickRoute('https://x.com/a/status/1')!.kind,
          RouteKind.galleryDl);
    });
    test('pinterest goes to gallery-dl, not aria2', () {
      // Both tools claim pinterest; it is image-first, so gallery-dl
      // wins rather than leaving the probe order to decide.
      expect(router.quickRoute('https://www.pinterest.com/pin/12345/')!.kind,
          RouteKind.galleryDl);
      expect(
          router.quickRoute('https://pin.it/abc')!.kind, RouteKind.galleryDl);
    });
    test('magnets go straight to aria2', () {
      final d = router.quickRoute('magnet:?xt=urn:btih:abc')!;
      expect(d.kind, RouteKind.aria2Direct);
      expect(d.isDirectFile, isTrue);
    });
    test('a file extension alone never short-circuits to aria2', () {
      // The extractors are asked first, so a URL that merely looks like
      // a file is not routed instantly — otherwise a page on a
      // supported site could be mistaken for a download.
      expect(router.quickRoute('https://example.com/big.zip'), isNull);
      expect(router.quickRoute('https://example.com/video.mp4'), isNull);
      expect(UrlRouter.looksLikeFile('https://example.com/big.zip'), isTrue);
      expect(
          UrlRouter.looksLikeFile('https://example.com/some/page'), isFalse);
      expect(UrlRouter.extensionOf('https://a.com/x/y.tar.gz'), 'gz');
      expect(UrlRouter.extensionOf('https://a.com/dir/'), '');
    });
    test('unknown pages are undecided locally', () {
      expect(router.quickRoute('https://example.com/some/page'), isNull);
      expect(router.quickRoute('not a url'), isNull);
    });
    test('a matched-but-failed extractor still counts as supported', () {
      // The bug that sent pinterest to aria2: an extractor claimed the
      // URL and then failed, which must not read as "unsupported".
      expect(
          UrlRouter.galleryDlClaimsUrl(
              4, '[pinterest][error] NotFoundError: Requested pin not found'),
          isTrue);
      expect(
          UrlRouter.ytDlpClaimsUrl(1,
              'ERROR: [Pinterest] 133: Unable to download JSON metadata: HTTP Error 404'),
          isTrue);
      // Genuine "nothing matches" replies, as measured from the tools.
      expect(
          UrlRouter.galleryDlClaimsUrl(
              64, "[gallery-dl][error] Unsupported URL 'https://example.com'"),
          isFalse);
      expect(
          UrlRouter.ytDlpClaimsUrl(
              1, 'ERROR: No suitable extractor found for URL https://x.com'),
          isFalse);
      expect(UrlRouter.ytDlpClaimsUrl(0, 'abc123'), isTrue);
      expect(UrlRouter.galleryDlClaimsUrl(0, '/tmp/a.jpg'), isTrue);
    });
  });

  group('LinkScraper', () {
    test('only real file links are offered to aria2', () {
      // aria2 can only fetch files, so pages must not appear.
      for (final ext in ['jpg', 'mp4', 'zip', 'pdf', 'torrent', 'flac']) {
        expect(LinkScraper.isFileLink(ext), isTrue, reason: ext);
      }
      for (final ext in ['', 'html', 'php', 'aspx', 'jsp', 'com']) {
        expect(LinkScraper.isFileLink(ext), isFalse, reason: ext);
      }
    });
  });

  group('cookie gate for login-walled sites', () {
    test('restricted sites stop before any request; others do not', () async {
      final dm = DownloadManager(ToolManager());
      // Instagram hides everything from logged-out visitors, so the task
      // parks at needsCookies without routing or previewing.
      await dm.addUrl('https://www.instagram.com/p/abc/');
      final gated = dm.tasks.first;
      expect(gated.status, TaskStatus.needsCookies);
      expect(gated.preview, isNull, reason: 'must not have touched the site');
      expect(gated.statusLine, contains('logged-in'));

      // The same check covers every site on the cookie-recommended list,
      // including ones the router would otherwise probe live (patreon).
      for (final host in ['x.com', 'pixiv.net', 'patreon.com']) {
        await dm.addUrl('https://$host/thing');
        expect(dm.tasks.first.status, TaskStatus.needsCookies,
            reason: '$host should be gated');
        expect(dm.tasks.first.preview, isNull);
      }
    });

    test('a remembered cookie choice skips the gate', () async {
      final dm = DownloadManager(ToolManager());
      dm.defaultCookieSource = CookieSource.librewolf;
      await dm.addUrl('https://www.instagram.com/p/abc/');
      final task = dm.tasks.first;
      expect(task.status, isNot(TaskStatus.needsCookies));
      expect(task.options.cookieSource, CookieSource.librewolf);
    });
  });

  group('Presets', () {
    test('instagram gets the low-profile preset and a cookies hint', () {
      expect(Presets.recommendedFor('www.instagram.com'), PresetId.gentle);
      expect(Presets.cookiesRecommendedFor('www.instagram.com'), isTrue);
    });
    test('unknown hosts get balanced', () {
      expect(Presets.recommendedFor('example.com'), PresetId.balanced);
      expect(Presets.cookiesRecommendedFor('example.com'), isFalse);
    });
    test('gentle preset actually sleeps', () {
      final args = Presets.argsFor(Engine.ytDlp, PresetId.gentle);
      expect(args, contains('--sleep-interval'));
      expect(args, contains('--limit-rate'));
    });
  });

  group('parseProgressLine', () {
    DownloadTask makeTask(Engine e) => DownloadTask(
        id: 1,
        url: 'https://example.com',
        engine: e,
        options: DownloadOptions());
    final dm = DownloadManager(ToolManager());

    test('yt-dlp single video progress (real template output)', () {
      final t = makeTask(Engine.ytDlp);
      dm.parseProgressLine(
          t, 'PROG| 77.8%|   4.55KiB/s|00:12|NA|NA|Me at the zoo');
      expect(t.progress, closeTo(0.778, 0.001));
      expect(t.statusLine, contains('77.8%'));
      expect(t.statusLine, contains('4.55KiB/s'));
      expect(t.statusLine, isNot(contains('video')));
      expect(t.statusLine, isNot(contains('NA')));
    });

    test('yt-dlp playlist tracks each video as its own bar', () {
      final t = makeTask(Engine.ytDlp);
      dm.parseProgressLine(
          t, 'PROG| 45.0%|2.00MiB/s|00:30|3|10|Some | Piped | Title');
      expect(t.parts['3']!.percent, 45);
      expect(t.parts['3']!.title, 'Some | Piped | Title');
      expect(t.parts['3']!.speed, '2.00MiB/s');
      expect(t.partsTotal, 10);
      expect(t.statusLine, contains('0/10 videos'));
      expect(t.statusLine, contains('1 downloading'));
      expect(t.progress, closeTo(0.045, 0.001));

      // A parallel worker reports a different video: separate bar, and
      // the overall bar aggregates both.
      dm.parseProgressLine(t, 'PROG| 20.0%|1.00MiB/s|01:00|7|10|Other');
      expect(t.parts.length, 2);
      expect(t.parts['7']!.percent, 20);
      expect(t.progress, closeTo(0.065, 0.001));
      expect(t.statusLine, contains('2 downloading'));

      // Video 3 finishes: its own bar reads done, overall advances.
      dm.parseProgressLine(t, 'PROG|100.0%|2.00MiB/s|00:00|3|10|Some');
      expect(t.parts['3']!.done, isTrue);
      expect(t.partsDone, 1);
      expect(t.partsActive, 1);
      expect(t.statusLine, contains('1/10 videos'));
      expect(t.progress, closeTo(0.12, 0.001));
      // Display order is numeric, not insertion order.
      expect(t.sortedParts.map((p) => p.key), ['3', '7']);
      expect(t.parts['3']!.label, '#3');
    });

    test('speed preset runs every video in parallel, capped at 5', () {
      final t = makeTask(Engine.ytDlp);
      t.options.preset = PresetId.speed;
      // The reported case: a 3-video playlist runs all 3 at once.
      t.preview = MediaPreview()..playlistCount = 3;
      expect(dm.shardCountFor(t), 3);
      t.preview!.playlistCount = 5;
      expect(dm.shardCountFor(t), 5);
      t.preview!.playlistCount = 40; // capped
      expect(dm.shardCountFor(t), DownloadManager.defaultMaxParallelItems);
      expect(DownloadManager.defaultMaxParallelItems, 5);
      t.preview!.playlistCount = 1; // single video: nothing to split
      expect(dm.shardCountFor(t), 1);

      t.preview!.playlistCount = 20;
      t.options.preset = PresetId.balanced; // only Speed shards
      expect(dm.shardCountFor(t), 1);
      t.options.preset = PresetId.speed;
      t.options.values['playlistItems'] = '1-5'; // user range wins
      expect(dm.shardCountFor(t), 1);
      t.options.values.remove('playlistItems');
      t.options.values['archive'] = '~/a.txt'; // archive is not shard-safe
      expect(dm.shardCountFor(t), 1);

      final g = makeTask(Engine.galleryDl);
      g.options.preset = PresetId.speed;
      g.preview = MediaPreview()
        ..sampleItems = List.generate(8, (i) => 'f$i.jpg');
      expect(dm.shardCountFor(g), 5);
      g.preview!.sampleItems = ['one.jpg']; // small gallery
      expect(dm.shardCountFor(g), 1);

      final a = makeTask(Engine.aria2);
      a.options.preset = PresetId.speed;
      expect(dm.shardCountFor(a), 1); // aria2 parallelizes on its own
    });

    test('yt-dlp TITLE and FILE lines are captured, NA ignored', () {
      final t = makeTask(Engine.ytDlp);
      dm.parseProgressLine(t, 'TITLE|NA');
      expect(t.title, isNull);
      dm.parseProgressLine(t, 'TITLE|Me at the zoo');
      expect(t.title, 'Me at the zoo');
      dm.parseProgressLine(t, 'FILE|/downloads/a.mp4');
      expect(t.outputFiles, ['/downloads/a.mp4']);
    });

    test('aria2 single download progress', () {
      final t = makeTask(Engine.aria2);
      dm.parseProgressLine(t,
          '[#6e2b2f 4.3MiB/10MiB(43%) CN:4 DL:2.1MiB ETA:2s]');
      expect(t.progress, closeTo(0.43, 0.001));
      expect(t.statusLine, contains('43%'));
      expect(t.statusLine, contains('2.1MiB/s'));
    });

    test('gallery-dl uses one overall bar, never a row per picture', () {
      final t = makeTask(Engine.galleryDl);
      dm.parseProgressLine(t, '/out/a.webp');
      dm.parseProgressLine(t, '# /out/b_already_here.webp');
      // No per-file rows: a gallery of hundreds would be unreadable.
      expect(t.parts, isEmpty);
      expect(t.filesDone, 2);
      // Skipped files still count but are not offered for conversion.
      expect(t.outputFiles, ['/out/a.webp']);
      // Status/error lines are not mistaken for file paths.
      dm.parseProgressLine(t, '[instagram][error] HTTP redirect to home page');
      expect(t.filesDone, 2);
    });

    test('gallery-dl gets a real bar when {count} is known', () {
      final t = makeTask(Engine.galleryDl);
      // Real --Print output from an imgur album of 19.
      dm.parseProgressLine(t, 'MULTI|1|19|693j2Kr.jpg');
      dm.parseProgressLine(t, '/out/imgur_001_693j2Kr.jpg');
      expect(t.partsTotal, 19);
      expect(t.progress, closeTo(1 / 19, 0.001));
      expect(t.statusLine, contains('1 of 19 files'));

      dm.parseProgressLine(t, 'MULTI|2|19|ZNalkAC.jpg');
      dm.parseProgressLine(t, '/out/imgur_002_ZNalkAC.jpg');
      expect(t.progress, closeTo(2 / 19, 0.001));
    });

    test('gallery-dl stops claiming a total once a second post starts', () {
      final t = makeTask(Engine.galleryDl);
      // First post: 2 files, so a bar is legitimate.
      dm.parseProgressLine(t, 'MULTI|1|2|a.jpg');
      dm.parseProgressLine(t, '/out/a.jpg');
      expect(t.progress, closeTo(0.5, 0.001));
      dm.parseProgressLine(t, 'MULTI|2|2|b.jpg');
      dm.parseProgressLine(t, '/out/b.jpg');
      expect(t.progress, closeTo(1.0, 0.001));

      // A profile's next post restarts num: {count} is per-post, so the
      // run total is unknowable and the bar must not lie or reset.
      dm.parseProgressLine(t, 'MULTI|1|3|c.jpg');
      dm.parseProgressLine(t, '/out/c.jpg');
      expect(t.multiplePosts, isTrue);
      expect(t.partsTotal, isNull);
      expect(t.progress, isNull);
      expect(t.statusLine, contains('3 files so far'));
    });

    test('an endless feed reports no count and gets no fake bar', () {
      final t = makeTask(Engine.galleryDl);
      // Real --Print output from a danbooru tag search.
      dm.parseProgressLine(t, 'MULTI|None|None|e72ecdb.png');
      dm.parseProgressLine(t, '/out/e72ecdb.png');
      expect(t.partsTotal, isNull);
      expect(t.progress, isNull);
      expect(t.statusLine, contains('1 files so far'));
    });

    test('an explicit --range supplies the denominator', () {
      final t = makeTask(Engine.galleryDl);
      t.options.values['range'] = '1-20';
      dm.parseProgressLine(t, 'MULTI|None|None|x.jpg');
      dm.parseProgressLine(t, '/out/x.jpg');
      expect(t.progress, closeTo(1 / 20, 0.001));
      expect(t.statusLine, contains('1 of 20 files'));

      expect(DownloadManager.rangeLimit('1-50'), 50);
      expect(DownloadManager.rangeLimit('10-20'), 11);
      expect(DownloadManager.rangeLimit('5'), 1);
      expect(DownloadManager.rangeLimit('1-5,8'), isNull);
      expect(DownloadManager.rangeLimit('2::3'), isNull);
      expect(DownloadManager.rangeLimit(''), isNull);
      expect(DownloadManager.rangeLimit(null), isNull);
    });

    test('a login-wall failure explains itself', () {
      final t = makeTask(Engine.galleryDl);
      t.filesDone = 4;
      final hint = dm.loginWallHintFor(
          t, '[instagram][error] HTTP redirect to home page');
      expect(hint, isNotNull);
      expect(hint, contains('after 4 files'));
      expect(hint, contains('Set cookies'));
      // With cookies already set the advice changes.
      t.options.cookieSource = CookieSource.librewolf;
      expect(dm.loginWallHintFor(t, 'HTTP Error 429: rate limit'),
          contains('expired'));
      // Ordinary failures get no cookie lecture.
      expect(dm.loginWallHintFor(t, 'No such file or directory'), isNull);
    });

    test('aria2 parallel downloads get one bar per file', () {
      final t = makeTask(Engine.aria2);
      t.directUrls = ['u1', 'u2', 'u3', 'u4'];
      dm.parseProgressLine(t,
          '[#aaaa11 5MiB/10MiB(50%) CN:4 DL:2.1MiB] [#bbbb22 1MiB/4MiB(25%) CN:2]');
      expect(t.parts.length, 2);
      expect(t.parts['aaaa11']!.percent, 50);
      expect(t.parts['bbbb22']!.percent, 25);
      expect(t.parts['aaaa11']!.label, '#aaaa');
      expect(t.progress, closeTo((0.50 + 0.25) / 4, 0.001));
      // A later line advances one file; the other keeps its last value.
      dm.parseProgressLine(t, '[#bbbb22 4MiB/4MiB(100%) CN:1]');
      expect(t.progress, closeTo((0.50 + 1.0) / 4, 0.001));
      expect(t.statusLine, contains('1/4 files'));
      expect(t.partsDone, 1);
    });
  });

  group('BrowserProfiles (LibreWolf)', () {
    late Directory tmp;
    setUp(() => tmp = Directory.systemTemp.createTempSync('multi-lw'));
    tearDown(() => tmp.deleteSync(recursive: true));

    String makeProfile(String rel) {
      final dir = Directory(p.join(tmp.path, p.joinAll(rel.split('/'))))
        ..createSync(recursive: true);
      File(p.join(dir.path, 'cookies.sqlite')).writeAsStringSync('x');
      return dir.path;
    }

    test('[Install] section wins over Default=1', () {
      makeProfile('Profiles/aaa.default-release');
      makeProfile('Profiles/bbb.other');
      const ini = '''
[Install4F96D1932A9F858E]
Default=Profiles/bbb.other
Locked=1

[Profile0]
Name=default-release
IsRelative=1
Path=Profiles/aaa.default-release
Default=1

[Profile1]
Name=other
IsRelative=1
Path=Profiles/bbb.other

[General]
StartWithLastProfile=1
''';
      final profiles = BrowserProfiles.parseProfilesIni(ini, tmp.path);
      expect(profiles.length, 2);
      // The install default is promoted to the front and marked.
      expect(profiles.first.name, 'other');
      expect(profiles.first.markedDefault, isTrue);
      File(p.join(tmp.path, 'profiles.ini')).writeAsStringSync(ini);
      final main = BrowserProfiles.mainProfileOfRoot(tmp.path);
      expect(main!.name, 'other');
      expect(main.path, p.join(tmp.path, 'Profiles', 'bbb.other'));
    });

    test('falls back to Default=1, then to a default-release name', () {
      makeProfile('Profiles/x.alpha');
      makeProfile('Profiles/y.default-release');
      const withFlag = '''
[Profile0]
Name=alpha
IsRelative=1
Path=Profiles/x.alpha
Default=1

[Profile1]
Name=default-release
IsRelative=1
Path=Profiles/y.default-release
''';
      expect(BrowserProfiles.mainProfileOfRoot(tmp.path), isNotNull);
      File(p.join(tmp.path, 'profiles.ini')).writeAsStringSync(withFlag);
      expect(BrowserProfiles.mainProfileOfRoot(tmp.path)!.name, 'alpha');

      const noFlag = '''
[Profile0]
Name=alpha
IsRelative=1
Path=Profiles/x.alpha

[Profile1]
Name=default-release
IsRelative=1
Path=Profiles/y.default-release
''';
      File(p.join(tmp.path, 'profiles.ini')).writeAsStringSync(noFlag);
      expect(BrowserProfiles.mainProfileOfRoot(tmp.path)!.name,
          'default-release');
    });

    test('honours IsRelative=0 absolute paths', () {
      final abs = makeProfile('elsewhere/custom');
      final ini = '''
[Profile0]
Name=custom
IsRelative=0
Path=$abs
Default=1
''';
      final profiles = BrowserProfiles.parseProfilesIni(ini, tmp.path);
      expect(profiles.single.path, abs);
      expect(profiles.single.hasCookies, isTrue);
    });

    test('prefers a profile that actually has cookies', () {
      Directory(p.join(tmp.path, 'Profiles', 'empty'))
          .createSync(recursive: true);
      makeProfile('Profiles/real');
      const ini = '''
[Profile0]
Name=empty
IsRelative=1
Path=Profiles/empty

[Profile1]
Name=real
IsRelative=1
Path=Profiles/real
''';
      File(p.join(tmp.path, 'profiles.ini')).writeAsStringSync(ini);
      expect(BrowserProfiles.mainProfileOfRoot(tmp.path)!.name, 'real');
    });

    test('works with no profiles.ini by scanning for cookie databases', () {
      makeProfile('Profiles/scanned.default');
      final main = BrowserProfiles.mainProfileOfRoot(tmp.path);
      expect(main, isNotNull);
      expect(main!.hasCookies, isTrue);
    });

    test('root candidates cover system and flatpak layouts on Linux', () {
      if (!Platform.isLinux) return;
      final home = tmp.path;
      for (final dir in [
        p.join(home, '.librewolf'),
        p.join(home, '.var', 'app', 'io.gitlab.librewolf-community',
            '.librewolf'),
      ]) {
        Directory(dir).createSync(recursive: true);
        File(p.join(dir, 'profiles.ini')).writeAsStringSync('[General]\n');
      }
      // An empty directory is not a profile root and must be ignored.
      Directory(p.join(home, '.config', 'librewolf'))
          .createSync(recursive: true);

      final roots = BrowserProfiles.rootsFor(env: {'HOME': home});
      expect(roots.map((r) => r.$1), containsAll(['System', 'Flatpak']));
      expect(roots.length, 2);
    });

    test('with both system and flatpak installs, the freshest one wins', () {
      if (!Platform.isLinux) return;
      final home = tmp.path;
      Directory sysRoot = Directory(p.join(home, '.librewolf'));
      Directory flatRoot = Directory(p.join(home, '.var', 'app',
          'io.gitlab.librewolf-community', '.librewolf'));

      void seed(Directory root, String profileName, DateTime touched) {
        final dir = Directory(p.join(root.path, 'Profiles', profileName))
          ..createSync(recursive: true);
        final db = File(p.join(dir.path, 'cookies.sqlite'))
          ..writeAsStringSync('x');
        db.setLastModifiedSync(touched);
        File(p.join(root.path, 'profiles.ini')).writeAsStringSync('''
[Profile0]
Name=$profileName
IsRelative=1
Path=Profiles/$profileName
Default=1
''');
      }

      seed(sysRoot, 'sys-profile', DateTime(2026, 1, 1));
      seed(flatRoot, 'flat-profile', DateTime(2026, 8, 30));
      var main = BrowserProfiles.findLibrewolf(env: {'HOME': home});
      expect(main!.name, 'flat-profile');
      expect(main.installKind, 'Flatpak');

      // Use the system install more recently and it takes over.
      File(p.join(sysRoot.path, 'Profiles', 'sys-profile', 'cookies.sqlite'))
          .setLastModifiedSync(DateTime(2026, 8, 31));
      main = BrowserProfiles.findLibrewolf(env: {'HOME': home});
      expect(main!.name, 'sys-profile');
      expect(main.installKind, 'System');
    });

    test('real-world layout: nested dir, installs.ini, stale Default=1', () {
      if (!Platform.isLinux) return;
      // Mirrors an actual LibreWolf install: the root is nested one
      // level inside ~/.config/librewolf, the profile flagged Default=1
      // is NOT the one in use, and the real one is named by installs.ini
      // (and an [Install…] section) — only it has cookies.
      final home = tmp.path;
      final root = p.join(home, '.config', 'librewolf', 'librewolf');
      Directory(p.join(root, 'lk7504tx.default')).createSync(recursive: true);
      final inUse = Directory(p.join(root, 'i9876ybz.default-default'))
        ..createSync(recursive: true);
      File(p.join(inUse.path, 'cookies.sqlite')).writeAsStringSync('x');
      File(p.join(root, 'profiles.ini')).writeAsStringSync('''
[Profile1]
Name=default
IsRelative=1
Path=lk7504tx.default
Default=1

[Install6C4726F70D182CF7]
Default=i9876ybz.default-default
Locked=1

[Profile0]
Name=default-default
IsRelative=1
Path=i9876ybz.default-default

[General]
StartWithLastProfile=1
Version=2
''');
      File(p.join(root, 'installs.ini')).writeAsStringSync('''
[6C4726F70D182CF7]
Default=i9876ybz.default-default
Locked=1
''');

      // The nested root is discovered even though ~/.config/librewolf
      // itself holds no profiles.ini.
      final roots = BrowserProfiles.rootsFor(env: {'HOME': home});
      expect(roots.map((r) => r.$2), contains(root));

      final found = BrowserProfiles.findLibrewolf(env: {'HOME': home});
      expect(found, isNotNull);
      expect(found!.name, 'default-default',
          reason: 'installs.ini beats a stale Default=1');
      expect(found.path, inUse.path);
      expect(found.hasCookies, isTrue);
    });

    test('installs.ini parses bare-hash sections', () {
      expect(
          BrowserProfiles.parseInstallsIni('''
[6C4726F70D182CF7]
Default=i9876ybz.default-default
Locked=1
'''),
          ['i9876ybz.default-default']);
      expect(BrowserProfiles.parseInstallsIni('[X]\nLocked=1\n'), isEmpty);
    });

    test('a pasted path works whether it is the profile or the root', () {
      final profileDir = makeProfile('Profiles/pasted.default-release');
      // 1. The profile folder itself (about:profiles "Root Directory").
      var resolved = BrowserProfiles.resolveManualPath(profileDir);
      expect(resolved, isNotNull);
      expect(resolved!.path, profileDir);
      expect(resolved.hasCookies, isTrue);

      // 2. The installation root holding profiles.ini.
      File(p.join(tmp.path, 'profiles.ini')).writeAsStringSync('''
[Profile0]
Name=default-release
IsRelative=1
Path=Profiles/pasted.default-release
Default=1
''');
      resolved = BrowserProfiles.resolveManualPath(tmp.path);
      expect(resolved!.path, profileDir);

      // 3. Copy/paste noise: quotes and a trailing separator.
      expect(BrowserProfiles.resolveManualPath('"$profileDir"')?.path,
          profileDir);
      expect(BrowserProfiles.resolveManualPath('$profileDir/')?.path,
          profileDir);

      // 4. Nonsense stays null so the UI can report it.
      expect(BrowserProfiles.resolveManualPath(''), isNull);
      expect(BrowserProfiles.resolveManualPath(null), isNull);
      expect(
          BrowserProfiles.resolveManualPath(p.join(tmp.path, 'nope')), isNull);
      final empty = Directory(p.join(tmp.path, 'blank'))
        ..createSync(recursive: true);
      expect(BrowserProfiles.resolveManualPath(empty.path), isNull);
    });

    test('a pasted path overrides auto-detection', () {
      final dm = DownloadManager(ToolManager());
      final profileDir = makeProfile('Profiles/manual.default');
      dm.librewolfManualPath = profileDir;
      expect(dm.librewolfProfile!.path, profileDir);
      expect(dm.librewolfProfile!.installKind, 'Manual');
      expect(dm.librewolfManualPathError, isNull);

      dm.librewolfManualPath = p.join(tmp.path, 'does-not-exist');
      expect(dm.librewolfManualPathError, contains('does not exist'));
      final blank = Directory(p.join(tmp.path, 'blank2'))
        ..createSync(recursive: true);
      dm.librewolfManualPath = blank.path;
      expect(dm.librewolfManualPathError, contains('cookies.sqlite'));
    });

    test('librewolf is passed as a firefox profile path, not by name', () {
      // Neither yt-dlp nor gallery-dl knows "librewolf".
      expect(CookieSource.librewolf.browserKey, isNull);
      expect(CookieSource.librewolf.isFirefoxFamily, isTrue);
      expect(CookieSource.librewolf.label, 'LibreWolf');
    });
  });

  group('ConvertPlanner', () {
    final planner = ConvertPlanner(ToolManager());
    ContainerSpec spec(String id) =>
        containerSpecs.firstWhere((c) => c.id == id);
    ProbeResult mkvH264Aac() => ProbeResult(
          path: '/tmp/in.mkv',
          container: 'matroska',
          durationSeconds: 60,
          streams: [
            StreamInfo(index: 0, type: 'video', codec: 'h264'),
            StreamInfo(index: 1, type: 'audio', codec: 'aac'),
          ],
        );

    test('h264+aac mkv → mp4 is a pure remux', () {
      final plan = planner.plan(mkvH264Aac(), spec('mp4'));
      expect(plan.isPureRemux, isTrue);
      expect(plan.actions.every((a) => a.kind == StreamActionKind.copy),
          isTrue);
    });

    test('a codec mp4 cannot hold is transcoded, the rest copied', () {
      final input = ProbeResult(
        path: '/tmp/in.mkv',
        container: 'matroska',
        streams: [
          // Theora has no place in MP4; opus does.
          StreamInfo(index: 0, type: 'video', codec: 'theora'),
          StreamInfo(index: 1, type: 'audio', codec: 'opus'),
        ],
      );
      final plan = planner.plan(input, spec('mp4'));
      expect(plan.actions[0].kind, StreamActionKind.transcode);
      expect(plan.actions[0].targetCodec, 'h264');
      expect(plan.actions[1].kind, StreamActionKind.copy);
      expect(plan.isPureRemux, isFalse);
    });

    test('mp4 accepts vp9 and opus, so they are copied not re-encoded', () {
      // MP4 really does carry VP9 and Opus; remux-first means copying
      // them rather than re-encoding for no reason. Pick H.264 from the
      // dropdown when maximum player compatibility matters.
      final input = ProbeResult(
        path: '/tmp/in.webm',
        container: 'webm',
        streams: [
          StreamInfo(index: 0, type: 'video', codec: 'vp9'),
          StreamInfo(index: 1, type: 'audio', codec: 'opus'),
        ],
      );
      final plan = planner.plan(input, spec('mp4'));
      expect(plan.isPureRemux, isTrue);
    });

    test('audio-only target drops video and converts the codec', () {
      final plan = planner.plan(mkvH264Aac(), spec('mp3'));
      expect(plan.actions[0].kind, StreamActionKind.drop);
      expect(plan.actions[1].kind, StreamActionKind.transcode);
      expect(plan.actions[1].targetCodec, 'mp3');
    });

    test('aac → m4a is remux, not re-encode', () {
      final input = ProbeResult(
        path: '/tmp/in.mkv',
        container: 'matroska',
        streams: [StreamInfo(index: 0, type: 'audio', codec: 'aac')],
      );
      final plan = planner.plan(input, spec('m4a'));
      expect(plan.actions.single.kind, StreamActionKind.copy);
    });

    test('image subtitles are dropped for mp4, not transcoded', () {
      final input = ProbeResult(
        path: '/tmp/in.mkv',
        container: 'matroska',
        streams: [
          StreamInfo(index: 0, type: 'subtitle', codec: 'hdmv_pgs_subtitle'),
        ],
      );
      final plan = planner.plan(input, spec('mp4'));
      expect(plan.actions.single.kind, StreamActionKind.drop);
    });

    test('buildArgs maps copies and transcodes per stream', () {
      final plan = planner.plan(mkvH264Aac(), spec('webm'));
      final args =
          planner.buildArgs(plan, spec('webm'), '/tmp/out.webm', EncoderInventory.empty);
      // h264 → vp9 transcode, aac → opus transcode.
      expect(args.join(' '), contains('-c:0 libvpx-vp9'));
      expect(args.join(' '), contains('-c:1 libopus'));
      expect(args.join(' '), contains('-b:1 128k'));
      expect(args.last, '/tmp/out.webm');
    });

    test('buildArgs uses copy for remux', () {
      final plan = planner.plan(mkvH264Aac(), spec('mp4'));
      final args =
          planner.buildArgs(plan, spec('mp4'), '/tmp/out.mp4', EncoderInventory.empty);
      expect(args.join(' '), contains('-c:0 copy'));
      expect(args.join(' '), contains('-c:1 copy'));
      expect(args.join(' '), contains('-movflags +faststart'));
    });

    test('user can force a re-encode even when copy is possible', () {
      final plan = planner.plan(mkvH264Aac(), spec('mp4'));
      plan.selection[0] = 'hevc';
      planner.recompute(plan, spec('mp4'));
      final v = plan.actions[0];
      expect(v.kind, StreamActionKind.transcode);
      expect(v.userForced, isTrue);
      final args =
          planner.buildArgs(plan, spec('mp4'), '/tmp/out.mp4', EncoderInventory.empty);
      expect(args.join(' '), contains('-c:0 libx265'));
      expect(args.join(' '), contains('-tag:0 hvc1'));
      expect(args.join(' '), contains('-crf 24')); // hevc default
    });

    test('constant bitrate mode uses -b instead of -crf', () {
      final plan = planner.plan(mkvH264Aac(), spec('webm'));
      plan.settings.mode = RateMode.constantBitrate;
      plan.settings.videoBitrate = '2M';
      final args =
          planner.buildArgs(plan, spec('webm'), '/tmp/out.webm', EncoderInventory.empty);
      final joined = args.join(' ');
      expect(joined, contains('-b:0 2M'));
      expect(joined, isNot(contains('-crf')));
    });

    test('hardware encoder is used when enabled and available', () {
      final plan = planner.plan(mkvH264Aac(), spec('webm'));
      plan.selection[0] = 'vp9';
      plan.settings.hwAccel = true;
      const hw = EncoderInventory(encoders: {'vp9_vaapi', 'h264_vaapi'},
          hwFamilies: ['vaapi']);
      final args = planner.buildArgs(plan, spec('webm'), '/tmp/o.webm', hw);
      final joined = args.join(' ');
      expect(joined, contains('-c:0 vp9_vaapi'));
      expect(joined, contains('-init_hw_device vaapi'));
      expect(joined, contains('format=nv12,hwupload'));
    });

    test('size estimates exist and respond to quality', () {
      final input = ProbeResult(
        path: '/tmp/in.webm',
        container: 'webm',
        durationSeconds: 100,
        streams: [
          StreamInfo(
              index: 0, type: 'video', codec: 'vp9',
              width: 1920, height: 1080, fps: 30),
        ],
      );
      final plan = planner.plan(input, spec('mp4'));
      // MP4 can carry VP9, so force a re-encode to exercise the
      // quality-driven estimate.
      plan.selection[0] = 'h264';
      planner.recompute(plan, spec('mp4'));
      final base = plan.actions[0].estimatedBytes!;
      expect(base, greaterThan(0));
      plan.settings.crf = 26; // worse quality → smaller
      planner.recompute(plan, spec('mp4'));
      expect(plan.actions[0].estimatedBytes!, lessThan(base));
      expect(plan.estimatedTotalBytes, plan.actions[0].estimatedBytes);
    });

    test('copied streams estimate from their real bitrate', () {
      final input = ProbeResult(
        path: '/tmp/in.mkv',
        container: 'matroska',
        durationSeconds: 10,
        streams: [
          StreamInfo(
              index: 0, type: 'audio', codec: 'aac', bitRate: 128000),
        ],
      );
      final plan = planner.plan(input, spec('m4a'));
      expect(plan.actions[0].estimatedBytes, 160000); // 128kbps * 10s / 8
    });

    test('parseBitrate handles k and M suffixes', () {
      expect(ConvertPlanner.parseBitrate('800k'), 800000);
      expect(ConvertPlanner.parseBitrate('4M'), 4000000);
      expect(ConvertPlanner.parseBitrate('2.5M'), 2500000);
      expect(ConvertPlanner.parseBitrate('junk'), isNull);
    });

    test('every codec in the catalog has descriptions', () {
      for (final c in codecCatalog) {
        expect(c.description.length, greaterThan(20),
            reason: '${c.id} needs a real description');
        expect(c.shortDescription, isNotEmpty,
            reason: '${c.id} needs a short description');
      }
    });

    test('raw codec strings map to short blurbs', () {
      expect(shortBlurbForRawCodec('avc1.64001f'),
          codecInfo('h264')!.shortDescription);
      expect(shortBlurbForRawCodec('mp4a.40.2'),
          codecInfo('aac')!.shortDescription);
      expect(shortBlurbForRawCodec('vp09.00.20.08'),
          codecInfo('vp9')!.shortDescription);
      expect(shortBlurbForRawCodec('av01.0.00M.08'),
          codecInfo('av1')!.shortDescription);
      expect(shortBlurbForRawCodec('somethingweird'), isNull);
    });

    test('most-compatible preset emits -S h264/aac sort', () {
      final dm = DownloadManager(ToolManager());
      final task = DownloadTask(
          id: 1,
          url: 'https://youtube.com/watch?v=x',
          engine: Engine.ytDlp,
          options: DownloadOptions());
      task.formatSort = 'vcodec:h264,acodec:aac';
      final cmd = dm.commandPreview(task);
      expect(cmd, contains('-S vcodec:h264,acodec:aac'));
      // A custom -f pick clears the sort instead of stacking.
      task.formatSort = null;
      task.chosenFormat = '137+140';
      expect(dm.commandPreview(task), contains('-f 137+140'));
      expect(dm.commandPreview(task), isNot(contains('-S ')));
    });

    test('encodable choices respect the container and rank by popularity',
        () {
      final mp4Video =
          planner.encodableFor(spec('mp4'), 'video', EncoderInventory.empty);
      final ids = mp4Video.map((c) => c.id).toList();
      expect(ids, containsAll(['h264', 'hevc', 'av1', 'vp9']));
      // Theora and ProRes have no place in MP4.
      expect(ids, isNot(contains('theora')));
      expect(ids, isNot(contains('prores')));
      // Most compatible first.
      expect(ids.first, 'h264');

      final webmAudio =
          planner.encodableFor(spec('webm'), 'audio', EncoderInventory.empty);
      expect(webmAudio.map((c) => c.id), containsAll(['opus', 'vorbis']));
      expect(webmAudio.map((c) => c.id), isNot(contains('mp3')));
    });

    test('MKV lists everything the ffmpeg build can encode', () {
      // A permissive container offers the curated codecs first, then
      // every other encoder the local build provides.
      const inv = EncoderInventory(
        encoders: {'libx264', 'libx265', 'libaom-av1', 'ffv1', 'roqvideo'},
        codecOf: {
          'libx264': 'h264',
          'libx265': 'hevc',
          'libaom-av1': 'av1',
          'ffv1': 'ffv1',
          'roqvideo': 'roq',
        },
        kindOf: {
          'libx264': 'video',
          'libx265': 'video',
          'libaom-av1': 'video',
          'ffv1': 'video',
          'roqvideo': 'video',
        },
      );
      final ids =
          planner.encodableFor(spec('mkv'), 'video', inv).map((c) => c.id);
      expect(ids.first, 'h264', reason: 'popular codecs sort to the top');
      expect(ids, contains('ffv1'));
      // The long tail from the build shows up too, even uncurated.
      expect(ids, contains('roq'));
      // A codec the build cannot encode is not offered.
      expect(ids, isNot(contains('vp9')));
    });

    test('hardware quality uses the family scale, and CQ can be absent', () {
      final st = TranscodeSettings()..hwAccel = true;
      const nv = EncoderInventory(
          encoders: {'h264_nvenc'}, hwFamilies: ['nvenc']);
      final nvScale = planner.qualityScale('h264', st, nv);
      expect(nvScale.$4, isTrue);
      expect(nvScale.$3, hwFamilies['nvenc']!.cqDefault);
      // Software CRF differs from the hardware CQ scale.
      final swScale =
          planner.qualityScale('h264', TranscodeSettings(), nv);
      expect(swScale.$3, codecInfo('h264')!.crfDefault);

      // VideoToolbox has no dependable constant-quality mode.
      const vt = EncoderInventory(
          encoders: {'h264_videotoolbox'}, hwFamilies: ['videotoolbox']);
      expect(planner.qualityScale('h264', st, vt).$4, isFalse);
    });

    test('a size cap turns into a bitrate that fits', () {
      // 25 MB over 60s, minus 128 kbps of audio.
      final bps = ConvertPlanner.bitrateForSizeCap(25, 60, 128);
      expect(bps, isNotNull);
      final totalBytes = (bps! + 128000) * 60 / 8;
      expect(totalBytes, lessThan(25 * 1000 * 1000));
      expect(totalBytes, greaterThan(20 * 1000 * 1000));
      // Nonsense inputs are refused rather than guessed at.
      expect(ConvertPlanner.bitrateForSizeCap(25, null, 128), isNull);
      expect(ConvertPlanner.bitrateForSizeCap(1, 6000, 128), isNull);
    });

    test('filters build a chain in a sensible order and change estimates',
        () {
      final f = VideoFilters()
        ..deinterlace = true
        ..scale = '1280:-2'
        ..fps = '30'
        ..grayscale = true;
      expect(f.chain(), ['yadif', 'scale=1280:-2', 'fps=30', 'format=gray']);
      expect(f.scaleSize.$1, 1280);
      expect(VideoFilters().isEmpty, isTrue);

      // Downscaling should shrink the estimate.
      final input = ProbeResult(
        path: '/tmp/in.mkv',
        container: 'matroska',
        durationSeconds: 60,
        streams: [
          StreamInfo(
              index: 0, type: 'video', codec: 'theora',
              width: 1920, height: 1080, fps: 30),
        ],
      );
      final plan = planner.plan(input, spec('mp4'));
      final before = plan.actions[0].estimatedBytes!;
      plan.settings.filters.scale = '640:-2';
      planner.recompute(plan, spec('mp4'));
      expect(plan.actions[0].estimatedBytes!, lessThan(before ~/ 2));
    });

    test('quality auto-pick lands near the original size', () {
      final input = ProbeResult(
        path: '/tmp/in.mkv',
        container: 'matroska',
        durationSeconds: 60,
        streams: [
          StreamInfo(
              index: 0, type: 'video', codec: 'theora',
              width: 1920, height: 1080, fps: 30, bitRate: 4000000),
        ],
      );
      final plan = planner.plan(input, spec('mp4'));
      final q = planner.qualityMatchingOriginalSize(
          plan, spec('mp4'), EncoderInventory.empty);
      expect(q, isNotNull);
      plan.settings.crf = q;
      planner.recompute(plan, spec('mp4'));
      final a = plan.actions[0];
      final ratio = a.estimatedBytes! / a.originalBytes!;
      expect(ratio, greaterThan(0.6));
      expect(ratio, lessThan(1.6));
      expect(a.percentChange!.abs(), lessThan(60));
    });

    test('stream rows carry original and estimated sizes', () {
      final plan = planner.plan(
          ProbeResult(
            path: '/tmp/in.mkv',
            container: 'matroska',
            durationSeconds: 10,
            streams: [
              StreamInfo(
                  index: 0, type: 'audio', codec: 'aac', bitRate: 128000),
            ],
          ),
          spec('m4a'));
      final a = plan.actions.single;
      expect(a.kind, StreamActionKind.copy);
      expect(a.originalBytes, 160000);
      expect(a.estimatedBytes, 160000);
      expect(a.percentChange, 0);
    });
  });
}
