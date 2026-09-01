import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models/convert.dart';
import '../../services/convert_manager.dart';
import '../../services/convert_planner.dart';
import '../../services/ffmpeg_capabilities.dart';

/// Switch every stream of a type from Copy to a real encode.
///
/// Rate, channels, loudness and picture filters are all things done
/// *to* frames, so none of them can touch a stream that is being copied
/// bit-for-bit. Rather than showing controls that quietly do nothing,
/// Multi says so and offers the one change that makes them work.
class ReencodeNotice extends StatelessWidget {
  final ConvertPlan plan;
  final ContainerSpec target;
  final EncoderInventory inventory;
  final String type; // 'video' | 'audio'
  final String explanation;
  final VoidCallback onChanged;
  const ReencodeNotice({
    super.key,
    required this.plan,
    required this.target,
    required this.inventory,
    required this.type,
    required this.explanation,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final planner = context.read<ConvertManager>().planner;
    final copied = [
      for (final a in plan.actions)
        if (a.stream.type == type &&
            a.kind == StreamActionKind.copy &&
            !a.stream.attachedPic)
          a,
    ];
    if (copied.isEmpty) return const SizedBox.shrink();
    final choices = planner.encodableFor(target, type, inventory);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.info_outline, size: 16, color: cs.tertiary),
          const SizedBox(width: 8),
          Expanded(
            child: Text(explanation,
                style: Theme.of(context)
                    .textTheme
                    .bodySmall
                    ?.copyWith(color: cs.tertiary)),
          ),
          const SizedBox(width: 8),
          if (choices.isNotEmpty)
            FilledButton.tonal(
              style: FilledButton.styleFrom(
                visualDensity: VisualDensity.compact,
                textStyle: Theme.of(context).textTheme.labelSmall,
              ),
              onPressed: () {
                for (final a in copied) {
                  // Keep the codec it already is, when the container
                  // allows it — the point is to re-encode, not to change
                  // format as a side effect.
                  final same = choices.any((c) => c.id == a.stream.codec);
                  plan.selection[a.stream.index] =
                      same ? a.stream.codec : choices.first.id;
                }
                onChanged();
              },
              child: Text('Re-encode the $type'),
            ),
        ],
      ),
    );
  }
}

/// A label in the left column, so every control on the page lines up.

class OptionRow extends StatelessWidget {
  final String label;
  final String? help;
  final Widget child;
  const OptionRow({super.key, required this.label, this.help, required this.child});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          SizedBox(
            width: 190,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
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
          Expanded(child: child),
        ],
      ),
    );
  }
}

/// Everything about the audio, in one place: rate, channels, how the
/// bits are spent, and how loud it ends up.
///
/// Multi picks all of this automatically — what an encoder will accept
/// is discovered, not guessed — so every control here is an override of
/// a working default, never a thing you have to fill in.
class AudioCard extends StatelessWidget {
  final ConvertPlan plan;
  final ContainerSpec target;
  final EncoderInventory inventory;
  final VoidCallback onChanged;
  const AudioCard({
    super.key,
    required this.plan,
    required this.target,
    required this.inventory,
    required this.onChanged,
  });

  /// The audio streams being re-encoded — the only ones these settings
  /// can reach. A copied track keeps everything it already had.
  List<StreamAction> get _transcoded => [
        for (final a in plan.actions)
          if (a.kind == StreamActionKind.transcode && a.stream.type == 'audio')
            a,
      ];

  static const _standardRates = [
    8000, 11025, 16000, 22050, 32000, 44100, 48000, 88200, 96000, 192000
  ];

