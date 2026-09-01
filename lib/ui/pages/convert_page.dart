import 'dart:io';
import 'dart:math' as math;

import 'package:desktop_drop/desktop_drop.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:provider/provider.dart';

import '../../app.dart';
import '../../models/convert.dart';
import '../../services/convert_manager.dart';
import '../../services/convert_planner.dart';
import '../../ui/widgets/convert_options.dart';
import '../../ui/widgets/format_options_panel.dart';

import '../../util/platform.dart';

class ConvertPage extends StatefulWidget {
  const ConvertPage({super.key});

  @override
  State<ConvertPage> createState() => _ConvertPageState();
}

class _ConvertPageState extends State<ConvertPage> {
  ProbeResult? _input;
  ContainerSpec? _target;
  ConvertPlan? _plan;
  String? _error;
  bool _probing = false;
  bool _dragging = false;

  /// Set when the file arrived from a finished download, so the page can
  /// say where it came from and offer to clean it up afterwards.
  bool _fromDownload = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final cm = context.read<ConvertManager>();
      // Detect hardware encoders early so the toggle is accurate.
      cm.ensureHwDetected();
      _takeDownloadHandoff();
    });
  }

  /// Open a file a finished download handed over, with the same plan UI
  /// as any other conversion.
  void _takeDownloadHandoff() {
    final cm = context.read<ConvertManager>();
    if (_input != null || _probing) return;
    final next = cm.takePendingFromDownload();
    if (next == null) return;
    final target = containerSpecs.firstWhere((c) => c.id == next.containerId,
        orElse: () => containerSpecs.first);
    _load(next.path, preselect: target, fromDownload: true);
  }

  /// Probe a file and build its plan.
  Future<void> _load(String path,
      {ContainerSpec? preselect, bool fromDownload = false}) async {
    final cm = context.read<ConvertManager>();
    setState(() {
      _probing = true;
      _error = null;
      _input = null;
      _plan = null;
      _target = null;
      _fromDownload = fromDownload;
    });
    try {
      final probe = await cm.planner.probe(path);
      if (!mounted) return;
      setState(() {
        _input = probe;
        _probing = false;
      });
      if (preselect != null) _selectTarget(preselect);
      // Files that arrived from a download are throwaway originals once
      // converted, which is the whole point of asking to convert them.
      if (fromDownload && _plan != null) {
        _plan!.settings.deleteSourceWhenDone = true;
        _recompute();
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '$e';
        _probing = false;
      });
    }
  }

  Future<void> _pickFile() async {
    final file = await openFile(acceptedTypeGroups: [
      const XTypeGroup(label: 'Media', extensions: [
        'mp4', 'mkv', 'webm', 'avi', 'mov', 'flv', 'ts', 'm2ts', 'wmv',
        'mp3', 'm4a', 'flac', 'opus', 'ogg', 'wav', 'aac', 'wma', 'gif',
      ])
    ]);
    if (file == null || !mounted) return;
    await _load(file.path);
  }

  Future<void> _selectTarget(ContainerSpec spec) async {
    final cm = context.read<ConvertManager>();
    setState(() {
      _target = spec;
      _plan = cm.planWithDefaults(_input!, spec);
    });
    // Ask FFmpeg what these encoders accept, then show their options.
    await cm.planner.loadCapabilities(_plan!, spec, cm.inventory);
    if (!mounted || _plan == null) return;
    cm.planner.recompute(_plan!, spec, cm.inventory);
    setState(() {});
  }

  void _recompute() {
    if (_plan == null || _target == null) return;
    final cm = context.read<ConvertManager>();
    cm.planner.recompute(_plan!, _target!, cm.inventory);
    setState(() {});
    // A codec change brings a different encoder, with different options.
    cm.planner
        .loadCapabilities(_plan!, _target!, cm.inventory)
        .then((_) {
      if (mounted) setState(() {});
    });
  }

  static const _mediaExtensions = {
    'mp4', 'mkv', 'webm', 'avi', 'mov', 'flv', 'ts', 'm2ts', 'wmv', 'm4v',
    'mpg', 'mpeg', '3gp', 'ogv', 'mp3', 'm4a', 'flac', 'opus', 'ogg',
    'wav', 'aac', 'wma', 'gif', 'weba',
  };

  @override
  Widget build(BuildContext context) {
    final cm = context.watch<ConvertManager>();
    // Files handed over by a download while this page was off-screen.
    if (cm.pendingFromDownloads.isNotEmpty && _input == null && !_probing) {
      WidgetsBinding.instance
          .addPostFrameCallback((_) => _takeDownloadHandoff());
    }
    return DropTarget(
      enable: PageVisibility.of(context),
      onDragEntered: (_) => setState(() => _dragging = true),
      onDragExited: (_) => setState(() => _dragging = false),
      onDragDone: (detail) {
        setState(() => _dragging = false);
        // Work with plain paths: firstWhere's orElse has to return the
        // element type exactly, and a throwing closure there fails the
        // runtime type check before it is ever called — which is what
        // silently swallowed every drop.
        final paths = detail.files.map((f) => f.path).toList();
        if (paths.isEmpty) return;
        final media = paths.firstWhere(
          (path) => _mediaExtensions.contains(
              p.extension(path).replaceFirst('.', '').toLowerCase()),
          orElse: () => paths.first,
        );
        _load(media);
      },
      child: Stack(
        children: [
          _body(context, cm),
          if (_dragging)
            Positioned.fill(
              child: IgnorePointer(
                child: Container(
                  color: Theme.of(context)
                      .colorScheme
                      .primary
                      .withValues(alpha: 0.12),
                  child: Center(
                    child: Card(
                      child: Padding(
                        padding: const EdgeInsets.all(24),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.file_download_outlined,
                                size: 40,
                                color: Theme.of(context).colorScheme.primary),
                            const SizedBox(height: 8),
                            Text('Drop a media file to convert it',
                                style:
                                    Theme.of(context).textTheme.titleMedium),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _body(BuildContext context, ConvertManager cm) {
    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        Text('Convert / Remux', style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: 4),
        Text(
          '“I have this container, I want that container.” Multi copies every stream the target can hold and re-encodes only what it can’t — unless you choose otherwise below.',
          style: Theme.of(context)
              .textTheme
              .bodySmall
              ?.copyWith(color: Theme.of(context).colorScheme.outline),
        ),
        const SizedBox(height: 16),
        Row(
          children: [
            FilledButton.tonalIcon(
              onPressed: _pickFile,
              icon: const Icon(Icons.video_file_outlined),
              label: const Text('Choose a file'),
            ),
            const SizedBox(width: 10),
            Text('or drop one anywhere on this page',
                style: Theme.of(context)
                    .textTheme
                    .bodySmall
                    ?.copyWith(color: Theme.of(context).colorScheme.outline)),
            const SizedBox(width: 12),
            if (_probing) const CircularProgressIndicator.adaptive(),
            if (_input != null)
              Expanded(
                child: Text(
                  '${p.basename(_input!.path)}'
                  '${_input!.sizeBytes != null ? ' · ${PlatformUtil.humanBytes(_input!.sizeBytes!)}' : ''}'
                  '${_input!.durationSeconds != null ? ' · ${_fmtDuration(_input!.durationSeconds!)}' : ''}',
                  overflow: TextOverflow.ellipsis,
                ),
              ),
          ],
        ),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.only(top: 12),
            child: Text(_error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error)),
          ),
        if (_fromDownload && _input != null)
          Padding(
            padding: const EdgeInsets.only(top: 12),
            child: Card(
              color: Theme.of(context)
                  .colorScheme
                  .tertiaryContainer
                  .withValues(alpha: 0.4),
              child: ListTile(
                dense: true,
                leading: const Icon(Icons.download_done, size: 20),
                title: const Text('Just downloaded'),
                subtitle: const Text(
                    'Set up the conversion below, then press Convert. The '
                    'downloaded original is deleted once it succeeds.'),
              ),
            ),
          ),
        if (_input != null) ...[
          const SizedBox(height: 20),
          Text('Convert to', style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final spec in containerSpecs.where((s) => !s.audioOnly))
                ChoiceChip(
                  label: Text(spec.label),
                  selected: _target?.id == spec.id,
                  onSelected: (_) => _selectTarget(spec),
                ),
              const SizedBox(width: 12),
              for (final spec in containerSpecs.where((s) => s.audioOnly))
                ChoiceChip(
                  avatar: const Icon(Icons.music_note, size: 16),
                  label: Text(spec.label),
                  selected: _target?.id == spec.id,
                  onSelected: (_) => _selectTarget(spec),
                ),
            ],
          ),
        ],
        if (_plan != null && _target != null) ...[
          const SizedBox(height: 20),
          _PlanCard(
            plan: _plan!,
            target: _target!,
            inventory: cm.inventory,
            onChanged: _recompute,
          ),
          if (_target!.id == 'gif') ...[
            const SizedBox(height: 12),
            GifCard(
              plan: _plan!,
              target: _target!,
              inventory: cm.inventory,
              onChanged: _recompute,
            ),
          ],
          if (!_target!.audioOnly &&
              _input!.streams
                  .any((s) => s.type == 'video' && !s.attachedPic)) ...[
            const SizedBox(height: 12),
            Card(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
                child: _FiltersSection(
                  plan: _plan!,
                  target: _target!,
                  inventory: cm.inventory,
                  onChanged: _recompute,
                ),
              ),
            ),
          ],
          const SizedBox(height: 12),
          AudioCard(
            plan: _plan!,
            target: _target!,
            inventory: cm.inventory,
            onChanged: _recompute,
          ),

          if (_input!.streams.any((s) => s.type == 'subtitle')) ...[
            const SizedBox(height: 12),
            SubtitleCard(
              plan: _plan!,
              target: _target!,
              onChanged: _recompute,
            ),
          ],
          const SizedBox(height: 12),
          _TrimCard(plan: _plan!, onChanged: _recompute),

          const SizedBox(height: 12),
          FormatOptionsPanel(
            plan: _plan!,
            target: _target!,
            inventory: cm.inventory,
            planner: cm.planner,
            onChanged: () => setState(() {}),
          ),
          const SizedBox(height: 12),
          _OutputCard(
            plan: _plan!,
            target: _target!,
            sourcePath: _input!.path,
            onChanged: () => setState(() {}),
          ),
          const SizedBox(height: 16),
          if (_plan!.keepsNothing)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Row(children: [
                Icon(Icons.block,
                    size: 16, color: Theme.of(context).colorScheme.error),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Nothing would survive into ${_target!.label} — this file '
                    'has no stream that container can hold. Pick a different '
                    'container.',
                    style: TextStyle(
                        color: Theme.of(context).colorScheme.error),
                  ),
                ),
              ]),
            ),
          Align(
            alignment: Alignment.centerLeft,
            child: FilledButton.icon(
              onPressed: _plan!.keepsNothing
                  ? null
                  : () {
                cm.enqueue(_plan!, _target!);
                setState(() {
                  _plan = null;
                  _target = null;
                  _input = null;
                  _fromDownload = false;
                });
              },
              icon: Icon(
                  _plan!.isPureRemux ? Icons.swap_horiz : Icons.autorenew),
              label: Text(_plan!.isPureRemux ? 'Remux' : 'Convert'),
            ),
          ),
        ],
        if (cm.jobs.isNotEmpty) ...[
          const Divider(height: 32),
          Text('Jobs', style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(height: 8),
          for (final job in cm.jobs) _JobTile(job: job),
        ],
      ],
    );
  }

  String _fmtDuration(double seconds) {
    final d = Duration(seconds: seconds.round());
    final h = d.inHours;
    final m = d.inMinutes % 60;
    final s = d.inSeconds % 60;
    return h > 0 ? '$h:${_pad(m)}:${_pad(s)}' : '$m:${_pad(s)}';
  }

  String _pad(int n) => n.toString().padLeft(2, '0');
}

