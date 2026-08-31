import '../models/download.dart';

/// Preset argument sets per engine, plus per-site recommendations.
class Presets {
  static List<String> argsFor(Engine engine, PresetId preset) {
    switch (engine) {
      case Engine.ytDlp:
        return switch (preset) {
          PresetId.speed => [
              '--concurrent-fragments', '8',
              '--retries', '3',
            ],
          PresetId.balanced => [
              '--retries', '5',
            ],
          PresetId.gentle => [
              '--concurrent-fragments', '1',
              '--sleep-requests', '1.5',
              '--sleep-interval', '3',
              '--max-sleep-interval', '9',
              '--limit-rate', '3M',
              '--retries', '10',
              '--retry-sleep', 'exp=1:120',
            ],
        };
      case Engine.galleryDl:
        return switch (preset) {
          PresetId.speed => ['--retries', '3'],
          PresetId.balanced => ['--sleep', '0.5-1.5', '--retries', '4'],
          PresetId.gentle => [
              '--sleep', '3.0-8.0',
              '--sleep-request', '1.5',
              '--limit-rate', '2M',
              '--retries', '8',
            ],
        };
      case Engine.aria2:
        return switch (preset) {
          PresetId.speed => [
              '--max-connection-per-server=16',
              '--split=16',
              '--min-split-size=1M',
              '--max-concurrent-downloads=8',
            ],
          PresetId.balanced => [
              '--max-connection-per-server=4',
              '--split=4',
              '--max-concurrent-downloads=4',
            ],
          PresetId.gentle => [
              '--max-connection-per-server=1',
              '--split=1',
              '--max-concurrent-downloads=1',
              '--max-overall-download-limit=2M',
              '--retry-wait=5',
            ],
        };
    }
  }

  /// Sites known to aggressively rate-limit or bot-detect get the
  /// low-profile preset recommended automatically.
  static final Map<String, PresetId> _siteRecommendation = {
    'instagram.com': PresetId.gentle,
    'x.com': PresetId.gentle,
    'twitter.com': PresetId.gentle,
    'pixiv.net': PresetId.gentle,
    'fanbox.cc': PresetId.gentle,
    'kemono.su': PresetId.gentle,
    'patreon.com': PresetId.gentle,
    'weibo.com': PresetId.gentle,
    'tiktok.com': PresetId.balanced,
    'youtube.com': PresetId.balanced,
    'youtu.be': PresetId.balanced,
    'archive.org': PresetId.speed,
  };

  /// Sites where logged-in cookies are usually required to get anything.
  static final Set<String> cookieRecommended = {
    'instagram.com',
    'x.com',
    'twitter.com',
    'pixiv.net',
    'fanbox.cc',
    'patreon.com',
    'facebook.com',
  };

  static PresetId recommendedFor(String host) {
    final h = _stripWww(host);
    for (final e in _siteRecommendation.entries) {
      if (h == e.key || h.endsWith('.${e.key}')) return e.value;
    }
    return PresetId.balanced;
  }

  static bool cookiesRecommendedFor(String host) {
    final h = _stripWww(host);
    return cookieRecommended.any((d) => h == d || h.endsWith('.$d'));
  }

  static String _stripWww(String host) =>
      host.startsWith('www.') ? host.substring(4) : host;
}
