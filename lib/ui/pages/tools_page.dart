import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models/tool.dart';
import '../../services/tool_manager.dart';
import '../../util/platform.dart';

class ToolsPage extends StatelessWidget {
  const ToolsPage({super.key});

  @override
  Widget build(BuildContext context) {
    final tm = context.watch<ToolManager>();
    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        Row(
          children: [
            Text('Bundled tools', style: Theme.of(context).textTheme.titleLarge),
            const Spacer(),
            if (tm.checking)
              const Padding(
                padding: EdgeInsets.only(right: 8),
                child: SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2)),
              ),
            TextButton.icon(
              onPressed: tm.checking ? null : tm.checkAndUpdateAll,
              icon: const Icon(Icons.refresh),
              label: Text(tm.checking ? 'Checking…' : 'Check for updates'),
            ),
          ],
        ),
        const SizedBox(height: 4),
        Text(
          'Multi downloads and updates these automatically at every launch — nothing to install by hand.',
          style: Theme.of(context)
              .textTheme
              .bodySmall
              ?.copyWith(color: Theme.of(context).colorScheme.outline),
        ),
        const SizedBox(height: 16),
        for (final spec in toolSpecs) _ToolRow(spec: spec),
        const SizedBox(height: 16),
        Row(
          children: [
            Icon(Icons.folder_outlined,
                size: 16, color: Theme.of(context).colorScheme.outline),
            const SizedBox(width: 6),
            TextButton(
              onPressed: () =>
                  PlatformUtil.revealInFileManager(tm.toolsDir.path),
              child: const Text('Open tools folder'),
            ),
          ],
        ),
      ],
    );
  }
}

class _ToolRow extends StatelessWidget {
  final ToolSpec spec;
  const _ToolRow({required this.spec});

  @override
  Widget build(BuildContext context) {
    final tm = context.watch<ToolManager>();
    final status = tm.statusOf(spec.id);
    final cs = Theme.of(context).colorScheme;

    final (chipColor, chipLabel) = switch (status.kind) {
      ToolStatusKind.ready => (
          Colors.green,
          status.installedVersion != null
              ? 'v${status.installedVersion}'
              : 'Ready'
        ),
      ToolStatusKind.usingSystem => (
          cs.tertiary,
          'System${status.installedVersion != null ? ' v${status.installedVersion}' : ''}'
        ),
      ToolStatusKind.checking => (cs.secondary, 'Checking…'),
      ToolStatusKind.downloading => (
          cs.primary,
          'Downloading${status.progress != null ? ' ${(status.progress! * 100).round()}%' : '…'}'
        ),
      ToolStatusKind.installing => (cs.primary, 'Installing…'),
      ToolStatusKind.updateAvailable => (Colors.orange, 'Update available'),
      ToolStatusKind.missing => (cs.error, 'Not installed'),
      ToolStatusKind.error => (cs.error, 'Error'),
      ToolStatusKind.unknown => (cs.outline, '…'),
    };

    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 12, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  switch (spec.id) {
                    ToolId.ytDlp => Icons.smart_display_outlined,
                    ToolId.galleryDl => Icons.photo_library_outlined,
                    ToolId.aria2 => Icons.bolt,
                    ToolId.ffmpeg => Icons.movie_outlined,
                    ToolId.magick => Icons.auto_fix_high_outlined,
                  },
                  color: cs.primary,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(spec.id.displayName,
                          style: Theme.of(context).textTheme.titleSmall),
                      Text(spec.id.blurb,
                          style: Theme.of(context)
                              .textTheme
                              .bodySmall
                              ?.copyWith(color: cs.outline)),
                    ],
                  ),
                ),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  decoration: BoxDecoration(
                    color: chipColor.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(20),
                    border:
                        Border.all(color: chipColor.withValues(alpha: 0.6)),
                  ),
                  child: Text(chipLabel,
                      style: Theme.of(context)
                          .textTheme
                          .labelSmall
                          ?.copyWith(
                              color: chipColor, fontWeight: FontWeight.bold)),
                ),
                const SizedBox(width: 4),
                IconButton(
                  tooltip: 'Update / reinstall',
                  icon: const Icon(Icons.download_for_offline_outlined),
                  onPressed: status.kind == ToolStatusKind.downloading ||
                          status.kind == ToolStatusKind.installing ||
                          status.kind == ToolStatusKind.checking
                      ? null
                      : () => tm.updateOne(spec.id),
                ),
              ],
            ),
            if (status.kind == ToolStatusKind.downloading)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: LinearProgressIndicator(
                    value: status.progress,
                    borderRadius: BorderRadius.circular(4)),
              ),
            if (status.message != null)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(status.message!,
                    style: Theme.of(context)
                        .textTheme
                        .bodySmall
                        ?.copyWith(color: cs.outline)),
              ),
            if (status.kind == ToolStatusKind.missing &&
                spec.unavailableHint != null)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(spec.unavailableHint!,
                    style: Theme.of(context).textTheme.bodySmall),
              ),
            // Where no portable binary exists, offer to install it via
            // Homebrew rather than sending the user to a terminal.
            if (spec.brewFormula != null &&
                (status.kind == ToolStatusKind.missing ||
                    status.kind == ToolStatusKind.error))
              _BrewButton(spec: spec),
          ],
        ),
      ),
    );
  }
}


/// One-click Homebrew install for tools with no portable build.
class _BrewButton extends StatefulWidget {
  final ToolSpec spec;
  const _BrewButton({required this.spec});

  @override
  State<_BrewButton> createState() => _BrewButtonState();
}

class _BrewButtonState extends State<_BrewButton> {
  bool? _hasBrew;

  @override
  void initState() {
    super.initState();
    ToolManager.homebrewPath().then((p) {
      if (mounted) setState(() => _hasBrew = p != null);
    });
  }

  @override
  Widget build(BuildContext context) {
    final tm = context.read<ToolManager>();
    final cs = Theme.of(context).colorScheme;
    if (_hasBrew == null) return const SizedBox.shrink();
    if (_hasBrew == false) {
      return Padding(
        padding: const EdgeInsets.only(top: 6),
        child: Text(
          'Install Homebrew from brew.sh, then Multi can install '
          '${widget.spec.brewFormula} for you.',
          style: Theme.of(context)
              .textTheme
              .bodySmall
              ?.copyWith(color: cs.outline),
        ),
      );
    }
    return Align(
      alignment: Alignment.centerLeft,
      child: TextButton.icon(
        onPressed: () => tm.installWithHomebrew(widget.spec.id),
        icon: const Icon(Icons.download_outlined, size: 18),
        label: Text('Install ${widget.spec.brewFormula} with Homebrew'),
      ),
    );
  }
}