/// The before-you-act plan: per-stream codec choice with descriptions
/// and size estimates, plus quality / bitrate / hardware settings.
class _PlanCard extends StatelessWidget {
  final ConvertPlan plan;
  final ContainerSpec target;
  final EncoderInventory inventory;
  final VoidCallback onChanged;
  const _PlanCard({
    required this.plan,
    required this.target,
    required this.inventory,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final planner = context.read<ConvertManager>().planner;
    final headlineColor = plan.isPureRemux
        ? Colors.green
        : plan.transcodedCount > 0
            ? Colors.orange
            : cs.primary;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(plan.isPureRemux ? Icons.flash_on : Icons.autorenew,
                    color: headlineColor),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(plan.headline,
                      style: Theme.of(context)
                          .textTheme
                          .titleSmall
                          ?.copyWith(color: headlineColor)),
                ),
              ],
            ),
            const SizedBox(height: 10),
            _SizeSummary(plan: plan),
            const Divider(height: 20),
            ..._streamSections(context, planner),
            LanguageFilterBar(
              plan: plan,
              target: target,
              inventory: inventory,
              onChanged: onChanged,
            ),

            if (plan.transcodedCount > 0) ...[
              const Divider(height: 24),
              _TranscodeSettingsPanel(
                plan: plan,
                target: target,
                inventory: inventory,
                onChanged: onChanged,
              ),
            ],
          ],
        ),
      ),
    );
  }

  /// Rows grouped by what they are, in the order they will be written.
  ///
  /// A file with a dozen subtitle tracks would otherwise bury the video
  /// and audio it came for, so past three they fold away.
  List<Widget> _streamSections(BuildContext context, ConvertPlanner planner) {
    final ordered = planner.orderedActions(plan);
    Widget row(StreamAction a) => _StreamRow(
          plan: plan,
          target: target,
          action: a,
          planner: planner,
          inventory: inventory,
          onChanged: onChanged,
          onMove: (delta) => _move(planner, a.stream, delta),
        );
    final subs = [
      for (final a in ordered)
        if (a.stream.type == 'subtitle') a,
    ];
    final kept = subs.where((a) => a.kind != StreamActionKind.drop).length;
    return [
      for (final a in ordered)
        if (a.stream.type != 'subtitle') row(a),
      if (subs.isNotEmpty && subs.length <= 3)
        for (final a in subs) row(a),
      if (subs.length > 3)
        Theme(
          data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
          child: ExpansionTile(
            tilePadding: EdgeInsets.zero,
            childrenPadding: EdgeInsets.zero,
            leading: const Icon(Icons.subtitles_outlined, size: 20),
            title: Text('${subs.length} subtitle tracks',
                style: Theme.of(context).textTheme.bodyMedium),
            subtitle: Text(
                '$kept kept, ${subs.length - kept} dropped — open to change '
                'any of them',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.outline)),
            children: [for (final a in subs) row(a)],
          ),
        ),
    ];
  }

  /// Swap a stream with its neighbour of the same type. Reordering
  /// video against audio is not a thing anyone wants, and it changes
  /// which stream players treat as the main one.
  void _move(ConvertPlanner planner, StreamInfo s, int delta) {
    final ordered = planner.orderedActions(plan);
    final order = [for (final a in ordered) a.stream.index];
    final sameType = [
      for (final a in ordered)
        if (a.stream.type == s.type) a.stream.index,
    ];
    final pos = sameType.indexOf(s.index);
    final to = pos + delta;
    if (pos < 0 || to < 0 || to >= sameType.length) return;
    final other = sameType[to];
    final i = order.indexOf(s.index), j = order.indexOf(other);
    order[i] = other;
    order[j] = s.index;
    plan.streamOrder = order;
    onChanged();
  }
}

