import 'dart:io';

import 'package:path/path.dart' as p;

/// A Firefox-family browser profile found on disk.
class BrowserProfile {
  final String name;
  final String path;
  /// 'System', 'Flatpak', or 'Snap' — how the browser was installed.
  final String installKind;
  final bool markedDefault;

  BrowserProfile({
    required this.name,
    required this.path,
    required this.installKind,
    this.markedDefault = false,
  });

  File get cookieDb => File(p.join(path, 'cookies.sqlite'));
  bool get hasCookies => cookieDb.existsSync();

  DateTime? get cookiesModified {
    try {
      return cookieDb.statSync().modified;
    } catch (_) {
      return null;
    }
  }

  /// Short description for the UI.
  String get label => installKind == 'System' ? name : '$name ($installKind)';

  @override
  String toString() => '$label — $path';
}

/// Locates profiles of Firefox-family browsers that yt-dlp and
/// gallery-dl don't know by name.
///
/// LibreWolf is a Firefox fork and stores an identical `cookies.sqlite`
/// in an identical profile layout, but neither tool lists it as a
/// supported browser. Both do accept an explicit profile *path*
/// (`firefox:/path/to/profile`), so finding the right directory is all
/// that's needed.
class BrowserProfiles {
  /// Candidate profile-root directories for LibreWolf, per platform.
  ///
  /// Each entry is (installKind, directory). Directories that don't
  /// exist are filtered out by [rootsFor].
  static List<(String, String)> _librewolfCandidates(
      Map<String, String> env, String home) {
    if (Platform.isWindows) {
      final appData = env['APPDATA'] ?? p.join(home, 'AppData', 'Roaming');
      final localAppData =
          env['LOCALAPPDATA'] ?? p.join(home, 'AppData', 'Local');
      return [
        ('System', p.join(appData, 'librewolf')),
        ('System', p.join(appData, 'LibreWolf')),
        ('System', p.join(localAppData, 'librewolf')),
      ];
    }
    if (Platform.isMacOS) {
      final support = p.join(home, 'Library', 'Application Support');
      return [
        ('System', p.join(support, 'LibreWolf')),
        ('System', p.join(support, 'librewolf')),
      ];
    }
    // Linux and other Unix. Layouts vary by packaging: some builds use
    // ~/.librewolf, others $XDG_CONFIG_HOME/librewolf — and that one
    // nests a second 'librewolf' directory inside. [rootsFor] also
    // descends one level, so both forms resolve.
    final config = env['XDG_CONFIG_HOME'] ?? p.join(home, '.config');
    final flatpak =
        p.join(home, '.var', 'app', 'io.gitlab.librewolf-community');
    return [
      ('System', p.join(config, 'librewolf')),
      ('System', p.join(home, '.librewolf')),
      ('System', p.join(home, '.mozilla', 'librewolf')),
      ('Flatpak', p.join(flatpak, '.config', 'librewolf')),
      ('Flatpak', p.join(flatpak, '.librewolf')),
      ('Flatpak', p.join(flatpak, '.mozilla', 'librewolf')),
      ('Snap', p.join(home, 'snap', 'librewolf', 'common', '.librewolf')),
      (
        'Snap',
        p.join(home, 'snap', 'librewolf', 'common', '.config', 'librewolf')
      ),
    ];
  }

  /// True when a directory looks like a profile-root (has profiles.ini)
  /// or is itself a profile (has cookies.sqlite).
  static bool _isProfileRoot(String dir) =>
      File(p.join(dir, 'profiles.ini')).existsSync() ||
      File(p.join(dir, 'installs.ini')).existsSync() ||
      File(p.join(dir, 'cookies.sqlite')).existsSync();

  static String? _home(Map<String, String> env) =>
      env['HOME'] ?? env['USERPROFILE'];

