import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models/download.dart';
import '../../services/convert_planner.dart';
import '../../services/download_manager.dart';
import '../../services/engine_options.dart';
import '../../services/link_scraper.dart';
import '../../services/presets.dart';
import '../../util/platform.dart';

class DownloadPage extends StatefulWidget {
  const DownloadPage({super.key});

  @override
  State<DownloadPage> createState() => _DownloadPageState();
}

class _DownloadPageState extends State<DownloadPage> {
  final _urlController = TextEditingController();
  String _lastText = '';

  void _submit(DownloadManager dm, [String? text]) {
    final url = (text ?? _urlController.text).trim();
    if (url.isEmpty) return;
    dm.addUrl(url);
    _urlController.clear();
    _lastText = '';
  }

  @override
  Widget build(BuildContext context) {
    final dm = context.watch<DownloadManager>();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 20, 20, 8),
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _urlController,
                  decoration: InputDecoration(
                    hintText:
                        'Paste a link — video, gallery, or any file. Multi picks the right tool and previews it first.',
                    prefixIcon: const Icon(Icons.link),
                    border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12)),
                    isDense: true,
                  ),
                  onChanged: (v) {
                    // A paste lands as one big change that parses as a URL:
                    // analyze it immediately (nothing downloads yet).
                    final grew = v.length - _lastText.length;
                    _lastText = v;
                    final uri = Uri.tryParse(v.trim());
                    final isUrl = v.trim().startsWith('magnet:') ||
                        (uri != null &&
                            (uri.isScheme('http') || uri.isScheme('https')) &&
                            uri.host.contains('.'));
                    if (grew > 5 && isUrl) _submit(dm, v);
                  },
                  onSubmitted: (v) => _submit(dm, v),
                ),
              ),
              const SizedBox(width: 8),
              FilledButton.icon(
                onPressed: () => _submit(dm),
                icon: const Icon(Icons.add),
                label: const Text('Add'),
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24),
          child: Row(
            children: [
              Icon(Icons.folder_outlined,
                  size: 16, color: Theme.of(context).colorScheme.outline),
              const SizedBox(width: 6),
              Flexible(
                child: InkWell(
                  onTap: () async {
                    final dir = await getDirectoryPath();
                    if (dir != null) dm.setDownloadDir(dir);
                  },
                  child: Text(
                    dm.downloadDir ?? '…',
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
              ),
              const Spacer(),
              Text(
                'Nothing downloads until you hit Start',
                style: Theme.of(context)
                    .textTheme
                    .bodySmall
                    ?.copyWith(color: Theme.of(context).colorScheme.outline),
              ),
            ],
          ),
        ),
        const Divider(height: 24),
        Expanded(
          child: dm.tasks.isEmpty
              ? Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.file_download_outlined,
                          size: 56,
                          color: Theme.of(context).colorScheme.outlineVariant),
                      const SizedBox(height: 12),
                      Text('Nothing here yet',
                          style: Theme.of(context).textTheme.titleMedium),
                      const SizedBox(height: 4),
                      Text(
                        'Videos go to yt-dlp, galleries to gallery-dl,\neverything else to aria2 — automatically.',
                        textAlign: TextAlign.center,
                        style: Theme.of(context)
                            .textTheme
                            .bodySmall
                            ?.copyWith(
                                color:
                                    Theme.of(context).colorScheme.outline),
                      ),
                    ],
                  ),
                )
              : ListView.builder(
                  padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
                  itemCount: dm.tasks.length,
                  itemBuilder: (_, i) => _TaskCard(task: dm.tasks[i]),
                ),
        ),
      ],
    );
  }
}

class _TaskCard extends StatefulWidget {
  final DownloadTask task;
  const _TaskCard({required this.task});

  @override
  State<_TaskCard> createState() => _TaskCardState();
}

class _TaskCardState extends State<_TaskCard> {
  bool _showLog = false;

  Color _statusColor(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return switch (widget.task.status) {
      TaskStatus.done => Colors.green,
      TaskStatus.failed => cs.error,
      TaskStatus.canceled => cs.outline,
      TaskStatus.running => cs.primary,
      _ => cs.secondary,
    };
  }

  bool get _configurable =>
      widget.task.status == TaskStatus.ready ||
      widget.task.status == TaskStatus.awaitingChoice ||
      widget.task.status == TaskStatus.needsCookies;