/// Original size, estimated size, and the change between them.

class _SizeSummary extends StatelessWidget {
  final ConvertPlan plan;
  const _SizeSummary({required this.plan});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final est = plan.estimatedTotalBytes;
    final original = plan.input.sizeBytes ??
        plan.actions.fold<int>(0, (a, b) => a + (b.originalBytes ?? 0));
    if (est == null || original <= 0) return const SizedBox.shrink();
    final change = (est - original) / original * 100;
    final smaller = change < 0;
    final color = change.abs() < 5
        ? cs.outline
        : smaller
            ? Colors.green
            : Colors.orange;

    Widget cell(String label, String value, {Color? valueColor}) => Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(label,
                style: Theme.of(context)
                    .textTheme
                    .labelSmall
                    ?.copyWith(color: cs.outline)),
            Text(value,
                style: Theme.of(context)
                    .textTheme
                    .titleSmall
                    ?.copyWith(color: valueColor)),
          ],
        );

    return Row(
      children: [
        cell('Original', PlatformUtil.humanBytes(original)),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Icon(Icons.arrow_forward, size: 16, color: cs.outline),
        ),
        cell('Estimated', '~${PlatformUtil.humanBytes(est)}'),
        const SizedBox(width: 16),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.15),
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: color.withValues(alpha: 0.6)),
          ),
          child: Text(
            '${change >= 0 ? '+' : ''}${change.toStringAsFixed(0)}%',
            style: Theme.of(context)
                .textTheme
                .labelMedium
                ?.copyWith(color: color, fontWeight: FontWeight.bold),
          ),
        ),
        const Spacer(),
        Flexible(
          child: Text(
            plan.isPureRemux
                ? 'exact — nothing is re-encoded'
                : 'estimate: real size depends on the footage',
            textAlign: TextAlign.end,
            style: Theme.of(context)
                .textTheme
                .labelSmall
                ?.copyWith(color: cs.outline),
          ),
        ),
      ],
    );
  }
}

class _StreamRow extends StatelessWidget {
  final ConvertPlan plan;
  final ContainerSpec target;
  final StreamAction action;
  final ConvertPlanner planner;
  final EncoderInventory inventory;
  final VoidCallback onChanged;