  /// Existing profile-root directories for LibreWolf on this machine.
  ///
  /// Some packagings nest the real root one level down (for example
  /// ~/.config/librewolf/librewolf), so a candidate that isn't itself a
  /// profile root contributes its immediate subdirectories that are.
  static List<(String, String)> rootsFor({Map<String, String>? env}) {
    final e = env ?? Platform.environment;
    final home = _home(e);
    if (home == null) return [];
    final seen = <String>{};
    final roots = <(String, String)>[];
    for (final (kind, dir) in _librewolfCandidates(e, home)) {
      if (!Directory(dir).existsSync()) continue;
      if (_isProfileRoot(dir)) {
        if (seen.add(dir)) roots.add((kind, dir));
        continue;
      }
      try {
        for (final sub in Directory(dir).listSync().whereType<Directory>()) {
          if (_isProfileRoot(sub.path) && seen.add(sub.path)) {
            roots.add((kind, sub.path));
          }
        }
      } catch (_) {}
    }
    return roots;
  }

  /// Parse a Firefox `profiles.ini` into profiles, in file order.
  ///
  /// The `[Install…]` section names the profile the browser actually
  /// launches, which is more reliable than `Default=1` on a `[Profile…]`
  /// section, so it wins when present.
  static List<BrowserProfile> parseProfilesIni(String contents, String root,
      {String installKind = 'System'}) {
    final profiles = <BrowserProfile>[];
    final installDefaults = <String>[];
    var section = '';
    var name = '', path = '';
    var isRelative = true, isDefault = false;

    void flush() {
      if (section.toLowerCase().startsWith('profile') && path.isNotEmpty) {
        profiles.add(BrowserProfile(
          name: name.isEmpty ? p.basename(path) : name,
          // profiles.ini always uses forward slashes.
          path: isRelative
              ? p.normalize(p.join(root, p.joinAll(path.split('/'))))
              : path,
          installKind: installKind,
          markedDefault: isDefault,
        ));
      }
      name = '';
      path = '';
      isRelative = true;
      isDefault = false;
    }

    for (final raw in contents.split(RegExp(r'\r?\n'))) {
      final line = raw.trim();
      if (line.isEmpty || line.startsWith('#') || line.startsWith(';')) {
        continue;
      }
      if (line.startsWith('[') && line.endsWith(']')) {
        flush();
        section = line.substring(1, line.length - 1);
        continue;
      }
      final eq = line.indexOf('=');
      if (eq < 0) continue;
      final key = line.substring(0, eq).trim().toLowerCase();
      final value = line.substring(eq + 1).trim();
      if (section.toLowerCase().startsWith('install')) {
        if (key == 'default' && value.isNotEmpty) installDefaults.add(value);
      } else if (section.toLowerCase().startsWith('profile')) {
        switch (key) {
          case 'name':
            name = value;
            break;
          case 'path':
            path = value;
            break;
          case 'isrelative':
            isRelative = value != '0';
            break;
          case 'default':
            isDefault = value == '1' || value.toLowerCase() == 'true';
            break;
        }
      }
    }
    flush();

    // Promote whatever the [Install…] sections point at.
    for (final rel in installDefaults) {
      final target = p.normalize(p.join(root, p.joinAll(rel.split('/'))));
      for (var i = 0; i < profiles.length; i++) {
        if (p.equals(profiles[i].path, target)) {
          final hit = profiles.removeAt(i);
          profiles.insert(
              0,
              BrowserProfile(
                name: hit.name,
                path: hit.path,
                installKind: hit.installKind,
                markedDefault: true,
              ));
          break;
        }
      }
    }
    return profiles;
  }

  /// Profile paths named as the default by an `installs.ini`, whose
  /// sections are bare install hashes rather than `[Install…]`.
  static List<String> parseInstallsIni(String contents) {
    final defaults = <String>[];
    for (final raw in contents.split(RegExp(r'\r?\n'))) {
      final line = raw.trim();
      final eq = line.indexOf('=');
      if (eq < 0 || line.startsWith('[')) continue;
      if (line.substring(0, eq).trim().toLowerCase() == 'default') {
        final value = line.substring(eq + 1).trim();
        if (value.isNotEmpty) defaults.add(value);
      }
    }
    return defaults;
  }