  @override
  Widget build(BuildContext context) {
    final task = widget.task;
    final dm = context.read<DownloadManager>();
    final host = Uri.tryParse(task.url)?.host ?? '';
    final cookiesHint = Presets.cookiesRecommendedFor(host) &&
        task.options.cookieSource == CookieSource.none;

    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                _EngineChip(task: task),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(task.preview?.title ?? task.title ?? task.url,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.titleSmall),
                      if ((task.preview?.title ?? task.title) != null)
                        Text(task.url,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context)
                                .textTheme
                                .bodySmall
                                ?.copyWith(
                                    color: Theme.of(context)
                                        .colorScheme
                                        .outline)),
                    ],
                  ),
                ),
                ..._actions(context, dm, task),
              ],
            ),
            if (task.status == TaskStatus.needsCookies) _CookieGate(task: task),
            if (task.status == TaskStatus.needsEngine)
              _EngineChooser(task: task),
            if (task.status == TaskStatus.ready) _PreviewSection(task: task),
            const SizedBox(height: 8),
            if (task.status == TaskStatus.running ||
                task.status == TaskStatus.done)
              LinearProgressIndicator(
                value: task.progress,
                minHeight: 6,
                borderRadius: BorderRadius.circular(4),
              ),
            const SizedBox(height: 6),
            Row(
              children: [
                Icon(Icons.circle, size: 8, color: _statusColor(context)),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(task.statusLine,
                      maxLines: 4,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodySmall),
                ),
                if (_configurable || task.status == TaskStatus.queued) ...[
                  _PresetChip(task: task),
                  const SizedBox(width: 8),
                ],
              ],
            ),
            if (task.status == TaskStatus.running ||
                (task.status == TaskStatus.done && task.parts.isNotEmpty))
              _PartBars(task: task),
            if (cookiesHint && _configurable)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Row(children: [
                  Icon(Icons.cookie_outlined,
                      size: 14,
                      color: Theme.of(context).colorScheme.tertiary),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      '$host usually needs log-in cookies — set them in Options to avoid errors and bot checks.',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: Theme.of(context).colorScheme.tertiary),
                    ),
                  ),
                ]),
              ),
            if (_showLog)
              Container(
                margin: const EdgeInsets.only(top: 8),
                padding: const EdgeInsets.all(8),
                width: double.infinity,
                constraints: const BoxConstraints(maxHeight: 180),
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: SingleChildScrollView(
                  reverse: true,
                  child: SelectableText(
                    task.log.join('\n'),
                    style: const TextStyle(
                        fontFamily: 'monospace', fontSize: 11.5),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  List<Widget> _actions(
      BuildContext context, DownloadManager dm, DownloadTask task) {
    return [
      if (task.status == TaskStatus.awaitingChoice)
        FilledButton.tonalIcon(
          onPressed: () => showDialog(
            context: context,
            builder: (_) => LinkPickerDialog(task: task),
          ),
          icon: const Icon(Icons.checklist, size: 18),
          label: const Text('Choose files'),
        ),
      if (task.status == TaskStatus.ready)
        FilledButton.icon(
          onPressed: () => dm.startTask(task),
          icon: const Icon(Icons.download, size: 18),
          label: const Text('Start'),
        ),
      if (_configurable || task.status == TaskStatus.queued)
        IconButton(
          tooltip: 'Options',
          icon: const Icon(Icons.tune),
          onPressed: () => showDialog(
            context: context,
            builder: (_) => TaskOptionsDialog(task: task),
          ),
        ),
      if (task.status == TaskStatus.done)
        IconButton(
          tooltip: 'Open folder',
          icon: const Icon(Icons.folder_open),
          onPressed: () => PlatformUtil.revealInFileManager(
              task.options.outputDir ?? dm.downloadDir ?? '.'),
        ),
      if (task.status == TaskStatus.failed ||
          task.status == TaskStatus.canceled)
        IconButton(
          tooltip: 'Retry',
          icon: const Icon(Icons.refresh),
          onPressed: () => dm.retryTask(task),
        ),
      IconButton(
        tooltip: 'Log',
        icon: Icon(_showLog ? Icons.terminal : Icons.terminal_outlined),
        onPressed: () => setState(() => _showLog = !_showLog),
      ),
      if (task.status == TaskStatus.running ||
          task.status == TaskStatus.queued ||
          task.status == TaskStatus.resolving)
        IconButton(
          tooltip: 'Cancel',
          icon: const Icon(Icons.stop_circle_outlined),
          onPressed: () => dm.cancelTask(task),
        )
      else
        IconButton(
          tooltip: 'Remove',
          icon: const Icon(Icons.close),
          onPressed: () => dm.removeTask(task),
        ),
    ];
  }
}

/// Shown when no downloader claims the URL and it isn't a file link.
/// Multi asks instead of guessing an engine.
class _EngineChooser extends StatelessWidget {
  final DownloadTask task;
  const _EngineChooser({required this.task});

  @override
  Widget build(BuildContext context) {
    final dm = context.read<DownloadManager>();
    final cs = Theme.of(context).colorScheme;
    return Container(
      margin: const EdgeInsets.only(top: 10),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: cs.surfaceContainerHighest.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: cs.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.help_outline, size: 18, color: cs.secondary),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Neither yt-dlp nor gallery-dl supports this site, and the '
                  'link isn\'t a file. How should Multi handle it?',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              FilledButton.tonalIcon(
                onPressed: () => dm.scanPageForFiles(task),
                icon: const Icon(Icons.checklist, size: 18),
                label: const Text('Scan page for files'),
              ),
              OutlinedButton.icon(
                onPressed: () => dm.useEngine(task, Engine.ytDlp),
                icon: const Icon(Icons.smart_display_outlined, size: 18),
                label: const Text('Try yt-dlp anyway'),
              ),
              OutlinedButton.icon(
                onPressed: () => dm.useEngine(task, Engine.galleryDl),
                icon: const Icon(Icons.photo_library_outlined, size: 18),
                label: const Text('Try gallery-dl anyway'),
              ),
              OutlinedButton.icon(
                onPressed: () => dm.useEngine(task, Engine.aria2),
                icon: const Icon(Icons.bolt, size: 18),
                label: const Text('Download this URL directly'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Shown for login-walled sites before Multi makes any request: pick
/// cookies (or explicitly decline) and only then does it look at the page.
class _CookieGate extends StatefulWidget {
  final DownloadTask task;
  const _CookieGate({required this.task});

  @override
  State<_CookieGate> createState() => _CookieGateState();
}

class _CookieGateState extends State<_CookieGate> {
  bool _remember = true;

  @override
  Widget build(BuildContext context) {
    final dm = context.watch<DownloadManager>();
    final cs = Theme.of(context).colorScheme;
    final o = widget.task.options;
    final host = Uri.tryParse(widget.task.url)?.host ?? '';
    final ready = switch (o.cookieSource) {
      CookieSource.none => false,
      CookieSource.file => o.cookieFilePath != null,
      CookieSource.librewolf => dm.librewolfProfile != null,
      _ => true,
    };

    return Container(
      margin: const EdgeInsets.only(top: 10),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: cs.tertiaryContainer.withValues(alpha: 0.30),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: cs.tertiary.withValues(alpha: 0.4)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.cookie_outlined, size: 18, color: cs.tertiary),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  '$host hides content from logged-out visitors. Choose your '
                  'cookies first — nothing has been requested from the site yet.',
                  style: Theme.of(context)
                      .textTheme
                      .bodySmall
                      ?.copyWith(color: cs.onSurface),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: DropdownButton<CookieSource>(
                  isExpanded: true,
                  isDense: true,
                  value: o.cookieSource,
                  items: [
                    for (final c in CookieSource.values)
                      if (c.availableOnThisOs)
                        DropdownMenuItem(value: c, child: Text(c.label)),
                  ],
                  onChanged: (v) async {
                    if (v == null) return;
                    if (v == CookieSource.file) {
                      final f = await openFile(acceptedTypeGroups: [
                        const XTypeGroup(
                            label: 'Cookies', extensions: ['txt'])
                      ]);
                      if (f == null) return;
                      o.cookieFilePath = f.path;
                    }
                    o.cookieSource = v;
                    dm.touch();
                  },
                ),
              ),
              const SizedBox(width: 12),
              FilledButton.icon(
                onPressed: ready
                    ? () {
                        if (_remember) {
                          dm.setDefaultCookieSource(o.cookieSource);
                        }
                        dm.continueAfterCookies(widget.task);
                      }
                    : null,
                icon: const Icon(Icons.arrow_forward, size: 18),
                label: const Text('Continue'),
              ),
            ],
          ),
          if (o.cookieSource == CookieSource.librewolf)
            const LibrewolfProfileField(),
          if (o.cookieSource == CookieSource.file && o.cookieFilePath != null)
            Text(o.cookieFilePath!,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.labelSmall),
          Row(
            children: [
              Checkbox(
                value: _remember,
                visualDensity: VisualDensity.compact,
                onChanged: (v) => setState(() => _remember = v ?? false),
              ),
              Expanded(
                child: Text('Remember this choice for future downloads',
                    style: Theme.of(context).textTheme.bodySmall),
              ),
              TextButton(
                onPressed: () => dm.continueAfterCookies(widget.task),
                child: const Text('Continue without cookies'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// LibreWolf profile picker: a box to paste the profile folder, with
/// instructions for finding it. Neither yt-dlp nor gallery-dl knows
/// LibreWolf by name, so Multi passes the folder as a Firefox profile.
class LibrewolfProfileField extends StatefulWidget {
  final bool browserSupported;
  const LibrewolfProfileField({super.key, this.browserSupported = true});

  @override
  State<LibrewolfProfileField> createState() => _LibrewolfProfileFieldState();
}

class _LibrewolfProfileFieldState extends State<LibrewolfProfileField> {
  late final TextEditingController _controller = TextEditingController(
      text: context.read<DownloadManager>().librewolfManualPath ?? '');

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  static String get _whereToLook {
    if (Platform.isWindows) return r'usually %APPDATA%\librewolf\Profiles\…';
    if (Platform.isMacOS) {
      return 'usually ~/Library/Application Support/LibreWolf/Profiles/…';
    }
    return 'usually ~/.librewolf/… , or ~/.var/app/io.gitlab.librewolf-community/… for Flatpak';
  }

  @override
  Widget build(BuildContext context) {
    final dm = context.watch<DownloadManager>();
    final cs = Theme.of(context).colorScheme;
    final small = Theme.of(context).textTheme.bodySmall;
    final label = Theme.of(context).textTheme.labelSmall;

    if (!widget.browserSupported) {
      return Text(
        'aria2 can\'t read browser cookies — export a cookie file instead.',
        style: small?.copyWith(color: cs.outline),
      );
    }

    final detected = dm.librewolfDetected;
    final active = dm.librewolfProfile;
    final error = dm.librewolfManualPathError;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 6),
        Container(
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: cs.surfaceContainerHighest.withValues(alpha: 0.5),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(Icons.info_outline, size: 14, color: cs.outline),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      'In LibreWolf open about:profiles, find the profile marked '
                      '“This is the profile in use”, and copy its Root Directory.',
                      style: small,
                    ),
                  ),
                ],
              ),
              Padding(
                padding: const EdgeInsets.only(left: 20, top: 2),
                child: Text(_whereToLook,
                    style: label?.copyWith(color: cs.outline)),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: _controller,
                decoration: InputDecoration(
                  labelText: 'LibreWolf profile folder',
                  hintText: 'paste the Root Directory here',
                  isDense: true,
                  border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8)),
                  errorText: error,
                  helperText: error == null && active != null
                      ? 'Found ${active.name}'
                          '${active.hasCookies ? ' with cookies.sqlite' : ' (no cookies.sqlite yet)'}'
                      : null,
                  suffixIcon: _controller.text.trim().isEmpty
                      ? null
                      : IconButton(
                          tooltip: 'Clear',
                          icon: const Icon(Icons.clear, size: 18),
                          onPressed: () {
                            _controller.clear();
                            dm.setLibrewolfManualPath(null);
                            setState(() {});
                          },
                        ),
                ),
                style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
                onChanged: (v) {
                  dm.setLibrewolfManualPath(v);
                  setState(() {});
                },
              ),
              const SizedBox(height: 4),
              Row(
                children: [
                  if (detected != null)
                    TextButton.icon(
                      onPressed: () {
                        _controller.text = detected.path;
                        dm.setLibrewolfManualPath(detected.path);
                        setState(() {});
                      },
                      icon: const Icon(Icons.auto_fix_high, size: 16),
                      label: Text('Use detected (${detected.installKind})'),
                    )
                  else
                    TextButton.icon(
                      onPressed: () {
                        dm.rescanBrowserProfiles();
                        setState(() {});
                      },
                      icon: const Icon(Icons.refresh, size: 16),
                      label: const Text('Try auto-detect'),
                    ),
                  const Spacer(),
                  if (active != null && error == null)
                    Row(children: [
                      const Icon(Icons.check_circle_outline,
                          size: 14, color: Colors.green),
                      const SizedBox(width: 4),
                      Text('ready', style: label?.copyWith(color: Colors.green)),
                    ]),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// One progress bar per item of a multi-item download: every video of a
/// playlist, or every file of a parallel aria2 batch. Items that haven't
/// started yet show as waiting so the list matches the item count.
class _PartBars extends StatelessWidget {
  final DownloadTask task;
  const _PartBars({required this.task});

  /// Very long playlists would produce an unusable wall of bars; show
  /// the ones in flight plus finished, and summarize the rest.
  static const _maxRows = 40;

  @override
  Widget build(BuildContext context) {
    final total = task.partsTotal ?? 0;
    final known = task.parts;
    // Only engines that report per-item progress get rows. gallery-dl
    // reports whole files with no per-file progress, so it uses the
    // single overall bar instead of a row per picture.
    if (known.isEmpty) return const SizedBox.shrink();
    if (total <= 1 && known.length <= 1) return const SizedBox.shrink();

    // Playlist keys are 1..N, so gaps can be filled with placeholders.
    final numeric = known.keys.every((k) => int.tryParse(k) != null);
    final rows = <DownloadPart?>[];
    if (numeric && total > 0) {
      for (var i = 1; i <= total; i++) {
        rows.add(known['$i']);
      }
    } else {
      rows.addAll(task.sortedParts);
    }

    var shown = rows;
    var hidden = 0;
    var hiddenAreEarlier = false;
    if (rows.length > _maxRows) {
      if (numeric && total > 0) {
        // Known playlist: keep the started/finished ones in order.
        final active = rows.where((r) => r != null).toList();
        shown = (active.length >= _maxRows
                ? active
                : [...active, ...rows.where((r) => r == null)])
            .take(_maxRows)
            .toList();
      } else {
        // Unknown total (a gallery): the newest files are the
        // interesting ones.
        shown = rows.sublist(rows.length - _maxRows);
        hiddenAreEarlier = true;
      }
      hidden = rows.length - shown.length;
    }

    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (var i = 0; i < shown.length; i++)
            _row(context, shown[i], numeric ? '${i + 1}' : null),
          if (hidden > 0)
            Padding(
              padding: const EdgeInsets.only(top: 4, left: 2),
              child: Text(
                  hiddenAreEarlier
                      ? '+ $hidden earlier files'
                      : '+ $hidden more waiting',
                  style: Theme.of(context)
                      .textTheme
                      .labelSmall
                      ?.copyWith(color: cs.outline)),
            ),
        ],
      ),
    );
  }

  Widget _row(BuildContext context, DownloadPart? part, String? fallbackKey) {
    final cs = Theme.of(context).colorScheme;
    final label = part?.label ?? '#$fallbackKey';
    final waiting = part == null;
    final done = part?.done ?? false;
    final title = part?.title;
    final detail = waiting
        ? 'waiting'
        : done
            ? (part.speed ?? 'done')
            : [
                '${part.percent}%',
                if (part.speed != null) part.speed!,
                if (part.eta != null) 'ETA ${part.eta}',
              ].join(' · ');

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        children: [
          SizedBox(
            width: 34,
            child: Text(label,
                style: Theme.of(context).textTheme.labelSmall?.copyWith(
                    color: cs.outline, fontFeatures: const [])),
          ),
          Expanded(
            flex: 3,
            child: LinearProgressIndicator(
              value: waiting ? 0 : part.fraction,
              minHeight: 4,
              borderRadius: BorderRadius.circular(3),
              color: done ? Colors.green : cs.primary,
              backgroundColor: cs.surfaceContainerHighest,
            ),
          ),
          const SizedBox(width: 8),
          SizedBox(
            width: 168,
            child: Text(detail,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.labelSmall?.copyWith(
                    color: done ? Colors.green : cs.onSurfaceVariant)),
          ),
          Expanded(
            flex: 4,
            child: Text(title ?? '',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context)
                    .textTheme
                    .labelSmall
                    ?.copyWith(color: cs.outline)),
          ),
        ],
      ),
    );
  }
}

/// Everything Multi learned before downloading: thumbnail, formats,
/// gallery sample, or server file info — plus convert-after-download.
class _PreviewSection extends StatelessWidget {
  final DownloadTask task;
  const _PreviewSection({required this.task});

  String _fmtDuration(double seconds) {
    final d = Duration(seconds: seconds.round());
    final h = d.inHours, m = d.inMinutes % 60, s = d.inSeconds % 60;
    String two(int n) => n.toString().padLeft(2, '0');
    return h > 0 ? '$h:${two(m)}:${two(s)}' : '$m:${two(s)}';
  }

  @override
  Widget build(BuildContext context) {
    final pv = task.preview;
    final cs = Theme.of(context).colorScheme;

    return Padding(
      padding: const EdgeInsets.only(top: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (pv != null && task.engine == Engine.ytDlp)
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (pv.thumbnailUrl != null)
                  ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: Image.network(
                      pv.thumbnailUrl!,
                      width: 128,
                      height: 72,
                      fit: BoxFit.cover,
                      errorBuilder: (_, _, _) => const SizedBox.shrink(),
                    ),
                  ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        [
                          if (pv.uploader != null) pv.uploader!,
                          if (pv.durationSeconds != null)
                            _fmtDuration(pv.durationSeconds!),
                          if ((pv.playlistCount ?? 0) > 1)
                            'playlist · ${pv.playlistCount} items',
                        ].join(' · '),
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                      const SizedBox(height: 6),
                      Wrap(
                        spacing: 8,
                        runSpacing: 4,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          _FormatPresetChip(task: task),
                          _ConvertAfterChip(task: task),
                        ],
                      ),
                    ],
                  ),
                ),
              ],
            ),
          if (pv != null &&
              task.engine == Engine.galleryDl &&
              pv.sampleItems.isNotEmpty) ...[
            Text('Sample of the gallery:',
                style: Theme.of(context).textTheme.bodySmall),
            const SizedBox(height: 4),
            Wrap(
              spacing: 6,
              runSpacing: 4,
              children: [
                for (final item in pv.sampleItems.take(8))
                  Chip(
                    label: Text(item,
                        style: Theme.of(context).textTheme.labelSmall),
                    visualDensity: VisualDensity.compact,
                    materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                _ConvertAfterChip(task: task),
              ],
            ),
          ],
          if (task.engine == Engine.aria2)
            Wrap(
              spacing: 8,
              runSpacing: 4,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                if (pv?.fileName != null)
                  Chip(
                    avatar: const Icon(Icons.insert_drive_file_outlined,
                        size: 16),
                    label: Text(
                      [
                        pv!.fileName!,
                        if (pv.fileSize != null)
                          PlatformUtil.humanBytes(pv.fileSize!),
                        if (pv.contentType != null) pv.contentType!,
                      ].join(' · '),
                      style: Theme.of(context).textTheme.labelSmall,
                    ),
                    visualDensity: VisualDensity.compact,
                    materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                _ConvertAfterChip(task: task),
              ],
            ),
          if (task.options.convertTo != null)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                'After downloading, media files go straight to Convert (remux-first).',
                style: Theme.of(context)
                    .textTheme
                    .bodySmall
                    ?.copyWith(color: cs.tertiary),
              ),
            ),
        ],
      ),
    );
  }
}

