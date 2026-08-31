import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:provider/provider.dart';

import '../../models/convert.dart';
import '../../services/convert_manager.dart';
import '../../services/convert_planner.dart';
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

  @override
  void initState() {
    super.initState();
    // Detect hardware encoders early so the toggle is accurate.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      context.read<ConvertManager>().ensureHwDetected();
    });
  }

  Future<void> _pickFile() async {
    final cm = context.read<ConvertManager>();
    final file = await openFile(acceptedTypeGroups: [
      const XTypeGroup(label: 'Media', extensions: [
        'mp4', 'mkv', 'webm', 'avi', 'mov', 'flv', 'ts', 'm2ts', 'wmv',
        'mp3', 'm4a', 'flac', 'opus', 'ogg', 'wav', 'aac', 'wma', 'gif',
      ])
    ]);
    if (file == null || !mounted) return;
    setState(() {
      _probing = true;
      _error = null;
      _input = null;
      _plan = null;
      _target = null;
    });
    try {
      final probe = await cm.planner.probe(file.path);
      setState(() {
        _input = probe;
        _probing = false;
      });
    } catch (e) {
      setState(() {
        _error = '$e';
        _probing = false;
      });
    }
  }

  void _selectTarget(ContainerSpec spec) {
    final cm = context.read<ConvertManager>();
    setState(() {
      _target = spec;
      _plan = cm.planWithDefaults(_input!, spec);
    });
  }

  void _recompute() {
    if (_plan == null || _target == null) return;
    final cm = context.read<ConvertManager>();
    cm.planner.recompute(_plan!, _target!, cm.inventory);
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final cm = context.watch<ConvertManager>();
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
          const SizedBox(height: 16),
          Align(
            alignment: Alignment.centerLeft,
            child: FilledButton.icon(
              onPressed: () {
                cm.enqueue(_plan!, _target!);
                setState(() {
                  _plan = null;
                  _target = null;
                  _input = null;
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
            for (final action in plan.actions)
              _StreamRow(
                plan: plan,
                target: target,
                action: action,
                planner: planner,
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
  const _StreamRow({
    required this.plan,
    required this.target,
    required this.action,
    required this.planner,
    required this.inventory,
    required this.onChanged,
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
        ],
      ),
    );
  }

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

  /// Video and audio streams get a codec choice; subtitles/data stay
  /// automatic.
  List<CodecInfo>? _choicesFor(StreamInfo s) {
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

  bool get _hasAudioTranscode => plan.actions.any((a) =>
      a.kind == StreamActionKind.transcode &&
      a.stream.type == 'audio' &&
      !(codecInfo(a.targetCodec!)?.lossless ?? false));

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
            Row(
              children: [
                const SizedBox(width: 190, child: Text('Video bitrate')),
                SizedBox(
                  width: 120,
                  child: TextFormField(
                    initialValue: st.videoBitrate,
                    decoration:
                        const InputDecoration(isDense: true, hintText: '4M'),
                    onChanged: (v) {
                      st.videoBitrate = v.trim().isEmpty ? '4M' : v.trim();
                      onChanged();
                    },
                  ),
                ),
                const SizedBox(width: 8),
                Text('e.g. 800k, 4M, 12M',
                    style: Theme.of(context)
                        .textTheme
                        .labelSmall
                        ?.copyWith(color: cs.outline)),
              ],
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
                    st.crf = null; // the quality scale changes with it
                    final fam = inventory.hwFamilyFor(codecId);
                    if (v && fam != null && !fam.supportsConstantQuality) {
                      st.mode = RateMode.constantBitrate;
                    }
                    onChanged();
                  },
          ),
          _SizeCapRow(plan: plan, onChanged: onChanged),
        ],
        if (_hasAudioTranscode)
          Row(
            children: [
              const SizedBox(width: 190, child: Text('Audio bitrate')),
              DropdownButton<int?>(
                value: plan.settings.audioKbps,
                isDense: true,
                items: const [
                  DropdownMenuItem(value: null, child: Text('Codec default')),
                  DropdownMenuItem(value: 64, child: Text('64 kbps')),
                  DropdownMenuItem(value: 96, child: Text('96 kbps')),
                  DropdownMenuItem(value: 128, child: Text('128 kbps')),
                  DropdownMenuItem(value: 160, child: Text('160 kbps')),
                  DropdownMenuItem(value: 192, child: Text('192 kbps')),
                  DropdownMenuItem(value: 256, child: Text('256 kbps')),
                  DropdownMenuItem(value: 320, child: Text('320 kbps')),
                  DropdownMenuItem(value: 448, child: Text('448 kbps')),
                ],
                onChanged: (v) {
                  plan.settings.audioKbps = v;
                  onChanged();
                },
              ),
            ],
          ),
        const SizedBox(height: 8),
        _FiltersSection(plan: plan, onChanged: onChanged),
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

/// Keep the output under a chosen size — for upload limits.
class _SizeCapRow extends StatelessWidget {
  final ConvertPlan plan;
  final VoidCallback onChanged;
  const _SizeCapRow({required this.plan, required this.onChanged});

  static const _presets = <int?, String>{
    null: 'No limit',
    8: '8 MB (Discord)',
    10: '10 MB (Discord free)',
    25: '25 MB (Gmail, Discord Nitro Basic)',
    50: '50 MB (Discord Nitro)',
    100: '100 MB',
    500: '500 MB',
  };

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final st = plan.settings;
    final dur = plan.input.durationSeconds;
    final bps = st.sizeCapMb == null
        ? null
        : ConvertPlanner.bitrateForSizeCap(
            st.sizeCapMb!, dur, st.audioKbps ?? 128);
    return Row(
      children: [
        const SizedBox(width: 190, child: Text('Cap file size')),
        DropdownButton<int?>(
          value: _presets.containsKey(st.sizeCapMb) ? st.sizeCapMb : null,
          isDense: true,
          items: [
            for (final e in _presets.entries)
              DropdownMenuItem(value: e.key, child: Text(e.value)),
          ],
          onChanged: (v) {
            st.sizeCapMb = v;
            onChanged();
          },
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Text(
            st.sizeCapMb == null
                ? 'Useful for upload limits — sets the bitrate to fit.'
                : bps == null
                    ? 'The clip has no known duration, so a size cap can\'t be worked out.'
                    : 'Encoding at ~${(bps / 1000).round()} kbps to land under ${st.sizeCapMb} MB.',
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

/// Common FFmpeg picture filters, plus a raw escape hatch.
class _FiltersSection extends StatelessWidget {
  final ConvertPlan plan;
  final VoidCallback onChanged;
  const _FiltersSection({required this.plan, required this.onChanged});

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
        Row(
          children: [
            const SizedBox(width: 190, child: Text('Crop (w:h:x:y)')),
            Expanded(
              child: TextFormField(
                initialValue: f.crop,
                decoration: const InputDecoration(
                    isDense: true, hintText: 'e.g. 1920:800:0:140'),
                onChanged: (v) {
                  f.crop = v.trim();
                  onChanged();
                },
              ),
            ),
          ],
        ),
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

class _JobTile extends StatelessWidget {
  final ConvertJob job;
  const _JobTile({required this.job});

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
            if (job.status == JobStatus.running)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: LinearProgressIndicator(
                    value: job.progress,
                    borderRadius: BorderRadius.circular(4)),
              ),
            Text(job.statusLine, maxLines: 1, overflow: TextOverflow.ellipsis),
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