  /// The main profile of one installation root, or null.
  static BrowserProfile? mainProfileOfRoot(String root,
      {String installKind = 'System'}) {
    final ini = File(p.join(root, 'profiles.ini'));
    List<BrowserProfile> profiles;
    if (ini.existsSync()) {
      try {
        profiles = parseProfilesIni(ini.readAsStringSync(), root,
            installKind: installKind);
      } catch (_) {
        profiles = [];
      }
    } else {
      profiles = [];
    }

    // Newer builds record the in-use profile in installs.ini instead of
    // an [Install…] section, and it outranks a stale Default=1 flag.
    final installs = File(p.join(root, 'installs.ini'));
    if (installs.existsSync() && profiles.isNotEmpty) {
      try {
        for (final rel in parseInstallsIni(installs.readAsStringSync())) {
          final target = p.normalize(p.join(root, p.joinAll(rel.split('/'))));
          final i = profiles.indexWhere((x) => p.equals(x.path, target));
          if (i >= 0) {
            final hit = profiles.removeAt(i);
            profiles.insert(
                0,
                BrowserProfile(
                  name: hit.name,
                  path: hit.path,
                  installKind: hit.installKind,
                  markedDefault: true,
                ));
            break;
          }
        }
      } catch (_) {}
    }
    if (profiles.isEmpty) {
      // No usable profiles.ini: fall back to scanning for profile dirs.
      final dirs = [
        Directory(p.join(root, 'Profiles')),
        Directory(root),
      ];
      for (final dir in dirs) {
        if (!dir.existsSync()) continue;
        for (final entity in dir.listSync().whereType<Directory>()) {
          if (File(p.join(entity.path, 'cookies.sqlite')).existsSync()) {
            profiles.add(BrowserProfile(
                name: p.basename(entity.path),
                path: entity.path,
                installKind: installKind));
          }
        }
      }
    }
    if (profiles.isEmpty) return null;

    bool named(BrowserProfile x, String s) =>
        x.name.toLowerCase().contains(s) ||
        p.basename(x.path).toLowerCase().contains(s);

    // Only profiles with a cookie database are useful here.
    final withCookies = profiles.where((x) => x.hasCookies).toList();
    final pool = withCookies.isNotEmpty ? withCookies : profiles;

    for (final test in <bool Function(BrowserProfile)>[
      (x) => x.markedDefault,
      (x) => named(x, 'default-release'),
      (x) => named(x, 'default'),
    ]) {
      final hit = pool.where(test);
      if (hit.isNotEmpty) return hit.first;
    }
    return pool.first;
  }

  /// Turn a path the user pasted into a usable profile.
  ///
  /// Accepts either the profile directory itself (the "Root Directory"
  /// shown on about:profiles, containing cookies.sqlite) or the
  /// installation root that holds profiles.ini — people reasonably
  /// paste either one.
  static BrowserProfile? resolveManualPath(String? raw) {
    var path = raw?.trim();
    if (path == null || path.isEmpty) return null;
    // Tolerate quotes and a trailing separator from copy/paste.
    if (path.length > 1 &&
        ((path.startsWith('"') && path.endsWith('"')) ||
            (path.startsWith("'") && path.endsWith("'")))) {
      path = path.substring(1, path.length - 1);
    }
    path = path.trim();
    if (path.length > 1 &&
        (path.endsWith('/') || path.endsWith(r'\'))) {
      path = path.substring(0, path.length - 1);
    }
    if (!Directory(path).existsSync()) return null;

    if (File(p.join(path, 'cookies.sqlite')).existsSync()) {
      return BrowserProfile(
        name: p.basename(path),
        path: path,
        installKind: 'Manual',
        markedDefault: true,
      );
    }
    if (File(p.join(path, 'profiles.ini')).existsSync()) {
      final main = mainProfileOfRoot(path, installKind: 'Manual');
      if (main != null) return main;
    }
    return null;
  }

  /// The main LibreWolf profile across every installation on this
  /// machine (system, Flatpak, Snap). When more than one installation
  /// exists, the one whose cookies were touched most recently wins —
  /// that's the copy actually being used.
  static BrowserProfile? findLibrewolf({Map<String, String>? env}) {
    final found = <BrowserProfile>[];
    for (final (kind, root) in rootsFor(env: env)) {
      final profile = mainProfileOfRoot(root, installKind: kind);
      if (profile != null) found.add(profile);
    }
    if (found.isEmpty) return null;
    if (found.length == 1) return found.first;
    found.sort((a, b) {
      final am = a.cookiesModified, bm = b.cookiesModified;
      if (am == null && bm == null) return 0;
      if (am == null) return 1;
      if (bm == null) return -1;
      return bm.compareTo(am); // newest first
    });
    return found.first;
  }
}