/// Format preset menu: quick choices with descriptions, plus the full
/// custom format picker.
class _FormatPresetChip extends StatelessWidget {
  final DownloadTask task;
  const _FormatPresetChip({required this.task});

  static const _presets = <(String, String, String)>[
    // (key, title, description)
    ('auto', 'Best (auto)', 'Highest quality yt-dlp can find'),
    (
      'compat',
      'Most compatible',
      'H.264 video + AAC audio when available — plays on everything'
    ),
    ('audio', 'Audio only', 'Best audio track, no video'),
    ('custom', 'Custom…', 'Pick from every available format'),
  ];

  void _apply(BuildContext context, String key) {
    final dm = context.read<DownloadManager>();
    switch (key) {
      case 'auto':
        task.chosenFormat = null;
        task.formatSort = null;
        task.chosenFormatLabel = null;
        break;
      case 'compat':
        task.chosenFormat = null;
        task.formatSort = 'vcodec:h264,acodec:aac';
        task.chosenFormatLabel = 'Format: Most compatible';
        break;
      case 'audio':
        task.chosenFormat = 'bestaudio';
        task.formatSort = null;
        task.chosenFormatLabel = 'Format: Audio only';
        break;
      case 'custom':
        showDialog(
          context: context,
          builder: (_) => FormatPickerDialog(task: task),
        );
        return;
    }
    dm.touch();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final hasFormats = (task.preview?.formats.isNotEmpty ?? false);
    return PopupMenuButton<String>(
      tooltip: 'Which version to download',
      onSelected: (k) => _apply(context, k),
      itemBuilder: (_) => [
        for (final (key, title, desc) in _presets)
          if (key != 'custom' || hasFormats)
            PopupMenuItem(
              value: key,
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 340),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(title),
                    Text(desc,
                        style: Theme.of(context)
                            .textTheme
                            .bodySmall
                            ?.copyWith(color: cs.outline)),
                  ],
                ),
              ),
            ),
      ],
      child: Chip(
        avatar: const Icon(Icons.video_settings, size: 16),
        label: Text(task.chosenFormatLabel ?? 'Format: Best (auto)'),
        labelStyle: Theme.of(context).textTheme.labelSmall,
        visualDensity: VisualDensity.compact,
        materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
      ),
    );
  }
}