  @override
  Widget build(BuildContext context) {
    final actions = _transcoded;
    final anyAudio = plan.actions.any((a) =>
        a.stream.type == 'audio' && a.kind != StreamActionKind.drop);
    if (actions.isEmpty) {
      if (!anyAudio) return const SizedBox.shrink();
      // Every audio track is being copied, so none of these settings can
      // reach it. Say that, and offer the change that would.
      return Card(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(children: [
                Icon(Icons.graphic_eq,
                    size: 20, color: Theme.of(context).colorScheme.outline),
                const SizedBox(width: 8),
                Text('Audio',
                    style: Theme.of(context).textTheme.titleSmall),
              ]),
              ReencodeNotice(
                plan: plan,
                target: target,
                inventory: inventory,
                type: 'audio',
                explanation:
                    'The audio is being copied bit-for-bit, so its rate, '
                    'channels and loudness stay exactly as they are. '
                    'Changing any of them means re-encoding it.',
                onChanged: onChanged,
              ),
            ],
          ),
        ),
      );
    }
    final cs = Theme.of(context).colorScheme;

    final st = plan.settings;
    final planner = context.read<ConvertManager>().planner;
    final first = actions.first;
    final codec = codecInfo(first.targetCodec!);
    final encoderName =
        planner.encoderNameFor(first.targetCodec!, st, inventory) ?? '';
    final caps = plan.encoderCaps[encoderName] as EncoderCaps?;
    final vbr = CodecCatalog.vbrFor(encoderName);
    final lossless = codec?.lossless ?? false;

    final rates = (caps != null && caps.sampleRates.isNotEmpty)
        ? caps.sampleRates
        : _standardRates;
    final maxCh = codec?.maxChannels ?? 0;
    final channelChoices = [
      for (final n in const [1, 2, 6, 8])
        if (maxCh == 0 || n <= maxCh) n,
    ];
    final sourceChannels = first.stream.channels;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              Icon(Icons.graphic_eq, size: 20, color: cs.primary),
              const SizedBox(width: 8),
              Text('Audio', style: Theme.of(context).textTheme.titleSmall),
              const SizedBox(width: 8),
              Text(
                  '${actions.length} track${actions.length == 1 ? '' : 's'} '
                  're-encoded to ${codec?.label ?? first.targetCodec}',
                  style: Theme.of(context)
                      .textTheme
                      .labelSmall
                      ?.copyWith(color: cs.outline)),
            ]),
            const SizedBox(height: 10),

            // ---- how the bits are spent ----
            if (!lossless) ...[
              if (vbr != null)
                CheckboxListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  controlAffinity: ListTileControlAffinity.leading,
                  title: const Text('Variable bitrate'),
                  subtitle: Text(
                      'Adjusts bitrate automatically to preserve audio '
                      'quality and compression efficiency. ${vbr.help}',
                      style: Theme.of(context).textTheme.labelSmall),
                  value: st.audioVbr,
                  onChanged: (v) {
                    st.audioVbr = v ?? false;
                    onChanged();
                  },
                ),
              if (vbr != null && st.audioVbr)
                OptionRow(
                  label: 'Quality '
                      '(${vbr.format(st.audioVbrQuality ?? vbr.def)})',
                  help: vbr.lowerIsBetter
                      ? 'lower is better'
                      : 'higher is better',
                  child: Slider(
                    value: (st.audioVbrQuality ?? vbr.def)
                        .clamp(vbr.min, vbr.max),
                    min: vbr.min,
                    max: vbr.max,
                    divisions: (vbr.max - vbr.min).round().clamp(1, 100),
                    label: vbr.format(st.audioVbrQuality ?? vbr.def),
                    onChanged: (v) {
                      st.audioVbrQuality = v;
                      onChanged();
                    },
                  ),
                ),
              if (vbr == null || !st.audioVbr)
                OptionRow(
                  label: 'Bitrate',
                  child: DropdownButton<int?>(
                    value: st.audioKbps,
                    isDense: true,
                    items: const [
                      DropdownMenuItem(
                          value: null, child: Text('Codec default')),
                      DropdownMenuItem(value: 64, child: Text('64 kbps')),
                      DropdownMenuItem(value: 96, child: Text('96 kbps')),
                      DropdownMenuItem(value: 128, child: Text('128 kbps')),
                      DropdownMenuItem(value: 160, child: Text('160 kbps')),
                      DropdownMenuItem(value: 192, child: Text('192 kbps')),
                      DropdownMenuItem(value: 256, child: Text('256 kbps')),
                      DropdownMenuItem(value: 320, child: Text('320 kbps')),
                      DropdownMenuItem(value: 448, child: Text('448 kbps')),
                      DropdownMenuItem(value: 640, child: Text('640 kbps')),
                    ],
                    onChanged: (v) {
                      st.audioKbps = v;
                      onChanged();
                    },
                  ),
                ),
            ],

            // ---- shape ----
            OptionRow(
              label: 'Sample rate',
              help: caps != null && caps.sampleRates.isNotEmpty
                  ? '${caps.sampleRates.length} accepted by $encoderName'
                  : null,
              child: DropdownButton<int?>(
                value: rates.contains(st.audioSampleRate)
                    ? st.audioSampleRate
                    : null,
                isDense: true,
                items: [
                  DropdownMenuItem(
                    value: null,
                    child: Text(first.stream.sampleRate != null
                        ? 'Keep source (${(first.stream.sampleRate! / 1000).toStringAsFixed(1)} kHz)'
                        : 'Keep source'),
                  ),
                  for (final r in rates)
                    DropdownMenuItem(
                        value: r,
                        child: Text('${_kHz(r)} kHz')),
                ],
                onChanged: (v) {
                  st.audioSampleRate = v;
                  onChanged();
                },
              ),
            ),
            OptionRow(
              label: 'Channels',
              help: maxCh > 0
                  ? '${codec?.label ?? encoderName} holds at most $maxCh'
                  : null,
              child: DropdownButton<int?>(
                value: channelChoices.contains(st.audioChannels)
                    ? st.audioChannels
                    : null,
                isDense: true,
                items: [
                  DropdownMenuItem(
                    value: null,
                    child: Text(sourceChannels != null
                        ? 'Keep source (${_channelLabel(sourceChannels)})'
                        : 'Keep source'),
                  ),
                  for (final n in channelChoices)
                    DropdownMenuItem(value: n, child: Text(_channelLabel(n))),
                ],
                onChanged: (v) {
                  st.audioChannels = v;
                  onChanged();
                },
              ),
            ),

            const Divider(height: 24),

            // ---- loudness ----
            Text('Loudness', style: Theme.of(context).textTheme.labelLarge),
            const SizedBox(height: 6),
            SegmentedButton<AudioNormalize>(
              segments: [
                for (final m in AudioNormalize.values)
                  ButtonSegment(
                    value: m,
                    label: Tooltip(message: m.description, child: Text(m.label)),
                  ),
              ],
              selected: {st.normalize},
              showSelectedIcon: false,
              style: const ButtonStyle(
                visualDensity: VisualDensity.compact,
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              onSelectionChanged: (s) {
                st.normalize = s.first;
                onChanged();
              },
            ),
            const SizedBox(height: 4),
            Text(st.normalize.description,
                style: Theme.of(context)
                    .textTheme
                    .bodySmall
                    ?.copyWith(color: cs.outline)),
            if (st.normalize == AudioNormalize.loudnorm) ...[
              const SizedBox(height: 6),
              _slider(context, 'Target loudness',
                  '${st.loudnessTarget.toStringAsFixed(1)} LUFS · '
                      'streaming services use −14 to −16',
                  st.loudnessTarget, -30, -5, (v) {
                st.loudnessTarget = double.parse(v.toStringAsFixed(1));
                onChanged();
              }),
              _slider(context, 'True peak ceiling',
                  '${st.truePeak.toStringAsFixed(1)} dBTP — nothing goes above this',
                  st.truePeak, -9, 0, (v) {
                st.truePeak = double.parse(v.toStringAsFixed(1));
                onChanged();
              }),
              _slider(context, 'Loudness range',
                  '${st.loudnessRange.toStringAsFixed(1)} LU — how much the '
                      'quiet and loud parts may differ',
                  st.loudnessRange, 1, 20, (v) {
                st.loudnessRange = double.parse(v.toStringAsFixed(1));
                onChanged();
              }),
            ],
            if (st.normalize == AudioNormalize.peak)
              _PeakMeasureRow(plan: plan, onChanged: onChanged),
            _slider(
                context,
                'Extra gain',
                st.gainDb == 0
                    ? 'no change'
                    : '${st.gainDb > 0 ? '+' : ''}${st.gainDb.toStringAsFixed(1)} dB',
                st.gainDb,
                -30,
                30, (v) {
              st.gainDb = double.parse(v.toStringAsFixed(1));
              onChanged();
            }),
          ],
        ),
      ),
    );
  }

  /// '48' rather than '48.0', but '44.1' where it matters.
  static String _kHz(int rate) =>
      (rate / 1000).toStringAsFixed(rate % 1000 == 0 ? 0 : 1);

  static String _channelLabel(int n) => switch (n) {
        1 => 'Mono',
        2 => 'Stereo',
        6 => '5.1 surround',
        8 => '7.1 surround',
        _ => '$n channels',
      };

  static Widget _slider(BuildContext context, String label, String help,
          double value, double min, double max, ValueChanged<double> onChanged) =>
      OptionRow(
        label: label,
        help: help,
        child: Slider(
          value: value.clamp(min, max),
          min: min,
          max: max,
          divisions: ((max - min) * 2).round(),
          label: value.toStringAsFixed(1),
          onChanged: onChanged,
        ),
      );
}