  /// Move this stream one place earlier (-1) or later (+1) among the
  /// streams of its own type.
  final void Function(int delta)? onMove;
  const _StreamRow({
    required this.plan,
    required this.target,
    required this.action,
    required this.planner,
    required this.inventory,
    required this.onChanged,
    this.onMove,
  });


  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final s = action.stream;
    final (color, badge) = switch (action.kind) {
      StreamActionKind.copy => (Colors.green, 'COPY'),
      StreamActionKind.transcode => (
          Colors.orange,
          '${s.codec.toUpperCase()} → ${action.targetCodec?.toUpperCase()}'
        ),
      StreamActionKind.drop => (cs.outline, 'DROP'),
    };
    final icon = switch (s.type) {
      'video' => s.attachedPic ? Icons.image_outlined : Icons.videocam_outlined,
      'audio' => Icons.graphic_eq,
      'subtitle' => Icons.subtitles_outlined,
      _ => Icons.insert_drive_file_outlined,
    };
    final choices = _choicesFor(s);
    final selection = plan.selection[s.index] ?? 'drop';
    final selectedCodec =
        selection != 'copy' && selection != 'drop' ? codecInfo(selection) : null;
    final pct = action.percentChange;
    final meta = plan.streamMeta[s.index];


    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(icon, size: 20, color: cs.onSurfaceVariant),
              const SizedBox(width: 10),
              Expanded(
                flex: 3,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                        '${s.type[0].toUpperCase()}${s.type.substring(1)} · ${s.summary}',
                        style: Theme.of(context).textTheme.bodyMedium),
                    Text(action.reason,
                        style: Theme.of(context)
                            .textTheme
                            .bodySmall
                            ?.copyWith(color: cs.outline)),
                  ],
                ),
              ),
              const SizedBox(width: 10),
              if (action.kind != StreamActionKind.drop)
                _sizeCell(context, action, pct),
              if (action.kind != StreamActionKind.drop && onMove != null) ...[
                _moveButton(context, Icons.keyboard_arrow_up, 'Move earlier', -1),
                _moveButton(context, Icons.keyboard_arrow_down, 'Move later', 1),
                IconButton(
                  tooltip: 'Name, language and flags',
                  visualDensity: VisualDensity.compact,
                  iconSize: 18,
                  color: meta != null && !meta.isEmpty ? cs.primary : null,
                  icon: const Icon(Icons.label_outline),
                  onPressed: () async {
                    await showDialog(
                      context: context,
                      builder: (_) =>
                          StreamMetaDialog(plan: plan, stream: s),
                    );
                    onChanged();
                  },
                ),
              ],
              if (choices != null)

                _codecDropdown(context, s, choices, selection)
              else
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  decoration: BoxDecoration(
                    color: color.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(color: color.withValues(alpha: 0.6)),
                  ),
                  child: Text(badge,
                      style: Theme.of(context)
                          .textTheme
                          .labelSmall
                          ?.copyWith(
                              color: color, fontWeight: FontWeight.bold)),
                ),
            ],
          ),
          if (selectedCodec != null)
            Padding(
              padding: const EdgeInsets.only(left: 30, top: 4),
              child: Text(
                selectedCodec.description,
                style: Theme.of(context)
                    .textTheme
                    .bodySmall
                    ?.copyWith(color: cs.tertiary),
              ),
            ),
          if (meta != null && !meta.isEmpty)
            Padding(
              padding: const EdgeInsets.only(left: 30, top: 2),
              child: Text(
                [
                  if (meta.title.isNotEmpty) '“${meta.title}”',
                  if (meta.language.isNotEmpty) meta.language,
                  if (meta.isDefault == true) 'default',
                  if (meta.forced == true) 'forced',
                ].join(' · '),
                style: Theme.of(context)
                    .textTheme
                    .labelSmall
                    ?.copyWith(color: cs.primary),
              ),
            ),

        ],
      ),
    );
  }

  Widget _moveButton(
          BuildContext context, IconData icon, String tip, int delta) =>
      IconButton(
        tooltip: tip,
        visualDensity: VisualDensity.compact,
        iconSize: 18,
        padding: EdgeInsets.zero,
        constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
        icon: Icon(icon),
        onPressed: () => onMove!(delta),
      );

  /// Per-stream original → estimated size with the percentage change.

  Widget _sizeCell(BuildContext context, StreamAction a, double? pct) {
    final cs = Theme.of(context).colorScheme;
    final small =
        Theme.of(context).textTheme.labelSmall?.copyWith(color: cs.outline);
    if (a.originalBytes == null && a.estimatedBytes == null) {
      return const SizedBox(width: 150);
    }
    final color = pct == null || pct.abs() < 5
        ? cs.outline
        : pct < 0
            ? Colors.green
            : Colors.orange;
    return SizedBox(
      width: 150,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Text(
            [
              if (a.originalBytes != null)
                PlatformUtil.humanBytes(a.originalBytes!),
              if (a.kind == StreamActionKind.transcode &&
                  a.estimatedBytes != null)
                '→ ~${PlatformUtil.humanBytes(a.estimatedBytes!)}',
            ].join(' '),
            style: small,
          ),
          if (a.kind == StreamActionKind.transcode && pct != null)
            Text('${pct >= 0 ? '+' : ''}${pct.toStringAsFixed(0)}%',
                style: Theme.of(context)
                    .textTheme
                    .labelSmall
                    ?.copyWith(color: color, fontWeight: FontWeight.bold)),
        ],
      ),
    );
  }

  /// Video, audio and text subtitle streams all get a codec choice.
  ///
  /// An image-based subtitle is a picture: it can be copied or dropped
  /// or burned into the frame, but there is no text in it to rewrite,
  /// so no format list is offered for it.
  List<CodecInfo>? _choicesFor(StreamInfo s) {
    if (s.type == 'subtitle') {
      if (ConvertPlanner.isImageSubtitle(s.codec)) return null;
      final list = planner.encodableFor(target, 'subtitle', inventory);
      return list.isEmpty ? null : list;
    }
    if (s.type != 'video' && s.type != 'audio') return null;
    if (target.audioOnly && s.type == 'video') return null;
    final list = planner.encodableFor(target, s.type, inventory);
    return list.isEmpty ? null : list;
  }


  Widget _codecDropdown(BuildContext context, StreamInfo s,
      List<CodecInfo> choices, String selection) {
    final copyAllowed = target.allows(s.type, s.codec);
    final cs = Theme.of(context).colorScheme;
    final entries = <(String, String, String, bool)>[
      if (copyAllowed)
        (
          'copy',
          'Copy — no re-encode',
          'instant, bit-for-bit, no quality loss',
          true
        ),
      for (final c in choices) (c.id, c.label, c.shortDescription, false),
      ('drop', 'Drop stream', 'leave this stream out of the output', false),
    ];
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 210),
      child: DropdownButton<String>(
        value: entries.any((e) => e.$1 == selection) ? selection : 'drop',
        itemHeight: null,
        isExpanded: true,
        underline: const SizedBox.shrink(),
        selectedItemBuilder: (context) => [
          for (final (_, title, _, _) in entries)
            Align(
              alignment: Alignment.centerRight,
              child: Text(title,
                  maxLines: 1, overflow: TextOverflow.ellipsis),
            ),
        ],
        items: [
          for (final (value, title, desc, bold) in entries)
            DropdownMenuItem(
              value: value,
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(title,
                        style: bold
                            ? const TextStyle(fontWeight: FontWeight.w600)
                            : null),
                    Text(desc,
                        style: Theme.of(context)
                            .textTheme
                            .labelSmall
                            ?.copyWith(color: cs.outline)),
                  ],
                ),
              ),
            ),
        ],
        onChanged: (v) {
          if (v == null) return;
          plan.selection[s.index] = v;
          onChanged();
        },
      ),
    );
  }
}