class _ConvertAfterChip extends StatelessWidget {
  final DownloadTask task;
  const _ConvertAfterChip({required this.task});

  @override
  Widget build(BuildContext context) {
    final dm = context.read<DownloadManager>();
    final current = task.options.convertTo;
    final spec = current == null
        ? null
        : containerSpecs.where((c) => c.id == current).firstOrNull;
    return PopupMenuButton<String>(
      tooltip: 'Convert after downloading',
      initialValue: current ?? '',
      onSelected: (v) {
        task.options.convertTo = v.isEmpty ? null : v;
        dm.touch();
      },
      itemBuilder: (_) => [
        const PopupMenuItem(value: '', child: Text('Don\'t convert')),
        const PopupMenuDivider(),
        for (final c in containerSpecs)
          PopupMenuItem(
              value: c.id,
              child: Text('${c.label}${c.audioOnly ? '  (audio)' : ''}')),
      ],
      child: Chip(
        avatar: Icon(
            spec == null ? Icons.swap_horiz : Icons.swap_horizontal_circle,
            size: 16),
        label: Text(spec == null
            ? 'Convert after: off'
            : 'Convert after: ${spec.label}'),
        labelStyle: Theme.of(context).textTheme.labelSmall,
        visualDensity: VisualDensity.compact,
        materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
      ),
    );
  }
}