/// Peak normalisation needs to know how loud the file already is, and
/// the only way to know that is to look.
class _PeakMeasureRow extends StatefulWidget {
  final ConvertPlan plan;
  final VoidCallback onChanged;
  const _PeakMeasureRow({required this.plan, required this.onChanged});

  @override
  State<_PeakMeasureRow> createState() => _PeakMeasureRowState();
}

class _PeakMeasureRowState extends State<_PeakMeasureRow> {
  bool _busy = false;
  String _status = '';

  Future<void> _measure() async {
    final cm = context.read<ConvertManager>();
    setState(() {
      _busy = true;
      _status = 'Measuring…';
    });
    final db = await cm.measurePeak(widget.plan,
        onStatus: (s) => setState(() => _status = s));
    if (!mounted) return;
    setState(() {
      _busy = false;
      _status = db == null
          ? 'Could not measure this file — leaving the levels alone.'
          : 'Loudest sample is ${db.toStringAsFixed(1)} dBFS, so the track '
              'goes up by ${(-db).toStringAsFixed(1)} dB.';
    });
    widget.onChanged();
  }

  @override
  Widget build(BuildContext context) {
    final peak = widget.plan.settings.measuredPeakDb;
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Row(
        children: [
          FilledButton.tonalIcon(
            onPressed: _busy ? null : _measure,
            icon: _busy
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.straighten, size: 18),
            label: Text(peak == null ? 'Measure the peak' : 'Measure again'),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              _status.isNotEmpty
                  ? _status
                  : peak == null
                      ? 'Not measured yet — nothing is applied until it is.'
                      : 'Loudest sample is ${peak.toStringAsFixed(1)} dBFS.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
        ],
      ),
    );
  }
}