class _TranscodeSettingsPanel extends StatelessWidget {
  final ConvertPlan plan;
  final ContainerSpec target;
  final EncoderInventory inventory;
  final VoidCallback onChanged;
  const _TranscodeSettingsPanel({
    required this.plan,
    required this.target,
    required this.inventory,
    required this.onChanged,
  });

  String? get _videoCodecId {
    for (final a in plan.actions) {
      if (a.kind == StreamActionKind.transcode && a.stream.type == 'video') {
        return a.targetCodec;
      }
    }
    return null;
  }


  @override
  Widget build(BuildContext context) {
    final st = plan.settings;
    final cs = Theme.of(context).colorScheme;
    final planner = context.read<ConvertManager>().planner;
    final codecId = _videoCodecId;
    final hwEncoder =
        codecId == null ? null : inventory.hwEncoderFor(codecId);
    final family = codecId == null ? null : inventory.hwFamilyFor(codecId);
    final usingHw = st.hwAccel && hwEncoder != null;
    final cqSupported = codecId == null
        ? false
        : planner.qualityScale(codecId, st, inventory).$4;
    final scale =
        codecId == null ? (0, 0, 0, false) : planner.qualityScale(codecId, st, inventory);
    final capped = st.sizeCapMb != null;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Transcode settings',
            style: Theme.of(context).textTheme.titleSmall),
        const SizedBox(height: 8),
        if (codecId != null) ...[
          Row(
            children: [
              SegmentedButton<RateMode>(
                segments: [
                  ButtonSegment(
                    value: RateMode.constantQuality,
                    label: const Text('Constant quality'),
                    icon: const Icon(Icons.high_quality_outlined),
                    enabled: cqSupported && !capped,
                  ),
                  ButtonSegment(
                    value: RateMode.constantBitrate,
                    label: const Text('Constant bitrate'),
                    icon: const Icon(Icons.speed),
                    enabled: !capped,
                  ),
                ],
                selected: {capped ? RateMode.constantBitrate : st.mode},
                onSelectionChanged: (s) {
                  st.mode = s.first;
                  st.crf = null;
                  onChanged();
                },
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            capped
                ? 'A size cap sets the bitrate directly, so the rate mode is fixed.'
                : !cqSupported
                    ? '${family?.label ?? 'This encoder'} has no dependable constant-quality mode — it encodes to a bitrate.'
                    : st.mode == RateMode.constantQuality
                        ? 'Recommended: quality stays constant, file size varies with content.'
                        : 'File size is predictable, quality varies with content.',
            style: Theme.of(context)
                .textTheme
                .bodySmall
                ?.copyWith(color: cs.outline),
          ),
          const SizedBox(height: 8),
          if (!capped &&
              cqSupported &&
              st.mode == RateMode.constantQuality) ...[
            Row(
              children: [
                SizedBox(
                  width: 190,
                  child: Text(
                      usingHw
                          ? '${family!.label} quality (${_cqFlagLabel(family)} ${st.crf ?? scale.$3})'
                          : 'Quality (CRF ${st.crf ?? scale.$3})',
                      style: Theme.of(context).textTheme.bodyMedium),
                ),
                Expanded(
                  child: Slider(
                    value: (st.crf ?? scale.$3)
                        .clamp(scale.$1, scale.$2)
                        .toDouble(),
                    min: scale.$1.toDouble(),
                    max: scale.$2.toDouble(),
                    divisions: (scale.$2 - scale.$1).clamp(1, 100),
                    label: '${st.crf ?? scale.$3}',
                    onChanged: (v) {
                      st.crf = v.round();
                      onChanged();
                    },
                  ),
                ),
                Text('lower = better',
                    style: Theme.of(context)
                        .textTheme
                        .labelSmall
                        ?.copyWith(color: cs.outline)),
              ],
            ),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: () {
                  final q = planner.qualityMatchingOriginalSize(
                      plan, target, inventory);
                  if (q != null) {
                    st.crf = q;
                    onChanged();
                  }
                },
                icon: const Icon(Icons.straighten, size: 16),
                label: const Text('Match the original file size'),
              ),
            ),
          ],
          if (!capped && (st.mode == RateMode.constantBitrate || !cqSupported))
            _BitrateSlider(
              value: st.videoBitrate,
              onChanged: (v) {
                st.videoBitrate = v;
                onChanged();
              },
            ),
          SwitchListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            title: Text(hwEncoder != null
                ? 'Hardware acceleration ($hwEncoder)'
                : 'Hardware acceleration'),
            subtitle: Text(hwEncoder != null
                ? 'On by default when available: much faster, slightly lower quality at the same size than software.'
                : 'No hardware encoder for ${codecInfo(codecId)?.label ?? codecId} on this machine.'),
            value: usingHw,
            onChanged: hwEncoder == null
                ? null
                : (v) {
                    st.hwAccel = v;
                    // Remember the choice, so re-planning stops
                    // overriding it.
                    st.hwAccelUserSet = true;
                    st.crf = null; // the quality scale changes with it
                    final fam = inventory.hwFamilyFor(codecId);
                    if (v && fam != null && !fam.supportsConstantQuality) {
                      st.mode = RateMode.constantBitrate;
                    }
                    onChanged();
                  },
          ),
          _SizeCapRow(plan: plan, onChanged: onChanged),
          if (planner.twoPassApplies(plan, inventory))
            CheckboxListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              controlAffinity: ListTileControlAffinity.leading,
              title: const Text('Two-pass encoding'),
              subtitle: const Text(
                  'Encodes once to measure where the difficult parts are, '
                  'then again to spend the bits there. Twice as slow, and '
                  'it hits the target size far more accurately.'),
              value: st.twoPass,
              onChanged: (v) {
                st.twoPass = v ?? false;
                onChanged();
              },
            ),
        ],
      ],
    );
  }


  static String _cqFlagLabel(HwFamily f) => switch (f.id) {
        'nvenc' => 'CQ',
        'qsv' => 'GQ',
        'amf' => 'QP',
        _ => 'QP',
      };
}

