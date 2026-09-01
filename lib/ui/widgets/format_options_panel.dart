import 'package:flutter/material.dart';

import '../../models/convert.dart';
import '../../services/convert_planner.dart';
import '../../services/ffmpeg_capabilities.dart';
import 'ff_option_field.dart';

/// Every option the chosen encoders and container actually support,
/// read from FFmpeg itself.
///
/// The handful people reach for most often are surfaced first; the rest
/// are one tap away. Nothing an encoder does not support is ever shown,
/// because the list comes from that encoder.
class FormatOptionsPanel extends StatelessWidget {
  final ConvertPlan plan;
  final ContainerSpec target;
  final EncoderInventory inventory;
  final ConvertPlanner planner;
  final VoidCallback onChanged;

  const FormatOptionsPanel({
    super.key,
    required this.plan,
    required this.target,
    required this.inventory,
    required this.planner,
    required this.onChanged,
  });

  /// Options worth showing without digging, in the order people tend to
  /// want them. Anything absent from a given encoder is simply skipped.
  static const _commonVideo = [
    'preset', 'tune', 'profile', 'level', 'cpu-used', 'deadline',
    'g', 'bf', 'refs', 'rc-lookahead', 'aq-mode', 'aq-strength',
    'row-mt', 'tile-columns', 'tiles', 'lag-in-frames', 'film_grain',
    'quality', 'compression_level', 'speed', 'threads',
  ];
  static const _commonAudio = [
    'profile', 'application', 'vbr', 'compression_level', 'cutoff',
    'aac_coder', 'joint_stereo', 'frame_duration', 'packet_loss',
  ];

  /// The container options worth putting in front of people, per muxer.
  /// Anything a build does not have is skipped, and everything else is
  /// still there under "all other options".
  static const _commonMuxer = <String, List<String>>{
    'mp4': [
      'movflags', 'brand', 'movie_timescale', 'video_track_timescale',
      'frag_duration', 'min_frag_duration', 'write_prft', 'use_editlist',
    ],
    'mov': [
      'movflags', 'brand', 'movie_timescale', 'video_track_timescale',
      'write_tmcd', 'use_editlist',
    ],
    'ipod': ['movflags', 'brand', 'movie_timescale'],
    'matroska': [
      'default_mode', 'reserve_index_space', 'cues_to_front', 'live',
      'write_crc32', 'cluster_time_limit', 'cluster_size_limit',
    ],
    'webm': [
      'default_mode', 'dash', 'live', 'cues_to_front',
      'cluster_time_limit', 'cluster_size_limit',
    ],
    'mpegts': [
      'mpegts_flags', 'mpegts_service_type', 'mpegts_service_id', 'muxrate',
      'pat_period', 'sdt_period', 'pcr_period', 'mpegts_m2ts_mode',
    ],
    'gif': ['loop', 'final_delay'],
    'mp3': ['id3v2_version', 'write_xing', 'write_id3v1'],
    'ogg': ['page_duration', 'pagesize', 'serial_offset'],
    'wav': ['rf64', 'write_bext', 'write_peak'],
    'flac': ['write_header'],
    'avi': ['reserve_index_space', 'write_channel_mask'],
  };

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final sections = <Widget>[];

    for (final action in plan.actions) {
      if (action.kind != StreamActionKind.transcode) continue;
      final encoderName = planner.encoderNameFor(
          action.targetCodec!, plan.settings, inventory);
      final caps = plan.encoderCaps[encoderName] as EncoderCaps?;
      if (caps == null || caps.options.isEmpty) continue;
      final isVideo = action.stream.type == 'video';
      sections.add(_encoderSection(
        context,
        title: '${action.targetCodec!.toUpperCase()} options',
        subtitle: encoderName!,
        caps: caps,
        common: isVideo ? _commonVideo : _commonAudio,
        values: plan.streamOptions[action.stream.index] ?? {},
        onSet: (name, value) {
          final map = plan.streamOptions.putIfAbsent(
              action.stream.index, () => <String, String>{});
          if (value == null) {
            map.remove(name);
          } else {
            map[name] = value;
          }
          onChanged();
        },
      ));
    }

    final muxer = plan.muxerCaps as MuxerCaps?;
    if (muxer != null && muxer.options.isNotEmpty) {
      sections.add(_encoderSection(
        context,
        title: '${target.label} container options',
        subtitle: 'muxer ${muxer.name}',
        caps: EncoderCaps(name: muxer.name, options: muxer.options),
        common: _commonMuxer[muxer.name] ?? const [],
        values: plan.muxerOptions,
        onSet: (name, value) {
          if (value == null) {
            plan.muxerOptions.remove(name);
          } else {
            plan.muxerOptions[name] = value;
          }
          onChanged();
        },
      ));
    }

    if (sections.isEmpty) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Text(
          'Nothing is being re-encoded, so there are no encoder options '
          'to set.',
          style: Theme.of(context)
              .textTheme
              .bodySmall
              ?.copyWith(color: cs.outline),
        ),
      );
    }
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: sections);
  }

  Widget _encoderSection(
    BuildContext context, {
    required String title,
    required String subtitle,
    required EncoderCaps caps,
    required List<String> common,
    required Map<String, String> values,
    required void Function(String name, String? value) onSet,
  }) {
    final cs = Theme.of(context).colorScheme;
    final commonOpts = [
      for (final name in common)
        if (caps.option(name) != null) caps.option(name)!,
    ];
    final rest = caps.options
        .where((o) => !commonOpts.any((c) => c.name == o.name))
        .toList()
      ..sort((a, b) => a.name.compareTo(b.name));
    final setCount = values.length;

    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: ExpansionTile(
        title: Row(
          children: [
            Text(title, style: Theme.of(context).textTheme.titleSmall),
            const SizedBox(width: 8),
            if (setCount > 0)
              Chip(
                label: Text('$setCount set'),
                labelStyle: Theme.of(context).textTheme.labelSmall,
                visualDensity: VisualDensity.compact,
                materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
          ],
        ),
        subtitle: Text(
            '$subtitle — ${caps.options.length} options'
            '${caps.pixelFormats.isNotEmpty ? ', ${caps.pixelFormats.length} pixel formats' : ''}'
            '${caps.sampleRates.isNotEmpty ? ', ${caps.sampleRates.length} sample rates' : ''}',
            style: Theme.of(context)
                .textTheme
                .labelSmall
                ?.copyWith(color: cs.outline)),
        childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
        children: [
          for (final o in commonOpts)
            FFOptionField(
              option: o,
              value: values[o.name],
              onChanged: (v) => onSet(o.name, v),
            ),
          if (rest.isNotEmpty)
            ExpansionTile(
              tilePadding: EdgeInsets.zero,
              title: Text('All ${rest.length} other options',
                  style: Theme.of(context).textTheme.labelLarge),
              subtitle: Text(
                  'Everything else this encoder accepts, straight from FFmpeg',
                  style: Theme.of(context)
                      .textTheme
                      .labelSmall
                      ?.copyWith(color: cs.outline)),
              children: [
                for (final o in rest)
                  FFOptionField(
                    option: o,
                    value: values[o.name],
                    onChanged: (v) => onSet(o.name, v),
                  ),
              ],
            ),
        ],
      ),
    );
  }
}