/// Find the black bars by asking FFmpeg to look at the picture, in
/// enough places that the answer can be trusted.
class BlackBarsRow extends StatefulWidget {
  final ConvertPlan plan;
  final VoidCallback onChanged;
  const BlackBarsRow({super.key, required this.plan, required this.onChanged});

  @override
  State<BlackBarsRow> createState() => _BlackBarsRowState();
}

class _BlackBarsRowState extends State<BlackBarsRow> {
  bool _busy = false;
  bool _cancel = false;
  String _status = '';

  Future<void> _detect() async {
    final cm = context.read<ConvertManager>();
    setState(() {
      _busy = true;
      _cancel = false;
      _status = 'Looking…';
    });
    await cm.detectCrop(
      widget.plan,
      onStatus: (s) {
        if (mounted) setState(() => _status = s);
      },
      isCanceled: () => _cancel,
    );

    if (!mounted) return;
    setState(() {
      _busy = false;
      _status = '';
    });
    widget.onChanged();
  }

  @override
  Widget build(BuildContext context) {
    final f = widget.plan.settings.filters;
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              FilledButton.tonalIcon(
                onPressed: _busy ? null : _detect,
                icon: _busy
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.crop, size: 18),
                label: Text(f.cropDetected
                    ? 'Check the black bars again'
                    : 'Remove black bars'),
              ),
              if (_busy) ...[
                const SizedBox(width: 12),
                Expanded(
                    child: Text(_status,
                        style: Theme.of(context).textTheme.bodySmall)),
                TextButton(
                  onPressed: () => setState(() => _cancel = true),
                  child: Text(_cancel ? 'Stopping…' : 'Stop'),
                ),
              ] else if (f.cropDetected) ...[
                const SizedBox(width: 8),
                IconButton(
                  tooltip: 'Keep the bars',
                  icon: const Icon(Icons.undo, size: 18),
                  onPressed: () {
                    f.crop = '';
                    f.cropDetected = false;
                    f.cropSummary = '';
                    widget.onChanged();
                  },
                ),
              ],
            ],
          ),
          if (!_busy && f.cropSummary.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(f.cropSummary,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: f.cropDetected ? cs.tertiary : cs.outline)),
            ),
        ],
      ),
    );
  }
}

