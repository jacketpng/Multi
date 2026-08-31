import 'dart:io';

/// Small cross-platform helpers shared across services.
class PlatformUtil {
  static String get exeSuffix => Platform.isWindows ? '.exe' : '';

  /// Reveal a file or directory in the OS file manager.
  static Future<void> revealInFileManager(String path) async {
    if (Platform.isWindows) {
      await Process.run('explorer', [path]);
      return;
    }
    if (Platform.isMacOS) {
      await Process.run('open', [path]);
      return;
    }
    // Linux: try the usual openers; inside containers (toolbox/flatpak)
    // they may be missing or sandboxed, so fall through to the host.
    for (final cmd in [
      ['xdg-open', path],
      ['gio', 'open', path],
      ['flatpak-spawn', '--host', 'xdg-open', path],
    ]) {
      try {
        final r = await Process.run(cmd.first, cmd.sublist(1))
            .timeout(const Duration(seconds: 10));
        if (r.exitCode == 0) return;
      } catch (_) {}
    }
  }

  /// Locate an executable on PATH, or null if absent.
  static Future<String?> which(String name) async {
    final cmd = Platform.isWindows ? 'where' : 'which';
    try {
      final r = await Process.run(cmd, [name]);
      if (r.exitCode == 0) {
        final line = (r.stdout as String)
            .split(RegExp(r'\r?\n'))
            .firstWhere((l) => l.trim().isNotEmpty, orElse: () => '');
        if (line.trim().isNotEmpty) return line.trim();
      }
    } catch (_) {}
    return null;
  }

  static String humanBytes(num bytes) {
    const units = ['B', 'KB', 'MB', 'GB', 'TB'];
    var v = bytes.toDouble();
    var i = 0;
    while (v >= 1024 && i < units.length - 1) {
      v /= 1024;
      i++;
    }
    return '${v.toStringAsFixed(v >= 100 || i == 0 ? 0 : 1)} ${units[i]}';
  }
}