/// Keep the output under a chosen size — for upload limits. Off by
/// default; ticking it reveals the size control.
class _SizeCapRow extends StatelessWidget {
  final ConvertPlan plan;
  final VoidCallback onChanged;
  const _SizeCapRow({required this.plan, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final st = plan.settings;
    final planner = context.read<ConvertManager>().planner;
    final on = st.sizeCapMb != null;
    final applies = planner.sizeCapApplies(plan);
    final bps = on ? planner.videoBitrateForSizeCap(plan) : null;
    final audioKbps = (planner.audioBitsPerSecond(plan) / 1000).round();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            SizedBox(
              width: 190,
              child: CheckboxListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                controlAffinity: ListTileControlAffinity.leading,
                title: const Text('Cap file size'),
                value: on,
                onChanged: (v) {
                  st.sizeCapMb = (v ?? false) ? 25 : null;
                  onChanged();
                },
              ),
            ),
            if (on)
              Expanded(
                child: _MbSlider(
                  valueMb: st.sizeCapMb!,
                  onChanged: (mb) {
                    st.sizeCapMb = mb;
                    onChanged();
                  },
                ),
              )
            else
              Expanded(
                child: Text(
                  'Fit the result under a size limit — for Discord, email, '
                  'or anywhere with an upload cap.',
                  style: Theme.of(context)
                      .textTheme
                      .labelSmall
                      ?.copyWith(color: cs.outline),
                ),
              ),
          ],
        ),
        if (on)
          Padding(
            padding: const EdgeInsets.only(left: 190, bottom: 4),
            child: Text(
              !applies
                  ? 'The video is being copied, so its size is already '
                      'fixed — pick a codec for the video stream above for '
                      'the cap to do anything.'
                  : bps == null
                      ? 'This clip has no known duration, so a size cap '
                          'cannot be worked out.'
                      : 'Video encoded at ~${(bps / 1000).round()} kbps, '
                          'after leaving $audioKbps kbps for the audio.',
              style: Theme.of(context).textTheme.labelSmall?.copyWith(
                  color: (!applies || bps == null) ? cs.error : cs.outline),
            ),
          ),
      ],
    );
  }
}

/// A size picker: free slider plus exact entry, with the common upload
/// limits marked so they are one tap away without being the only
/// choices.
class _MbSlider extends StatelessWidget {
  final int valueMb;
  final ValueChanged<int> onChanged;
  const _MbSlider({required this.valueMb, required this.onChanged});

  static const _min = 1.0;
  static const _max = 4096.0;

  // Megabytes span three orders of magnitude, so a linear slider would
  // make everything under 100 MB unusable. Map the track
  // logarithmically instead.
  static double _toSlider(num mb) =>
      (math.log(mb.clamp(_min, _max)) - math.log(_min)) /
      (math.log(_max) - math.log(_min));
  static int _fromSlider(double t) =>
      math.exp(math.log(_min) + t * (math.log(_max) - math.log(_min)))
          .round()
          .clamp(_min.toInt(), _max.toInt());

  static const _presets = <int, String>{
    10: 'Discord',
    25: 'Gmail',
    50: 'Discord Nitro',
    100: '100 MB',
  };

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Slider(
                value: _toSlider(valueMb),
                onChanged: (t) => onChanged(_fromSlider(t)),
              ),
            ),
            SizedBox(
              width: 92,
              child: TextField(
                key: ValueKey(valueMb),
                controller: TextEditingController(text: '$valueMb'),
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(
                    isDense: true, suffixText: 'MB', border: OutlineInputBorder()),
                onSubmitted: (v) {
                  final n = int.tryParse(v.trim());
                  if (n != null && n > 0) onChanged(n.clamp(1, 100000));
                },
              ),
            ),
          ],
        ),
        Wrap(
          spacing: 6,
          children: [
            for (final e in _presets.entries)
              ActionChip(
                label: Text('${e.key} MB · ${e.value}'),
                labelStyle: Theme.of(context)
                    .textTheme
                    .labelSmall
                    ?.copyWith(color: cs.outline),
                visualDensity: VisualDensity.compact,
                materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                onPressed: () => onChanged(e.key),
              ),
          ],
        ),
      ],
    );
  }
}

/// Bitrate as a slider rather than a text box, on a log scale because
/// useful values run from a few hundred kbps to tens of megabits.
class _BitrateSlider extends StatelessWidget {
  final String value; // '4M', '800k'
  final ValueChanged<String> onChanged;
  const _BitrateSlider({required this.value, required this.onChanged});

  static const _minBps = 100000.0; // 100 kbps
  static const _maxBps = 120000000.0; // 120 Mbps

  static double _toSlider(double bps) =>
      (math.log(bps.clamp(_minBps, _maxBps)) - math.log(_minBps)) /
      (math.log(_maxBps) - math.log(_minBps));

  static double _fromSlider(double t) =>
      math.exp(math.log(_minBps) + t * (math.log(_maxBps) - math.log(_minBps)));

  static String _format(double bps) {
    if (bps >= 1000000) {
      final m = bps / 1000000;
      return '${m >= 10 ? m.round() : double.parse(m.toStringAsFixed(1))}M';
    }
    return '${(bps / 1000).round()}k';
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final bps = (ConvertPlanner.parseBitrate(value) ?? 4000000).toDouble();
    return Row(
      children: [
        const SizedBox(width: 190, child: Text('Video bitrate')),
        Expanded(
          child: Slider(
            value: _toSlider(bps),
            onChanged: (t) => onChanged(_format(_fromSlider(t))),
          ),
        ),
        SizedBox(
          width: 92,
          child: TextField(
            key: ValueKey(value),
            controller: TextEditingController(text: value),
            decoration: const InputDecoration(
                isDense: true, border: OutlineInputBorder()),
            onSubmitted: (v) {
              final parsed = ConvertPlanner.parseBitrate(v.trim());
              if (parsed != null && parsed > 0) onChanged(v.trim());
            },
          ),
        ),
        const SizedBox(width: 8),
        SizedBox(
          width: 74,
          child: Text('${(bps / 1000000).toStringAsFixed(1)} Mbps',
              style: Theme.of(context)
                  .textTheme
                  .labelSmall
                  ?.copyWith(color: cs.outline)),
        ),
      ],
    );
  }
}

/// Common FFmpeg picture filters, plus a raw escape hatch.
class _FiltersSection extends StatelessWidget {
  final ConvertPlan plan;
  final ContainerSpec target;
  final EncoderInventory inventory;
  final VoidCallback onChanged;
  const _FiltersSection({
    required this.plan,
    required this.target,
    required this.inventory,
    required this.onChanged,
  });