/// Subtitles get the same treatment as everything else: what is there,
/// what happens to it, and anything extra you might want done with it.
class SubtitleCard extends StatelessWidget {
  final ConvertPlan plan;
  final ContainerSpec target;
  final VoidCallback onChanged;
  const SubtitleCard({
    super.key,
    required this.plan,
    required this.target,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final subs = [
      for (final s in plan.input.streams)
        if (s.type == 'subtitle') s,
    ];
    if (subs.isEmpty) return const SizedBox.shrink();
    final cs = Theme.of(context).colorScheme;
    final st = plan.settings;
    final planner = context.read<ConvertManager>().planner;
    final textSubs = [
      for (final s in subs)
        if (!ConvertPlanner.isImageSubtitle(s.codec)) s,
    ];
    final burnNeedsEncode = planner.burnInNeedsTranscode(plan);

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              Icon(Icons.subtitles_outlined, size: 20, color: cs.primary),
              const SizedBox(width: 8),
              Text('Subtitles', style: Theme.of(context).textTheme.titleSmall),
              const SizedBox(width: 8),
              Text(
                  '${subs.length} track${subs.length == 1 ? '' : 's'}'
                  '${textSubs.length < subs.length ? ', ${subs.length - textSubs.length} image-based' : ''}',
                  style: Theme.of(context)
                      .textTheme
                      .labelSmall
                      ?.copyWith(color: cs.outline)),
            ]),
            const SizedBox(height: 10),
            OptionRow(
              label: 'Burn into the picture',
              help: 'Paints one track onto every frame, permanently',
              child: DropdownButton<int?>(
                value: st.burnInSubtitle,
                isDense: true,
                isExpanded: true,
                items: [
                  const DropdownMenuItem(
                      value: null, child: Text('No — keep them as tracks')),
                  for (final s in subs)
                    DropdownMenuItem(
                      value: s.index,
                      child: Text(
                          '#${s.index} · ${s.codec}'
                          '${s.language != null ? ' · ${s.language}' : ''}'
                          '${ConvertPlanner.isImageSubtitle(s.codec) ? ' (image)' : ''}',
                          overflow: TextOverflow.ellipsis),
                    ),
                ],
                onChanged: (v) {
                  st.burnInSubtitle = v;
                  onChanged();
                },
              ),
            ),
            if (st.burnInSubtitle != null && burnNeedsEncode)
              Padding(
                padding: const EdgeInsets.only(top: 4, bottom: 4),
                child: Row(children: [
                  Icon(Icons.info_outline, size: 15, color: cs.tertiary),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                        'Burning in means drawing on every frame, so the '
                        'video has to be re-encoded — it cannot be copied. '
                        'Pick a codec for the video stream above.',
                        style: Theme.of(context)
                            .textTheme
                            .bodySmall
                            ?.copyWith(color: cs.tertiary)),
                  ),
                ]),
              ),
            const Divider(height: 20),
            CheckboxListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              controlAffinity: ListTileControlAffinity.leading,
              title: const Text('Also save the subtitles as separate files'),
              subtitle: Text(
                  textSubs.isEmpty
                      ? 'Nothing to write — every track here is image-based, '
                          'and there is no text in a picture to save.'
                      : 'Writes ${textSubs.length} sidecar '
                          'file${textSubs.length == 1 ? '' : 's'} next to the '
                          'output, named by language.',
                  style: Theme.of(context).textTheme.labelSmall),
              value: plan.extractSubtitles && textSubs.isNotEmpty,
              onChanged: textSubs.isEmpty
                  ? null
                  : (v) {
                      plan.extractSubtitles = v ?? false;
                      onChanged();
                    },
            ),
            if (plan.extractSubtitles && textSubs.isNotEmpty)
              OptionRow(
                label: 'Sidecar format',
                child: DropdownButton<String>(
                  value: plan.extractSubtitleFormat,
                  isDense: true,
                  items: const [
                    DropdownMenuItem(
                        value: 'subrip', child: Text('SRT — plays everywhere')),
                    DropdownMenuItem(
                        value: 'ass',
                        child: Text('ASS — keeps styling and positioning')),
                    DropdownMenuItem(
                        value: 'webvtt', child: Text('WebVTT — for the web')),
                  ],
                  onChanged: (v) {
                    plan.extractSubtitleFormat = v ?? 'subrip';
                    onChanged();
                  },
                ),
              ),
            if (target.subtitle.isEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(
                    '${target.label} cannot hold subtitle tracks at all. Burn '
                    'them in, save them as separate files, or both.',
                    style: Theme.of(context)
                        .textTheme
                        .bodySmall
                        ?.copyWith(color: cs.outline)),
              ),
          ],
        ),
      ),
    );
  }
}

