import 'dart:io';

import 'package:flutter/foundation.dart';

import '../models/download.dart';
import '../models/tool.dart';
import 'tool_manager.dart';

enum RouteKind {
  ytDlp,
  galleryDl,
  aria2Direct,

  /// No extractor claims the URL and it isn't a direct file link — the
  /// user decides what to do rather than Multi guessing.
  unsupported,
}

class RouteDecision {
  final RouteKind kind;
  final String reason;

  /// True when the URL points straight at a file (by extension or by
  /// what the server said).
  final bool isDirectFile;

  const RouteDecision(this.kind, this.reason, {this.isDirectFile = false});

  Engine? get engine => switch (kind) {
        RouteKind.ytDlp => Engine.ytDlp,
        RouteKind.galleryDl => Engine.galleryDl,
        RouteKind.aria2Direct => Engine.aria2,
        RouteKind.unsupported => null,
      };
}

/// Decides which engine handles a pasted URL.
///
/// Order of evidence, strongest first:
///  1. magnet links — only aria2 does torrents;
///  2. domains known to be galleries or video sites (instant, offline);
///  3. what yt-dlp and gallery-dl say when asked about the URL;
///  4. a direct link to a file, which nothing else claimed — aria2;
///  5. otherwise: ask the user.
///
/// aria2 is never chosen just because a URL looks like a file: the
/// extractors get asked first, so a page on a supported site can't be
/// mistaken for a download.
class UrlRouter {
  final ToolManager tools;
  UrlRouter(this.tools);

  // Sites that are primarily image galleries / social feeds → gallery-dl.
  static const _galleryDomains = {
    'instagram.com', 'pixiv.net', 'deviantart.com', 'artstation.com',
    'danbooru.donmai.us', 'gelbooru.com', 'e621.net', 'rule34.xxx',
    'flickr.com', 'tumblr.com', 'imgur.com', 'fanbox.cc', 'kemono.su',
    'coomer.su', 'redgifs.com', 'bsky.app', 'x.com', 'twitter.com',
    'reddit.com', 'weibo.com', '4chan.org', 'wallhaven.cc', 'behance.net',
    'newgrounds.com', 'furaffinity.net', 'mangadex.org',
    // Image-first sites that yt-dlp also claims — gallery-dl is the
    // better fit, so decide here rather than letting the probe order
    // pick for us.
    'pinterest.com', 'pinterest.co.uk', 'pinterest.ca', 'pin.it',
    'threads.net', 'threads.com', 'yande.re', 'konachan.com',
    'zerochan.net', 'safebooru.org', 'realbooru.com', 'nhentai.net',
    'e-hentai.org', 'exhentai.org', 'imgchest.com', 'postimg.cc',
    'sankakucomplex.com', 'nijie.info', 'seiga.nicovideo.jp',
    'lofter.com', 'poipiku.com', 'skeb.jp', 'booth.pm', 'inkbunny.net',
    'hentai-foundry.com', 'webtoons.com', 'subscribestar.adult',
    'patreon.com', 'gumroad.com', 'girlsreleased.com',
  };

  // Sites that are primarily video/audio → yt-dlp.
  static const _videoDomains = {
    'youtube.com', 'youtu.be', 'vimeo.com', 'twitch.tv', 'tiktok.com',
    'soundcloud.com', 'dailymotion.com', 'bilibili.com', 'nicovideo.jp',
    'rumble.com', 'odysee.com', 'bandcamp.com', 'streamable.com',
    'facebook.com', 'vk.com', 'bitchute.com', 'crunchyroll.com',
    'peertube.tv', 'ted.com', 'drive.google.com',
  };

  /// Extensions that mean "this URL is a file, not a page".
  static const directFileExtensions = {
    // archives & software
    'zip', '7z', 'rar', 'tar', 'gz', 'xz', 'bz2', 'zst', 'iso', 'img',
    'exe', 'msi', 'dmg', 'appimage', 'deb', 'rpm', 'apk', 'jar',
    // media served directly
    'mp4', 'mkv', 'webm', 'avi', 'mov', 'wmv', 'flv', 'm4v', 'mpg',
    'mpeg', 'ts', 'm2ts', 'mp3', 'm4a', 'flac', 'opus', 'ogg', 'oga',
    'wav', 'aac', 'wma', 'jpg', 'jpeg', 'png', 'gif', 'webp', 'avif',
    'bmp', 'tiff', 'tif', 'svg', 'heic',
    // documents & misc
    'pdf', 'epub', 'mobi', 'cbz', 'cbr', 'srt', 'ass', 'vtt', 'txt',
    'csv', 'json', 'xml', 'torrent', 'metalink', 'bin',
  };

