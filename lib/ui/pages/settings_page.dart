import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models/convert.dart';
import '../../models/download.dart';
import '../../services/convert_manager.dart';
import '../../services/convert_planner.dart';
import '../../services/download_manager.dart';
import '../../services/settings.dart';
import '../../util/platform.dart';
import 'download_page.dart' show LibrewolfProfileField;

class SettingsPage extends StatelessWidget {
  const SettingsPage({super.key});

  @override
  Widget build(BuildContext context) {
    final s = context.watch<Settings>();
    final dm = context.watch<DownloadManager>();
    final cm = context.watch<ConvertManager>();
    final cs = Theme.of(context).colorScheme;

    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        Text('Settings', style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: 4),
        Text('Defaults for new downloads and conversions. Saved automatically.',
            style: Theme.of(context)
                .textTheme
                .bodySmall
                ?.copyWith(color: cs.outline)),
        const SizedBox(height: 20),

        // ---- Converting ----
        _Section(
          title: 'Converting',
          icon: Icons.movie_outlined,
          children: [
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Use hardware acceleration when available'),
              subtitle: Text(
                cm.inventory.hwFamilies.isEmpty
                    ? 'No working hardware encoder was found on this machine.'
                    : 'Found: ${cm.inventory.hwFamilies.join(', ')}. Much faster than software, '
                        'at slightly lower quality for the same file size.',
              ),
              value: s.preferHardware,
              onChanged: s.setPreferHardware,
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Start at the quality matching the original size'),
              subtitle: const Text(
                  'Picks the quality whose estimated output is closest to the source file, '
                  'instead of the codec\'s own default.'),
              value: s.matchOriginalSize,
              onChanged: s.setMatchOriginalSize,
            ),
            _Row(
              label: 'Rate control',
              child: SegmentedButton<RateMode>(
                segments: const [
                  ButtonSegment(
                      value: RateMode.constantQuality,
                      label: Text('Constant quality'),
                      icon: Icon(Icons.high_quality_outlined)),
                  ButtonSegment(
                      value: RateMode.constantBitrate,
                      label: Text('Constant bitrate'),
                      icon: Icon(Icons.speed)),
                ],
                selected: {s.rateMode},
                onSelectionChanged: (v) => s.setRateMode(v.first),
              ),
            ),
            _Row(
              label: 'Default video bitrate',
              child: SizedBox(
                width: 140,
                child: TextFormField(
                  initialValue: s.videoBitrate,
                  decoration:
                      const InputDecoration(isDense: true, hintText: '4M'),
                  onChanged: s.setVideoBitrate,
                ),
              ),
            ),
            _Row(
              label: 'Default audio bitrate',
              child: DropdownButton<int?>(
                value: s.audioKbps,
                isDense: true,
                items: const [
                  DropdownMenuItem(value: null, child: Text('Codec default')),
                  DropdownMenuItem(value: 96, child: Text('96 kbps')),
                  DropdownMenuItem(value: 128, child: Text('128 kbps')),
                  DropdownMenuItem(value: 160, child: Text('160 kbps')),
                  DropdownMenuItem(value: 192, child: Text('192 kbps')),
                  DropdownMenuItem(value: 256, child: Text('256 kbps')),
                  DropdownMenuItem(value: 320, child: Text('320 kbps')),
                ],
                onChanged: s.setAudioKbps,
              ),
            ),
            _Row(
              label: 'Default container',
              child: DropdownButton<String>(
                value: s.defaultContainer,
                isDense: true,
                items: [
                  for (final c in containerSpecs)
                    DropdownMenuItem(
                        value: c.id,
                        child:
                            Text('${c.label}${c.audioOnly ? ' (audio)' : ''}')),
                ],
                onChanged: (v) => v == null ? null : s.setDefaultContainer(v),
              ),
            ),
          ],
        ),