/// Keep only the languages you want. Works on audio and subtitles
/// together, because that is how people think about it: "English only".
class LanguageFilterBar extends StatelessWidget {
  final ConvertPlan plan;
  final ContainerSpec target;
  final EncoderInventory inventory;
  final VoidCallback onChanged;
  const LanguageFilterBar({
    super.key,
    required this.plan,
    required this.target,
    required this.inventory,
    required this.onChanged,
  });

  /// Languages currently surviving into the output.
  Set<String> _kept() => {
        for (final s in plan.input.streams)
          if ((s.type == 'audio' || s.type == 'subtitle') &&
              plan.selection[s.index] != 'drop')
            (s.language ?? 'und').toLowerCase(),
      };

  int _countFor(String lang) => plan.input.streams
      .where((s) =>
          (s.type == 'audio' || s.type == 'subtitle') &&
          (s.language ?? 'und').toLowerCase() == lang)
      .length;

  @override
  Widget build(BuildContext context) {
    final langs = plan.languagesPresent.toList()..sort();
    // With one language there is nothing to choose between.
    if (langs.length < 2) return const SizedBox.shrink();
    final cs = Theme.of(context).colorScheme;
    final kept = _kept();
    final planner = context.read<ConvertManager>().planner;

    return Padding(
      padding: const EdgeInsets.only(top: 4, bottom: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            Icon(Icons.translate, size: 16, color: cs.outline),
            const SizedBox(width: 6),
            Text('Languages to keep',
                style: Theme.of(context).textTheme.labelLarge),
            const SizedBox(width: 8),
            Text('audio and subtitles',
                style: Theme.of(context)
                    .textTheme
                    .labelSmall
                    ?.copyWith(color: cs.outline)),
          ]),
          const SizedBox(height: 6),
          Wrap(
            spacing: 8,
            runSpacing: 6,
            children: [
              for (final lang in langs)
                FilterChip(
                  label: Text('${languageName(lang)} (${_countFor(lang)})'),
                  labelStyle: Theme.of(context).textTheme.labelSmall,
                  visualDensity: VisualDensity.compact,
                  materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  selected: kept.contains(lang),
                  onSelected: (on) {
                    final next = {...kept};
                    if (on) {
                      next.add(lang);
                    } else {
                      next.remove(lang);
                    }
                    // Deselecting everything means "keep everything",
                    // which is the same as having no filter at all.
                    planner.applyLanguageFilter(plan, target,
                        next.isEmpty ? {} : next, inventory);
                    onChanged();
                  },
                ),
              TextButton(
                onPressed: () {
                  planner.applyLanguageFilter(plan, target, {}, inventory);
                  onChanged();
                },
                style: TextButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
                child: const Text('Keep all'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  /// ISO 639-2 codes people actually meet in media files. Anything else
  /// is shown as the tag itself rather than guessed at.
  static String languageName(String code) => switch (code) {
        'und' => 'Untagged',
        'eng' || 'en' => 'English',
        'jpn' || 'ja' => 'Japanese',
        'spa' || 'es' => 'Spanish',
        'fra' || 'fre' || 'fr' => 'French',
        'deu' || 'ger' || 'de' => 'German',
        'ita' || 'it' => 'Italian',
        'por' || 'pt' => 'Portuguese',
        'rus' || 'ru' => 'Russian',
        'kor' || 'ko' => 'Korean',
        'zho' || 'chi' || 'zh' => 'Chinese',
        'ara' || 'ar' => 'Arabic',
        'hin' || 'hi' => 'Hindi',
        'nld' || 'dut' || 'nl' => 'Dutch',
        'pol' || 'pl' => 'Polish',
        'swe' || 'sv' => 'Swedish',
        'nor' || 'no' => 'Norwegian',
        'dan' || 'da' => 'Danish',
        'fin' || 'fi' => 'Finnish',
        'tur' || 'tr' => 'Turkish',
        'ces' || 'cze' || 'cs' => 'Czech',
        'ell' || 'gre' || 'el' => 'Greek',
        'heb' || 'he' => 'Hebrew',
        'tha' || 'th' => 'Thai',
        'vie' || 'vi' => 'Vietnamese',
        'ind' || 'id' => 'Indonesian',
        'ukr' || 'uk' => 'Ukrainian',
        'hun' || 'hu' => 'Hungarian',
        'ron' || 'rum' || 'ro' => 'Romanian',
        _ => code.toUpperCase(),
      };
}

/// Title, language and the default/forced flags for one stream.
class StreamMetaDialog extends StatefulWidget {
  final ConvertPlan plan;
  final StreamInfo stream;
  const StreamMetaDialog({
    super.key,
    required this.plan,
    required this.stream,
  });

  @override
  State<StreamMetaDialog> createState() => _StreamMetaDialogState();
}

class _StreamMetaDialogState extends State<StreamMetaDialog> {
  late final StreamMeta _meta = widget.plan.metaFor(widget.stream.index);
  late final _title = TextEditingController(text: _meta.title);
  late final _language = TextEditingController(
      text: _meta.language.isEmpty
          ? (widget.stream.language ?? '')
          : _meta.language);

  @override
  void dispose() {
    _title.dispose();
    _language.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.stream;
    return AlertDialog(
      title: Text('Stream #${s.index} — ${s.type}'),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(s.summary, style: Theme.of(context).textTheme.bodySmall),
            const SizedBox(height: 12),
            TextField(
              controller: _title,
              decoration: const InputDecoration(
                labelText: 'Track name',
                hintText: 'Director\'s commentary, Forced signs, …',
                isDense: true,
              ),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: _language,
              decoration: const InputDecoration(
                labelText: 'Language',
                hintText: 'eng, jpn, spa — a three-letter ISO 639-2 code',
                isDense: true,
              ),
            ),
            const SizedBox(height: 8),
            CheckboxListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              controlAffinity: ListTileControlAffinity.leading,
              title: const Text('Default track'),
              subtitle: const Text(
                  'The one a player picks on its own. Only one per type.'),
              value: _meta.isDefault ?? false,
              onChanged: (v) => setState(() => _meta.isDefault = v),
            ),
            CheckboxListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              controlAffinity: ListTileControlAffinity.leading,
              title: const Text('Forced'),
              subtitle: const Text(
                  'Shown even with subtitles off — for signs and foreign '
                  'dialogue in an otherwise untranslated film.'),
              value: _meta.forced ?? false,
              onChanged: (v) => setState(() => _meta.forced = v),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () {
            widget.plan.streamMeta.remove(s.index);
            Navigator.pop(context, true);
          },
          child: const Text('Leave as it was'),
        ),
        FilledButton(
          onPressed: () {
            _meta.title = _title.text.trim();
            _meta.language = _language.text.trim();
            Navigator.pop(context, true);
          },
          child: const Text('Apply'),
        ),
      ],
    );
  }
}

/// GIF has one job and FFmpeg does it badly by default. These are the
/// controls that make the difference.
class GifCard extends StatelessWidget {
  final ConvertPlan plan;
  final ContainerSpec target;
  final EncoderInventory inventory;
  final VoidCallback onChanged;
  const GifCard({
    super.key,
    required this.plan,
    required this.target,
    required this.inventory,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    if (target.id != 'gif') return const SizedBox.shrink();
    StreamAction? video;
    for (final a in plan.actions) {
      if (a.kind == StreamActionKind.transcode &&
          a.stream.type == 'video' &&
          a.targetCodec == 'gif') {
        video = a;
        break;
      }
    }
    if (video == null) return const SizedBox.shrink();

    final cs = Theme.of(context).colorScheme;
    final g = plan.settings.gif;
    final planner = context.read<ConvertManager>().planner;
    final graph = planner.complexGraph(plan, target, video, inventory);

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              Icon(Icons.gif_box_outlined, size: 20, color: cs.primary),
              const SizedBox(width: 8),
              Text('GIF', style: Theme.of(context).textTheme.titleSmall),
            ]),
            const SizedBox(height: 4),
            Text(
              'GIF holds 256 colours per frame. FFmpeg\'s default is a fixed '
              'web palette that has nothing to do with your footage, which is '
              'why GIFs out of FFmpeg usually look banded and dirty. Multi '
              'builds a palette from this clip instead, and dithers against '
              'it.',
              style: Theme.of(context)
                  .textTheme
                  .bodySmall
                  ?.copyWith(color: cs.outline),
            ),
            const SizedBox(height: 10),
            OptionRow(
              label: 'Frame rate (${g.fps} fps)',
              help: 'GIF stores delays in hundredths of a second, so 10, 20, '
                  '25 and 50 are exact and everything else drifts a little',
              child: Slider(
                value: g.fps.toDouble().clamp(1, 50),
                min: 1,
                max: 50,
                divisions: 49,
                label: '${g.fps}',
                onChanged: (v) {
                  g.fps = v.round();
                  onChanged();
                },
              ),
            ),
            OptionRow(
              label: g.width == 0
                  ? 'Width (keep source)'
                  : 'Width (${g.width} px)',
              help: 'The single biggest lever on file size',
              child: Slider(
                value: g.width.toDouble().clamp(0, 1280),
                min: 0,
                max: 1280,
                divisions: 64,
                label: g.width == 0 ? 'source' : '${g.width}',
                onChanged: (v) {
                  g.width = (v / 20).round() * 20;
                  onChanged();
                },
              ),
            ),
            OptionRow(
              label: 'Colours (${g.maxColors})',
              help: 'Fewer colours, smaller file',
              child: Slider(
                value: g.maxColors.toDouble().clamp(4, 256),
                min: 4,
                max: 256,
                divisions: 63,
                label: '${g.maxColors}',
                onChanged: (v) {
                  g.maxColors = (v / 4).round() * 4;
                  onChanged();
                },
              ),
            ),
            OptionRow(
              label: 'Palette from',
              child: DropdownButton<String>(
                value: g.statsMode,
                isDense: true,
                isExpanded: true,
                items: const [
                  DropdownMenuItem(
                      value: 'diff',
                      child: Text(
                          'What moves — best for clips with a still background')),
                  DropdownMenuItem(
                      value: 'full',
                      child: Text('The whole frame — every pixel counts alike')),
                  DropdownMenuItem(
                      value: 'single',
                      child:
                          Text('Each frame separately — biggest file, best colour')),
                ],
                onChanged: (v) {
                  g.statsMode = v ?? 'diff';
                  onChanged();
                },
              ),
            ),
            OptionRow(
              label: 'Dither',
              help: 'How the in-between colours are faked',
              child: DropdownButton<String>(
                value: g.dither,
                isDense: true,
                isExpanded: true,
                items: const [
                  DropdownMenuItem(
                      value: 'bayer',
                      child: Text('Bayer — a fixed pattern, compresses smallest')),
                  DropdownMenuItem(
                      value: 'floyd_steinberg',
                      child: Text('Floyd–Steinberg — smoother, larger file')),
                  DropdownMenuItem(
                      value: 'sierra2_4a',
                      child: Text('Sierra — a middle ground')),
                  DropdownMenuItem(
                      value: 'none',
                      child: Text('None — hard banding, smallest file')),
                ],
                onChanged: (v) {
                  g.dither = v ?? 'bayer';
                  onChanged();
                },
              ),
            ),
            if (g.dither == 'bayer')
              OptionRow(
                label: 'Pattern size (${g.bayerScale})',
                help: 'Lower is a coarser pattern that compresses better',
                child: Slider(
                  value: g.bayerScale.toDouble().clamp(0, 5),
                  min: 0,
                  max: 5,
                  divisions: 5,
                  label: '${g.bayerScale}',
                  onChanged: (v) {
                    g.bayerScale = v.round();
                    onChanged();
                  },
                ),
              ),
            OptionRow(
              label: 'Looping',
              child: DropdownButton<int>(
                value: g.loop,
                isDense: true,
                items: const [
                  DropdownMenuItem(value: 0, child: Text('Loop forever')),
                  DropdownMenuItem(value: -1, child: Text('Play once')),
                  DropdownMenuItem(value: 1, child: Text('Play twice')),
                  DropdownMenuItem(value: 2, child: Text('Play three times')),
                ],
                onChanged: (v) {
                  g.loop = v ?? 0;
                  onChanged();
                },
              ),
            ),
            CheckboxListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              controlAffinity: ListTileControlAffinity.leading,
              title: const Text('Only redraw what changed'),
              subtitle: const Text(
                  'Leaves untouched parts of the frame alone, which is where '
                  'most of the saving in an animated GIF comes from.'),
              value: g.diffRectangles,
              onChanged: (v) {
                g.diffRectangles = v ?? true;
                onChanged();
              },
            ),
            if (graph != null) ...[
              const SizedBox(height: 8),
              Text('Filter graph',
                  style: Theme.of(context).textTheme.labelSmall?.copyWith(
                      color: cs.outline)),
              const SizedBox(height: 4),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: cs.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: SelectableText(
                  graph.graph.replaceAll(';', ';\n'),
                  style: const TextStyle(
                      fontFamily: 'monospace', fontSize: 11.5),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