  static const _scales = <String, String>{
    '': 'Keep original size',
    '3840:-2': '4K — 3840 wide',
    '2560:-2': '1440p — 2560 wide',
    '1920:-2': '1080p — 1920 wide',
    '1280:-2': '720p — 1280 wide',
    '854:-2': '480p — 854 wide',
    '640:-2': '360p — 640 wide',
    'iw/2:-2': 'Half size',
  };
  static const _fpsOptions = <String, String>{
    '': 'Keep original',
    '60': '60 fps',
    '30': '30 fps',
    '24': '24 fps',
    '15': '15 fps',
  };
  static const _rotations = <String, String>{
    '': 'None',
    '90': 'Rotate 90° right',
    '180': 'Rotate 180°',
    '270': 'Rotate 90° left',
    'hflip': 'Flip horizontally',
    'vflip': 'Flip vertically',
  };

  @override
  Widget build(BuildContext context) {
    final f = plan.settings.filters;
    final cs = Theme.of(context).colorScheme;
    return ExpansionTile(
      tilePadding: EdgeInsets.zero,
      childrenPadding: const EdgeInsets.only(bottom: 8),
      initiallyExpanded: !f.isEmpty,
      title: Text('Video filters', style: Theme.of(context).textTheme.titleSmall),
      subtitle: Text(
          f.isEmpty
              ? 'Resize, change frame rate, crop, rotate, denoise'
              : f.chain().join(', '),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: Theme.of(context)
              .textTheme
              .labelSmall
              ?.copyWith(color: f.isEmpty ? cs.outline : cs.tertiary)),
      children: [
        // A filter draws on frames, which a copied stream never gives
        // it. Rather than leaving these controls to do nothing, say so.
        ReencodeNotice(
          plan: plan,
          target: target,
          inventory: inventory,
          type: 'video',
          explanation:
              'The video is being copied bit-for-bit, so nothing here can '
              'reach it — a filter has to draw on frames, and a copy never '
              'produces any.',
          onChanged: onChanged,
        ),
        Row(
          children: [
            const SizedBox(width: 190, child: Text('Resolution')),

            Expanded(
              child: DropdownButton<String>(
                value: _scales.containsKey(f.scale) ? f.scale : '',
                isExpanded: true,
                isDense: true,
                items: [
                  for (final e in _scales.entries)
                    DropdownMenuItem(value: e.key, child: Text(e.value)),
                ],
                onChanged: (v) {
                  f.scale = v ?? '';
                  onChanged();
                },
              ),
            ),
          ],
        ),
        Row(
          children: [
            const SizedBox(width: 190, child: Text('Frame rate')),
            Expanded(
              child: DropdownButton<String>(
                value: _fpsOptions.containsKey(f.fps) ? f.fps : '',
                isExpanded: true,
                isDense: true,
                items: [
                  for (final e in _fpsOptions.entries)
                    DropdownMenuItem(value: e.key, child: Text(e.value)),
                ],
                onChanged: (v) {
                  f.fps = v ?? '';
                  onChanged();
                },
              ),
            ),
          ],
        ),
        Row(
          children: [
            const SizedBox(width: 190, child: Text('Rotate / flip')),
            Expanded(
              child: DropdownButton<String>(
                value: _rotations.containsKey(f.rotate) ? f.rotate : '',
                isExpanded: true,
                isDense: true,
                items: [
                  for (final e in _rotations.entries)
                    DropdownMenuItem(value: e.key, child: Text(e.value)),
                ],
                onChanged: (v) {
                  f.rotate = v ?? '';
                  onChanged();
                },
              ),
            ),
          ],
        ),
        Wrap(
          spacing: 16,
          children: [
            for (final (label, get, set) in <(String, bool, void Function(bool))>[
              ('Deinterlace', f.deinterlace, (v) => f.deinterlace = v),
              ('Denoise', f.denoise, (v) => f.denoise = v),
              ('Grayscale', f.grayscale, (v) => f.grayscale = v),
            ])
              SizedBox(
                width: 200,
                child: CheckboxListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  controlAffinity: ListTileControlAffinity.leading,
                  title: Text(label),
                  value: get,
                  onChanged: (v) {
                    set(v ?? false);
                    onChanged();
                  },
                ),
              ),
          ],
        ),
        BlackBarsRow(plan: plan, onChanged: onChanged),
        _CropField(filters: f, onChanged: onChanged),


        const SizedBox(height: 8),
        TextFormField(
          initialValue: f.custom,
          decoration: InputDecoration(
            labelText: 'Extra filter chain',
            hintText: 'eq=contrast=1.1, unsharp, atadenoise …',
            isDense: true,
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
          ),
          style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
          onChanged: (v) {
            f.custom = v;
            onChanged();
          },
        ),
      ],
    );
  }
}

/// The crop box, which is typed into *and* filled in by the black-bar
/// detector — so it has to take a new value from outside without
/// interrupting anything half-typed.
class _CropField extends StatefulWidget {
  final VideoFilters filters;
  final VoidCallback onChanged;
  const _CropField({required this.filters, required this.onChanged});

  @override
  State<_CropField> createState() => _CropFieldState();
}

class _CropFieldState extends State<_CropField> {
  late final TextEditingController _controller =
      TextEditingController(text: widget.filters.crop);
  final FocusNode _focus = FocusNode();

  @override
  void dispose() {
    _controller.dispose();
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_controller.text != widget.filters.crop && !_focus.hasFocus) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || _focus.hasFocus) return;
        if (_controller.text != widget.filters.crop) {
          _controller.text = widget.filters.crop;
        }
      });
    }
    return Row(
      children: [
        const SizedBox(width: 190, child: Text('Crop (w:h:x:y)')),
        Expanded(
          child: TextField(
            controller: _controller,
            focusNode: _focus,
            decoration: const InputDecoration(
                isDense: true, hintText: 'e.g. 1920:800:0:140'),
            onChanged: (v) {
              widget.filters.crop = v.trim();
              // Typed by hand, so it is no longer the detector's answer.
              widget.filters.cropDetected = false;
              widget.onChanged();
            },
          ),
        ),
      ],
    );
  }
}

/// Keep only part of the input.
class _TrimCard extends StatelessWidget {

