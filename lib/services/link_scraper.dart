import 'package:html/parser.dart' as html_parser;
import 'package:http/http.dart' as http;

import 'url_router.dart';

class ScrapedLink {
  final String url;
  final String label;
  final String extension;
  bool selected;
  ScrapedLink(
      {required this.url,
      required this.label,
      required this.extension,
      this.selected = false});
}

/// Fetches a web page and collects the links that point at actual
/// files, so the user can tick the ones they want and hand them to
/// aria2. Links to other pages are left out: aria2 can only fetch
/// files, so offering pages would just produce saved HTML.
class LinkScraper {
  static const _mediaExts = {
    'mp4', 'mkv', 'webm', 'avi', 'mov', 'wmv', 'flv', 'm4v', 'mpg',
    'mpeg', 'ts', 'm2ts', 'mp3', 'm4a', 'flac', 'opus', 'ogg', 'oga',
    'wav', 'aac', 'wma', 'jpg', 'jpeg', 'png', 'gif', 'webp', 'avif',
    'bmp', 'tiff', 'tif', 'svg', 'heic',
  };
  static const _fileExts = {
    'zip', '7z', 'rar', 'tar', 'gz', 'xz', 'bz2', 'zst', 'iso', 'img',
    'exe', 'msi', 'dmg', 'appimage', 'deb', 'rpm', 'apk', 'jar', 'pdf',
    'epub', 'mobi', 'cbz', 'cbr', 'torrent', 'metalink', 'srt', 'ass',
    'vtt', 'txt', 'csv', 'json', 'xml', 'bin',
  };

  static bool isFileLink(String extension) =>
      _mediaExts.contains(extension) || _fileExts.contains(extension);

  Future<List<ScrapedLink>> scrape(String pageUrl) async {
    final base = Uri.parse(pageUrl);
    final resp = await http.get(base, headers: {
      'User-Agent':
          'Mozilla/5.0 (X11; Linux x86_64; rv:141.0) Gecko/20100101 Firefox/141.0',
    }).timeout(const Duration(seconds: 30));
    if (resp.statusCode != 200) {
      throw 'Could not load page (HTTP ${resp.statusCode})';
    }
    final doc = html_parser.parse(resp.body);
    final seen = <String>{};
    final links = <ScrapedLink>[];

    void add(String? href, String label) {
      if (href == null || href.isEmpty) return;
      Uri resolved;
      try {
        resolved = base.resolveUri(Uri.parse(href.trim()));
      } catch (_) {
        return;
      }
      if (!resolved.isScheme('http') && !resolved.isScheme('https')) return;
      final urlStr = resolved.toString();
      if (!seen.add(urlStr)) return;
      final path = resolved.path;
      final ext = UrlRouter.extensionOf(urlStr);
      // Only real files: aria2 cannot do anything useful with a page.
      if (!isFileLink(ext)) return;
      links.add(ScrapedLink(
        url: urlStr,
        label: label.trim().isEmpty
            ? (path.split('/').lastWhere((s) => s.isNotEmpty, orElse: () => urlStr))
            : label.trim(),
        extension: ext,
        selected: true,
      ));
    }

    for (final a in doc.querySelectorAll('a[href]')) {
      add(a.attributes['href'], a.text);
    }
    for (final el in doc.querySelectorAll('img[src], video[src], audio[src], source[src]')) {
      add(el.attributes['src'], el.attributes['alt'] ?? '');
    }

    // Media first — usually what someone scanning a page is after.
    links.sort((a, b) {
      int rank(ScrapedLink l) => _mediaExts.contains(l.extension) ? 0 : 1;
      return rank(a).compareTo(rank(b));
    });
    return links;
  }
}