class _EngineChip extends StatelessWidget {
  final DownloadTask task;
  const _EngineChip({required this.task});

  static (IconData, String) _iconFor(Engine e) => switch (e) {
        Engine.ytDlp => (Icons.smart_display_outlined, 'yt-dlp'),
        Engine.galleryDl => (Icons.photo_library_outlined, 'gallery-dl'),
        Engine.aria2 => (Icons.bolt, 'aria2'),
      };

  @override
  Widget build(BuildContext context) {
    final dm = context.read<DownloadManager>();
    final busy = task.status == TaskStatus.resolving ||
        task.status == TaskStatus.running ||
        task.status == TaskStatus.queued;
    final (icon, label) = task.status == TaskStatus.resolving
        ? (Icons.psychology_outlined, 'deciding…')
        : _iconFor(task.engine);

    final chip = Chip(
      avatar: Icon(icon, size: 16),
      label: Text(label),
      labelStyle: Theme.of(context).textTheme.labelSmall,
      visualDensity: VisualDensity.compact,
      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
    );
    if (busy) {
      return Tooltip(
        message: 'Engine chosen automatically for this link',
        child: chip,
      );
    }
    // Automatic routing can be wrong; let it be corrected in one click.
    return PopupMenuButton<Engine>(
      tooltip: 'Engine — click to use a different one',
      initialValue: task.engine,
      onSelected: (e) {
        if (e != task.engine) dm.useEngine(task, e);
      },
      itemBuilder: (_) => [
        for (final e in Engine.values)
          PopupMenuItem(
            value: e,
            child: Row(children: [
              Icon(_iconFor(e).$1, size: 16),
              const SizedBox(width: 8),
              Text(e.displayName),
            ]),
          ),
      ],
      child: chip,
    );
  }
}

class _PresetChip extends StatelessWidget {
  final DownloadTask task;
  const _PresetChip({required this.task});

  @override
  Widget build(BuildContext context) {
    final dm = context.read<DownloadManager>();
    final host = Uri.tryParse(task.url)?.host ?? '';
    final recommended = Presets.recommendedFor(host);
    return PopupMenuButton<PresetId>(
      tooltip: 'Preset — auto-picked for this site',
      initialValue: task.options.preset,
      onSelected: (p) {
        task.options.preset = p;
        dm.touch();
      },
      itemBuilder: (_) => [
        for (final p in PresetId.values)
          PopupMenuItem(
            value: p,
            child: ListTile(
              contentPadding: EdgeInsets.zero,
              dense: true,
              title: Text(
                  '${p.label}${p == recommended ? '  ★ recommended' : ''}'),
              subtitle: Text(p.description,
                  style: Theme.of(context).textTheme.bodySmall),
            ),
          ),
      ],
      child: Chip(
        avatar: Icon(
          switch (task.options.preset) {
            PresetId.speed => Icons.speed,
            PresetId.balanced => Icons.balance,
            PresetId.gentle => Icons.visibility_off_outlined,
          },
          size: 16,
        ),
        label: Text(task.options.preset.label +
            (task.options.preset == recommended ? ' ★' : '')),
        labelStyle: Theme.of(context).textTheme.labelSmall,
        visualDensity: VisualDensity.compact,
        materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
      ),
    );
  }
}

/// Full format list from yt-dlp: pick a combined format, a video+audio
/// pair, or audio only — with containers, codecs, and estimated sizes.
class FormatPickerDialog extends StatefulWidget {
  final DownloadTask task;
  const FormatPickerDialog({super.key, required this.task});

  @override
  State<FormatPickerDialog> createState() => _FormatPickerDialogState();
}