        // ---- Downloading ----
        _Section(
          title: 'Downloading',
          icon: Icons.download_outlined,
          children: [
            _Row(
              label: 'Save to',
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 320),
                    child: Text(dm.downloadDir ?? '…',
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.bodySmall),
                  ),
                  TextButton(
                    onPressed: () async {
                      final dir = await getDirectoryPath();
                      if (dir != null) dm.setDownloadDir(dir);
                    },
                    child: const Text('Change…'),
                  ),
                ],
              ),
            ),
            _Row(
              label: 'Downloads at once',
              child: _Stepper(
                value: s.maxConcurrent,
                min: 1,
                max: 10,
                onChanged: (v) {
                  s.setMaxConcurrent(v);
                  dm.maxConcurrent = s.maxConcurrent;
                },
              ),
            ),
            _Row(
              label: 'Parallel items per task',
              help: 'Videos of a playlist fetched at the same time on the '
                  'Speed preset.',
              child: _Stepper(
                value: s.maxParallelItems,
                min: 1,
                max: 10,
                onChanged: s.setMaxParallelItems,
              ),
            ),
            _Row(
              label: 'Preset',
              child: DropdownButton<PresetId?>(
                value: s.forcedPreset,
                isDense: true,
                items: [
                  const DropdownMenuItem(
                      value: null, child: Text('Auto-pick per site ★')),
                  for (final p in PresetId.values)
                    DropdownMenuItem(value: p, child: Text('Always ${p.label}')),
                ],
                onChanged: s.setForcedPreset,
              ),
            ),
            _Row(
              label: 'Cookies',
              child: DropdownButton<CookieSource>(
                value: dm.defaultCookieSource,
                isDense: true,
                items: [
                  for (final c in CookieSource.values)
                    if (c.availableOnThisOs)
                      DropdownMenuItem(value: c, child: Text(c.label)),
                ],
                onChanged: (v) async {
                  if (v == null) return;
                  if (v == CookieSource.file) {
                    final f = await openFile(acceptedTypeGroups: [
                      const XTypeGroup(label: 'Cookies', extensions: ['txt'])
                    ]);
                    if (f == null) return;
                  }
                  dm.setDefaultCookieSource(v);
                },
              ),
            ),
            if (dm.defaultCookieSource == CookieSource.librewolf)
              const LibrewolfProfileField(),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Convert after downloading'),
              subtitle: const Text(
                  'Send finished media straight to the Convert queue.'),
              value: s.convertAfterDownload,
              onChanged: (v) {
                s.setConvertAfterDownload(v);
                if (v && s.convertAfterContainer == null) {
                  s.setConvertAfterContainer(s.defaultContainer);
                }
              },
            ),
            if (s.convertAfterDownload)
              _Row(
                label: 'Convert to',
                child: DropdownButton<String>(
                  value: s.convertAfterContainer ?? s.defaultContainer,
                  isDense: true,
                  items: [
                    for (final c in containerSpecs)
                      DropdownMenuItem(value: c.id, child: Text(c.label)),
                  ],
                  onChanged: s.setConvertAfterContainer,
                ),
              ),
          ],
        ),

        // ---- Tools ----
        _Section(
          title: 'Tools',
          icon: Icons.handyman_outlined,
          children: [
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Check for tool updates at launch'),
              subtitle: const Text(
                  'Keeps yt-dlp, gallery-dl, aria2, FFmpeg, and ImageMagick current.'),
              value: s.checkUpdatesOnLaunch,
              onChanged: s.setCheckUpdatesOnLaunch,
            ),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: () => PlatformUtil.revealInFileManager(
                    context.read<DownloadManager>().tools.toolsDir.path),
                icon: const Icon(Icons.folder_open, size: 18),
                label: const Text('Open tools folder'),
              ),
            ),
          ],
        ),
      ],
    );
  }
}

class _Section extends StatelessWidget {
  final String title;
  final IconData icon;
  final List<Widget> children;
  const _Section(
      {required this.title, required this.icon, required this.children});

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.only(bottom: 16),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              Icon(icon, size: 18, color: Theme.of(context).colorScheme.primary),
              const SizedBox(width: 8),
              Text(title, style: Theme.of(context).textTheme.titleMedium),
            ]),
            const SizedBox(height: 8),
            ...children,
          ],
        ),
      ),
    );
  }
}

class _Row extends StatelessWidget {
  final String label;
  final String? help;
  final Widget child;
  const _Row({required this.label, this.help, required this.child});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 220,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label),
                if (help != null)
                  Text(help!,
                      style: Theme.of(context)
                          .textTheme
                          .labelSmall
                          ?.copyWith(color: cs.outline)),
              ],
            ),
          ),
          Expanded(child: Align(alignment: Alignment.centerLeft, child: child)),
        ],
      ),
    );
  }
}

class _Stepper extends StatelessWidget {
  final int value, min, max;
  final ValueChanged<int> onChanged;
  const _Stepper(
      {required this.value,
      required this.min,
      required this.max,
      required this.onChanged});

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        IconButton(
          icon: const Icon(Icons.remove_circle_outline, size: 20),
          onPressed: value > min ? () => onChanged(value - 1) : null,
        ),
        SizedBox(
            width: 28,
            child: Text('$value',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.titleMedium)),
        IconButton(
          icon: const Icon(Icons.add_circle_outline, size: 20),
          onPressed: value < max ? () => onChanged(value + 1) : null,
        ),
      ],
    );
  }
}