  final ConvertPlan plan;
  final VoidCallback onChanged;
  const _TrimCard({required this.plan, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final on = (plan.trimStart ?? '').isNotEmpty ||
        (plan.trimEnd ?? '').isNotEmpty;
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
        child: Row(
          children: [
            SizedBox(
              width: 190,
              child: CheckboxListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                controlAffinity: ListTileControlAffinity.leading,
                title: const Text('Trim'),
                value: on,
                onChanged: (v) {
                  if (v == true) {
                    plan.trimStart = '00:00:00';
                    plan.trimEnd = '';
                  } else {
                    plan.trimStart = null;
                    plan.trimEnd = null;
                  }
                  onChanged();
                },
              ),
            ),
            if (on) ...[
              SizedBox(
                width: 130,
                child: TextFormField(
                  initialValue: plan.trimStart ?? '',
                  decoration: const InputDecoration(
                      labelText: 'From', hintText: '00:00:10', isDense: true),
                  style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
                  onChanged: (v) {
                    plan.trimStart = v.trim();
                    onChanged();
                  },
                ),
              ),
              const SizedBox(width: 12),
              SizedBox(
                width: 130,
                child: TextFormField(
                  initialValue: plan.trimEnd ?? '',
                  decoration: const InputDecoration(
                      labelText: 'To', hintText: '00:01:30', isDense: true),
                  style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
                  onChanged: (v) {
                    plan.trimEnd = v.trim();
                    onChanged();
                  },
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text('Times as hh:mm:ss or seconds. Leave To empty to '
                    'run to the end.',
                    style: Theme.of(context)
                        .textTheme
                        .labelSmall
                        ?.copyWith(color: cs.outline)),
              ),
            ] else
              Expanded(
                child: Text('Convert only part of the file.',
                    style: Theme.of(context)
                        .textTheme
                        .labelSmall
                        ?.copyWith(color: cs.outline)),
              ),
          ],
        ),
      ),
    );
  }
}

/// Where the converted file lands, and whether the source survives.
class _OutputCard extends StatelessWidget {
  final ConvertPlan plan;
  final ContainerSpec target;
  final String sourcePath;
  final VoidCallback onChanged;
  const _OutputCard({
    required this.plan,
    required this.target,
    required this.sourcePath,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final dir = plan.outputDir ?? p.dirname(sourcePath);
    final name =
        '${p.basenameWithoutExtension(sourcePath)}.${target.extension}';
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.save_alt, size: 18, color: cs.primary),
                const SizedBox(width: 8),
                Text('Save to', style: Theme.of(context).textTheme.titleSmall),
                const SizedBox(width: 16),
                Expanded(
                  child: Text('$dir${Platform.pathSeparator}$name',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context)
                          .textTheme
                          .bodySmall
                          ?.copyWith(color: cs.outline)),
                ),
                TextButton(
                  onPressed: () async {
                    final chosen = await getDirectoryPath();
                    if (chosen == null) return;
                    plan.outputDir = chosen;
                    onChanged();
                  },
                  child: const Text('Change…'),
                ),
                if (plan.outputDir != null)
                  TextButton(
                    onPressed: () {
                      plan.outputDir = null;
                      onChanged();
                    },
                    child: const Text('Beside the original'),
                  ),
              ],
            ),
            CheckboxListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              controlAffinity: ListTileControlAffinity.leading,
              title: const Text('Delete the original when it succeeds'),
              subtitle: Text(
                  'Only after the new file is written — a failed conversion '
                  'never removes anything.',
                  style: Theme.of(context)
                      .textTheme
                      .bodySmall
                      ?.copyWith(color: cs.outline)),
              value: plan.settings.deleteSourceWhenDone,
              onChanged: (v) {
                plan.settings.deleteSourceWhenDone = v ?? false;
                onChanged();
              },
            ),
          ],
        ),
      ),
    );
  }
}

class _JobTile extends StatelessWidget {
  final ConvertJob job;
  const _JobTile({required this.job});

  /// What FFmpeg is reporting right now. Every figure here comes from
  /// the encoder itself; nothing is shown that isn't known yet.
  Widget _liveFigures(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final style = Theme.of(context)
        .textTheme
        .labelSmall
        ?.copyWith(color: cs.onSurfaceVariant);
    final items = <(IconData, String)>[
      if (job.progress != null)
        (Icons.percent, (job.progress! * 100).toStringAsFixed(0)),
      if (job.etaSeconds != null)
        (
          Icons.schedule,
          '${ConvertManager.formatDuration(job.etaSeconds!)} left'
        ),
      if (job.speed != null) (Icons.fast_forward, job.speed!),
      if (job.bitrate != null) (Icons.equalizer, job.bitrate!),
      if (job.outputBytes != null)
        (Icons.save_outlined, PlatformUtil.humanBytes(job.outputBytes!)),
      if (job.passes > 1) (Icons.repeat, 'pass ${job.pass}/${job.passes}'),
    ];
    if (items.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(bottom: 2),
      child: Wrap(
        spacing: 14,
        runSpacing: 2,
        children: [
          for (final (icon, text) in items)
            Row(mainAxisSize: MainAxisSize.min, children: [
              Icon(icon, size: 13, color: cs.outline),
              const SizedBox(width: 3),
              Text(text, style: style),
            ]),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final cm = context.read<ConvertManager>();
    final cs = Theme.of(context).colorScheme;
    final color = switch (job.status) {
      JobStatus.done => Colors.green,
      JobStatus.failed => cs.error,
      JobStatus.canceled => cs.outline,
      _ => cs.primary,
    };
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: ListTile(
        leading: Icon(
            job.plan.isPureRemux ? Icons.swap_horiz : Icons.autorenew,
            color: color),
        title: Text(
            job.outputPath.isEmpty
                ? p.basename(job.plan.input.path)
                : '${p.basename(job.plan.input.path)} → ${p.basename(job.outputPath)}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (job.status == JobStatus.running) ...[
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: LinearProgressIndicator(
                    value: job.progress,
                    borderRadius: BorderRadius.circular(4)),
              ),
              _liveFigures(context),
            ],
            Text(job.statusLine, maxLines: 2, overflow: TextOverflow.ellipsis),
            if (job.sidecarFiles.isNotEmpty)
              Text(
                  'Subtitles: ${job.sidecarFiles.map(p.basename).join(', ')}',
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.labelSmall?.copyWith(
                      color: Theme.of(context).colorScheme.tertiary)),
          ],
        ),

        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (job.status == JobStatus.done)
              IconButton(
                tooltip: 'Open folder',
                icon: const Icon(Icons.folder_open),
                onPressed: () => PlatformUtil.revealInFileManager(
                    p.dirname(job.outputPath)),
              ),
            if (job.status == JobStatus.running ||
                job.status == JobStatus.queued)
              IconButton(
                tooltip: 'Cancel',
                icon: const Icon(Icons.stop_circle_outlined),
                onPressed: () => cm.cancel(job),
              )
            else
              IconButton(
                tooltip: 'Remove',
                icon: const Icon(Icons.close),
                onPressed: () => cm.remove(job),
              ),
          ],
        ),
      ),
    );
  }
}