class _FormatPickerDialogState extends State<FormatPickerDialog> {
  String _video = 'auto'; // 'auto' | 'none' | format id
  String _audio = 'auto'; // 'auto' | 'none' | format id

  List<MediaFormat> get _formats => widget.task.preview?.formats ?? [];

  MediaFormat? _byId(String id) =>
      _formats.where((f) => f.id == id).firstOrNull;

  bool get _videoIsCombined {
    final f = _video == 'auto' || _video == 'none' ? null : _byId(_video);
    return f != null && f.hasAudio;
  }

  (String?, String) _compose() {
    // Returns (-f value or null for default, human label).
    if (_video == 'auto' && _audio == 'auto') return (null, 'Best (auto)');
    if (_video == 'none') {
      if (_audio == 'auto') return ('bestaudio', 'Audio only — best');
      final a = _byId(_audio);
      return (_audio, 'Audio only — ${a?.ext ?? _audio}');
    }
    if (_video == 'auto') {
      if (_audio == 'none') return ('bestvideo', 'Best video, no audio');
      final a = _byId(_audio);
      return ('bestvideo+$_audio', 'Best video + ${a?.ext ?? 'audio'}');
    }
    final v = _byId(_video)!;
    final label = StringBuffer(
        '${v.height != null ? '${v.height}p' : v.ext}${v.fps != null && v.fps! > 30 ? v.fps!.round() : ''} ${v.ext}');
    if (_videoIsCombined) return (_video, '$label (A/V)');
    if (_audio == 'none') return (_video, '$label, no audio');
    if (_audio == 'auto') {
      return ('$_video+bestaudio/$_video', '$label + best audio');
    }
    final a = _byId(_audio);
    return ('$_video+$_audio', '$label + ${a?.ext ?? 'audio'}');
  }

  int? _estimatedTotal() {
    var total = 0;
    var known = false;
    if (_video != 'auto' && _video != 'none') {
      final v = _byId(_video);
      if (v?.filesize != null) {
        total += v!.filesize!;
        known = true;
      }
    }
    if (!_videoIsCombined && _audio != 'auto' && _audio != 'none') {
      final a = _byId(_audio);
      if (a?.filesize != null) {
        total += a!.filesize!;
        known = true;
      }
    }
    return known ? total : null;
  }

  /// Small line under a format: what its codecs mean for playback.
  Widget? _codecBlurbs(BuildContext context, MediaFormat f) {
    final parts = <String>[
      if (f.hasVideo && shortBlurbForRawCodec(f.vcodec) != null)
        '${MediaFormat.prettyCodec(f.vcodec)}: ${shortBlurbForRawCodec(f.vcodec)}',
      if (f.hasAudio && shortBlurbForRawCodec(f.acodec) != null)
        '${MediaFormat.prettyCodec(f.acodec)}: ${shortBlurbForRawCodec(f.acodec)}',
      if (f.hasVideo && f.hasAudio) 'includes audio',
    ];
    if (parts.isEmpty) return null;
    return Text(parts.join(' · '),
        style: Theme.of(context)
            .textTheme
            .labelSmall
            ?.copyWith(color: Theme.of(context).colorScheme.outline));
  }

  String _fmtRow(MediaFormat f) {
    final parts = <String>[
      f.ext,
      if (f.hasVideo && f.height != null)
        '${f.height}p${f.fps != null && f.fps! > 31 ? f.fps!.round() : ''}',
      if (f.hasVideo) MediaFormat.prettyCodec(f.vcodec),
      if (f.hasAudio) MediaFormat.prettyCodec(f.acodec),
      if (f.language != null) f.language!,
      if (f.note.isNotEmpty) f.note,
      if (f.tbr != null) '${f.tbr!.round()} kbps',
      if (f.filesize != null)
        '${f.sizeIsEstimate ? '~' : ''}${PlatformUtil.humanBytes(f.filesize!)}',
    ];
    return parts.join(' · ');
  }