  static bool _hostMatches(String host, Set<String> domains) {
    final h = host.startsWith('www.') ? host.substring(4) : host;
    return domains.any((d) => h == d || h.endsWith('.$d'));
  }

  /// The file extension of a URL path, or '' when it has none.
  static String extensionOf(String url) {
    final uri = Uri.tryParse(url);
    if (uri == null) return '';
    final segments = uri.pathSegments;
    if (segments.isEmpty) return '';
    final last = segments.last;
    if (!last.contains('.')) return '';
    return last.split('.').last.toLowerCase();
  }

  static bool looksLikeFile(String url) =>
      directFileExtensions.contains(extensionOf(url));

  /// Instant, offline classification from the URL alone. Returns null
  /// when the extractors need to be asked.
  RouteDecision? quickRoute(String url) {
    if (url.startsWith('magnet:')) {
      return const RouteDecision(RouteKind.aria2Direct, 'Magnet link',
          isDirectFile: true);
    }
    final uri = Uri.tryParse(url);
    if (uri == null || !(uri.isScheme('http') || uri.isScheme('https'))) {
      return null;
    }
    final host = uri.host.toLowerCase();
    if (_hostMatches(host, _galleryDomains)) {
      return const RouteDecision(
          RouteKind.galleryDl, 'Known gallery / social site');
    }
    if (_hostMatches(host, _videoDomains)) {
      return const RouteDecision(RouteKind.ytDlp, 'Known video site');
    }
    return null;
  }

  /// Full routing: instant rules, then the extractors, then aria2 only
  /// for a genuine file link, then hand the choice to the user.
  Future<RouteDecision> route(String url,
      {void Function(String status)? onStatus}) async {
    final quick = quickRoute(url);
    if (quick != null) return quick;

    final isFile = looksLikeFile(url);

    // Ask the tools themselves. When no extractor matches they fail
    // immediately without touching the network, so this is cheap for
    // exactly the URLs that end up going to aria2.
    onStatus?.call('Checking whether yt-dlp supports this site…');
    if (await supportedByYtDlp(url)) {
      return const RouteDecision(RouteKind.ytDlp, 'yt-dlp supports this site');
    }
    onStatus?.call('Checking whether gallery-dl supports this site…');
    if (await supportedByGalleryDl(url)) {
      return const RouteDecision(
          RouteKind.galleryDl, 'gallery-dl supports this site');
    }

    if (isFile) {
      return RouteDecision(RouteKind.aria2Direct,
          'Direct link to a .${extensionOf(url)} file — no extractor needed',
          isDirectFile: true);
    }
    return const RouteDecision(RouteKind.unsupported,
        'No downloader supports this site, and it isn\'t a direct file link');
  }

  /// Whether an extractor *claims* the URL — not whether fetching it
  /// succeeded. A site that matched but then failed (login wall, rate
  /// limit, deleted post) is still the right engine for the job.
  @visibleForTesting
  static bool ytDlpClaimsUrl(int exitCode, String output) {
    if (exitCode == 0) return true;
    final o = output.toLowerCase();
    return !(o.contains('no suitable extractor') ||
        o.contains('unsupported url') ||
        o.contains('is not a valid url'));
  }

  /// gallery-dl exits 64 and says "Unsupported URL" when nothing
  /// matches; any other failure came from an extractor that did match.
  @visibleForTesting
  static bool galleryDlClaimsUrl(int exitCode, String output) {
    if (exitCode == 0) return true;
    if (exitCode == 64) return false;
    return !output.toLowerCase().contains('unsupported url');
  }

  Future<bool> supportedByYtDlp(String url) async {
    final exe = tools.pathFor(ToolId.ytDlp);
    if (exe == null) return false;
    try {
      final r = await Process.run(exe, [
        '--simulate',
        '--no-warnings',
        '--flat-playlist',
        '--playlist-items', '1',
        // Without this the catch-all generic extractor claims every URL.
        '--use-extractors', 'default,-generic',
        '--print', 'id',
        url,
      ]).timeout(const Duration(seconds: 40));
      return ytDlpClaimsUrl(r.exitCode, '${r.stdout}\n${r.stderr}');
    } catch (_) {
      return false;
    }
  }

  Future<bool> supportedByGalleryDl(String url) async {
    final exe = tools.pathFor(ToolId.galleryDl);
    if (exe == null) return false;
    try {
      final r = await Process.run(exe, ['--simulate', '--range', '1', url])
          .timeout(const Duration(seconds: 40));
      return galleryDlClaimsUrl(r.exitCode, '${r.stdout}\n${r.stderr}');
    } catch (_) {
      return false;
    }
  }
}