  @override
  Widget build(BuildContext context) {
    final dm = context.read<DownloadManager>();
    final videoFormats = _formats.where((f) => f.hasVideo).toList();
    final audioFormats =
        _formats.where((f) => f.hasAudio && !f.hasVideo).toList();
    final (fValue, label) = _compose();
    final est = _estimatedTotal();

    return AlertDialog(
      title: const Text('Pick a format'),
      content: SizedBox(
        width: 720,
        height: 500,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Video', style: Theme.of(context).textTheme.titleSmall),
                  Expanded(
                    child: RadioGroup<String>(
                      groupValue: _video,
                      onChanged: (v) => setState(() => _video = v!),
                      child: ListView(
                        children: [
                          const RadioListTile<String>(
                            dense: true,
                            value: 'auto',
                            title: Text('Best (auto)'),
                          ),
                          const RadioListTile<String>(
                            dense: true,
                            value: 'none',
                            title: Text('No video (audio only)'),
                          ),
                          for (final f in videoFormats)
                            RadioListTile<String>(
                              dense: true,
                              value: f.id,
                              title: Text(_fmtRow(f),
                                  style:
                                      Theme.of(context).textTheme.bodySmall),
                              subtitle: _codecBlurbs(context, f),
                            ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const VerticalDivider(width: 24),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Audio', style: Theme.of(context).textTheme.titleSmall),
                  Expanded(
                    child: _videoIsCombined
                        ? Center(
                            child: Text(
                              'The chosen video format\nalready includes audio.',
                              textAlign: TextAlign.center,
                              style: Theme.of(context)
                                  .textTheme
                                  .bodySmall
                                  ?.copyWith(
                                      color: Theme.of(context)
                                          .colorScheme
                                          .outline),
                            ),
                          )
                        : RadioGroup<String>(
                            groupValue: _audio,
                            onChanged: (v) => setState(() => _audio = v!),
                            child: ListView(
                              children: [
                                const RadioListTile<String>(
                                  dense: true,
                                  value: 'auto',
                                  title: Text('Best (auto)'),
                                ),
                                const RadioListTile<String>(
                                  dense: true,
                                  value: 'none',
                                  title: Text('No audio'),
                                ),
                                for (final f in audioFormats)
                                  RadioListTile<String>(
                                    dense: true,
                                    value: f.id,
                                    title: Text(_fmtRow(f),
                                        style: Theme.of(context)
                                            .textTheme
                                            .bodySmall),
                                    subtitle: _codecBlurbs(context, f),
                                  ),
                              ],
                            ),
                          ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
      actions: [
        if (est != null)
          Padding(
            padding: const EdgeInsets.only(right: 12),
            child: Text('Estimated download: ~${PlatformUtil.humanBytes(est)}',
                style: Theme.of(context).textTheme.bodySmall),
          ),
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () {
            widget.task.chosenFormat = fValue;
            widget.task.formatSort = null;
            widget.task.chosenFormatLabel = 'Format: $label';
            dm.touch();
            Navigator.pop(context);
          },
          child: Text('Use $label'),
        ),
      ],
    );
  }
}

/// Checklist of links scraped from a page that no extractor supports.
class LinkPickerDialog extends StatefulWidget {
  final DownloadTask task;
  const LinkPickerDialog({super.key, required this.task});

  @override
  State<LinkPickerDialog> createState() => _LinkPickerDialogState();
}

class _LinkPickerDialogState extends State<LinkPickerDialog> {
  String _filter = '';
  String _extFilter = '';

  @override
  Widget build(BuildContext context) {
    final dm = context.read<DownloadManager>();
    final links = dm.scrapedLinks[widget.task.id] ?? <ScrapedLink>[];
    final exts = links.map((l) => l.extension).where((e) => e.isNotEmpty).toSet().toList()
      ..sort();
    final visible = links.where((l) {
      if (_extFilter.isNotEmpty && l.extension != _extFilter) return false;
      if (_filter.isNotEmpty &&
          !l.url.toLowerCase().contains(_filter.toLowerCase()) &&
          !l.label.toLowerCase().contains(_filter.toLowerCase())) {
        return false;
      }
      return true;
    }).toList();
    final selectedCount = links.where((l) => l.selected).length;

    return AlertDialog(
      title: const Text('Pick files to download'),
      content: SizedBox(
        width: 640,
        height: 480,
        child: Column(
          children: [
            Row(
              children: [
                Expanded(
                  child: TextField(
                    decoration: const InputDecoration(
                      hintText: 'Filter…',
                      prefixIcon: Icon(Icons.search, size: 18),
                      isDense: true,
                    ),
                    onChanged: (v) => setState(() => _filter = v),
                  ),
                ),
                const SizedBox(width: 8),
                TextButton(
                  onPressed: () => setState(() {
                    for (final l in visible) {
                      l.selected = true;
                    }
                  }),
                  child: const Text('All'),
                ),
                TextButton(
                  onPressed: () => setState(() {
                    for (final l in visible) {
                      l.selected = false;
                    }
                  }),
                  child: const Text('None'),
                ),
              ],
            ),
            if (exts.isNotEmpty)
              SizedBox(
                height: 40,
                child: ListView(
                  scrollDirection: Axis.horizontal,
                  children: [
                    Padding(
                      padding: const EdgeInsets.all(4),
                      child: FilterChip(
                        label: const Text('all types'),
                        selected: _extFilter.isEmpty,
                        onSelected: (_) => setState(() => _extFilter = ''),
                      ),
                    ),
                    for (final e in exts)
                      Padding(
                        padding: const EdgeInsets.all(4),
                        child: FilterChip(
                          label: Text('.$e'),
                          selected: _extFilter == e,
                          onSelected: (_) => setState(
                              () => _extFilter = _extFilter == e ? '' : e),
                        ),
                      ),
                  ],
                ),
              ),
            const SizedBox(height: 4),
            Expanded(
              child: ListView.builder(
                itemCount: visible.length,
                itemBuilder: (_, i) {
                  final l = visible[i];
                  return CheckboxListTile(
                    dense: true,
                    controlAffinity: ListTileControlAffinity.leading,
                    value: l.selected,
                    onChanged: (v) => setState(() => l.selected = v ?? false),
                    title: Text(l.label,
                        maxLines: 1, overflow: TextOverflow.ellipsis),
                    subtitle: Text(l.url,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.bodySmall),
                    secondary: l.extension.isEmpty
                        ? null
                        : Chip(
                            label: Text('.${l.extension}'),
                            visualDensity: VisualDensity.compact,
                            materialTapTargetSize:
                                MaterialTapTargetSize.shrinkWrap,
                          ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton.icon(
          onPressed: selectedCount == 0
              ? null
              : () {
                  dm.startScrapedTask(widget.task);
                  Navigator.pop(context);
                },
          icon: const Icon(Icons.download),
          label: Text('Download $selectedCount with aria2'),
        ),
      ],
    );
  }
}

/// Full options sheet for a task: preset, cookies, output, engine
/// options rendered from their definitions, extra args, and a live
/// preview of the exact command line.
class TaskOptionsDialog extends StatefulWidget {
  final DownloadTask task;
  const TaskOptionsDialog({super.key, required this.task});

  @override
  State<TaskOptionsDialog> createState() => _TaskOptionsDialogState();
}

class _TaskOptionsDialogState extends State<TaskOptionsDialog> {
  late final DownloadOptions o = widget.task.options;

  @override
  Widget build(BuildContext context) {
    final dm = context.read<DownloadManager>();
    final task = widget.task;
    final defs = EngineOptions.forEngine(task.engine);
    final groups = <String, List<OptionDef>>{};
    for (final d in defs) {
      groups.putIfAbsent(d.group, () => []).add(d);
    }
    final host = Uri.tryParse(task.url)?.host ?? '';
    final recommended = Presets.recommendedFor(host);
    final browserCookies = task.engine != Engine.aria2;

    return AlertDialog(
      title: Row(
        children: [
          Text('${task.engine.displayName} options'),
          const Spacer(),
          Text(host,
              style: Theme.of(context)
                  .textTheme
                  .bodySmall
                  ?.copyWith(color: Theme.of(context).colorScheme.outline)),
        ],
      ),
      content: SizedBox(
        width: 620,
        height: 520,
        child: ListView(
          children: [
            Text('Preset', style: Theme.of(context).textTheme.titleSmall),
            const SizedBox(height: 8),
            SegmentedButton<PresetId>(
              segments: [
                for (final p in PresetId.values)
                  ButtonSegment(
                    value: p,
                    label: Text(
                        p == recommended ? '${p.label} ★' : p.label),
                    icon: Icon(switch (p) {
                      PresetId.speed => Icons.speed,
                      PresetId.balanced => Icons.balance,
                      PresetId.gentle => Icons.visibility_off_outlined,
                    }),
                  ),
              ],
              selected: {o.preset},
              onSelectionChanged: (s) => setState(() => o.preset = s.first),
            ),
            const SizedBox(height: 4),
            Text(
              '${o.preset.description}${o.preset == recommended ? '  (recommended for $host)' : ''}',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Theme.of(context).colorScheme.outline),
            ),
            const SizedBox(height: 16),
            Text('Cookies', style: Theme.of(context).textTheme.titleSmall),
            const SizedBox(height: 4),
            if (!browserCookies)
              Text(
                'aria2 reads cookies from a Netscape-format file. Export one with a browser extension, or use yt-dlp/gallery-dl for sites needing login.',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            Row(
              children: [
                Expanded(
                  child: DropdownButton<CookieSource>(
                    isExpanded: true,
                    value: o.cookieSource,
                    items: [
                      for (final c in CookieSource.values)
                        if (c.availableOnThisOs &&
                            (browserCookies ||
                                c == CookieSource.none ||
                                c == CookieSource.file))
                          DropdownMenuItem(value: c, child: Text(c.label)),
                    ],
                    onChanged: (v) async {
                      if (v == null) return;
                      if (v == CookieSource.file) {
                        final f = await openFile(acceptedTypeGroups: [
                          const XTypeGroup(label: 'Cookies', extensions: ['txt'])
                        ]);
                        if (f == null) return;
                        o.cookieFilePath = f.path;
                      }
                      setState(() => o.cookieSource = v);
                    },
                  ),
                ),
              ],
            ),
            if (o.cookieSource == CookieSource.file &&
                o.cookieFilePath != null)
              Text(o.cookieFilePath!,
                  style: Theme.of(context).textTheme.bodySmall),
            if (o.cookieSource == CookieSource.librewolf)
              LibrewolfProfileField(browserSupported: browserCookies),
            const SizedBox(height: 16),
            Text('Save to', style: Theme.of(context).textTheme.titleSmall),
            Row(
              children: [
                Expanded(
                  child: Text(o.outputDir ?? dm.downloadDir ?? '…',
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodySmall),
                ),
                TextButton(
                  onPressed: () async {
                    final dir = await getDirectoryPath();
                    if (dir != null) setState(() => o.outputDir = dir);
                  },
                  child: const Text('Change…'),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Text('Convert after download',
                style: Theme.of(context).textTheme.titleSmall),
            const SizedBox(height: 4),
            DropdownButton<String>(
              isExpanded: true,
              value: o.convertTo ?? '',
              items: [
                const DropdownMenuItem(
                    value: '', child: Text('Don\'t convert')),
                for (final c in containerSpecs)
                  DropdownMenuItem(
                      value: c.id,
                      child: Text(
                          '${c.label}${c.audioOnly ? '  (audio only)' : ''} — remux when possible')),
              ],
              onChanged: (v) =>
                  setState(() => o.convertTo = (v?.isEmpty ?? true) ? null : v),
            ),
            for (final entry in groups.entries) ...[
              const SizedBox(height: 12),
              Text(entry.key, style: Theme.of(context).textTheme.titleSmall),
              const SizedBox(height: 4),
              for (final def in entry.value) _optionField(def),
            ],
            const SizedBox(height: 12),
            Text('Extra arguments',
                style: Theme.of(context).textTheme.titleSmall),
            const SizedBox(height: 4),
            TextFormField(
              initialValue: o.extraArgs,
              decoration: InputDecoration(
                hintText:
                    'Any other ${task.engine.displayName} flags, exactly as on the command line',
                isDense: true,
                border:
                    OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
              ),
              style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
              onChanged: (v) => setState(() => o.extraArgs = v),
            ),
            const SizedBox(height: 16),
            Text('Command preview',
                style: Theme.of(context).textTheme.titleSmall),
            const SizedBox(height: 4),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(8),
              ),
              child: SelectableText(
                dm.commandPreview(task),
                style:
                    const TextStyle(fontFamily: 'monospace', fontSize: 11.5),
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Close'),
        ),
        if (task.status == TaskStatus.ready)
          FilledButton.icon(
            onPressed: () {
              dm.startTask(task);
              Navigator.pop(context);
            },
            icon: const Icon(Icons.download),
            label: const Text('Start download'),
          ),
      ],
    );
  }

  Widget _optionField(OptionDef def) {
    final value = o.values[def.id];
    switch (def) {
      case FlagOption():
        return CheckboxListTile(
          dense: true,
          contentPadding: EdgeInsets.zero,
          controlAffinity: ListTileControlAffinity.leading,
          title: Text(def.label),
          subtitle: def.help != null ? Text(def.help!) : null,
          value: (value as bool?) ?? def.defaultValue,
          onChanged: (v) => setState(() => o.values[def.id] = v),
        );
      case ChoiceOption():
        final cs = Theme.of(context).colorScheme;
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Row(
            children: [
              Expanded(flex: 2, child: Text(def.label)),
              Expanded(
                flex: 3,
                child: DropdownButton<String>(
                  isExpanded: true,
                  // Variable-height items so descriptions show in the
                  // open menu, all at once.
                  itemHeight: null,
                  value: (value as String?) ?? def.defaultValue,
                  selectedItemBuilder: (context) => [
                    for (final c in def.choices.entries)
                      Align(
                        alignment: Alignment.centerLeft,
                        child: Text(c.value,
                            maxLines: 1, overflow: TextOverflow.ellipsis),
                      ),
                  ],
                  items: [
                    for (final c in def.choices.entries)
                      DropdownMenuItem(
                        value: c.key,
                        child: Padding(
                          padding: const EdgeInsets.symmetric(vertical: 6),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(c.value),
                              if (def.descriptions[c.key] != null)
                                Text(def.descriptions[c.key]!,
                                    style: Theme.of(context)
                                        .textTheme
                                        .labelSmall
                                        ?.copyWith(color: cs.outline)),
                            ],
                          ),
                        ),
                      ),
                  ],
                  onChanged: (v) => setState(() => o.values[def.id] = v),
                ),
              ),
            ],
          ),
        );
      case TextOption():
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: TextFormField(
            initialValue: (value as String?) ?? '',
            decoration: InputDecoration(
              labelText: def.label,
              hintText: def.placeholder,
              helperText: def.help,
              isDense: true,
              border:
                  OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
            ),
            onChanged: (v) => setState(() => o.values[def.id] = v),
          ),
        );
    }
  }
}
