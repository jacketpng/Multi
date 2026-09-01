import 'package:flutter/material.dart';

import '../../services/ffmpeg_capabilities.dart';

/// Renders one FFmpeg option using the type FFmpeg reported for it: a
/// switch for a boolean, a dropdown for an enum, a slider for a bounded
/// number, a plain field otherwise. Because every detail comes from the
/// binary that will run, this stays correct as FFmpeg changes.
class FFOptionField extends StatelessWidget {
  final FFOption option;
  final String? value;
  final ValueChanged<String?> onChanged;
  const FFOptionField({
    super.key,
    required this.option,
    required this.value,
    required this.onChanged,
  });

  String get _label => option.name.replaceAll('_', ' ').replaceAll('-', ' ');

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final help = option.help.isEmpty
        ? null
        : Text(option.help,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context)
                .textTheme
                .labelSmall
                ?.copyWith(color: cs.outline));

    Widget row(Widget control) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: 200,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [Text(_label), ?help],
                ),
              ),
              Expanded(child: control),
              SizedBox(
                width: 40,
                child: value == null
                    ? null
                    : IconButton(
                        tooltip: 'Back to the default'
                            '${option.defaultValue == null ? '' : ' (${option.defaultValue})'}',
                        icon: const Icon(Icons.undo, size: 16),
                        onPressed: () => onChanged(null),
                      ),
              ),
            ],
          ),
        );

    switch (option.type) {
      case FFOptionType.boolean:
        return row(Align(
          alignment: Alignment.centerLeft,
          child: Switch(
            value: value == 'true' || value == '1',
            onChanged: (v) => onChanged(v ? 'true' : 'false'),
          ),
        ));

      // A flags option is a set, not a choice: FFmpeg takes them joined
      // with '+', and several are usually wanted at once.
      case FFOptionType.flags:
        final selected = (value ?? '')
            .split('+')
            .map((s) => s.trim())
            .where((s) => s.isNotEmpty)
            .toSet();
        return row(Wrap(
          spacing: 6,
          runSpacing: 4,
          children: [
            for (final c in option.choices)
              Tooltip(
                message: c.help,
                child: FilterChip(
                  label: Text(c.name),
                  labelStyle: Theme.of(context).textTheme.labelSmall,
                  visualDensity: VisualDensity.compact,
                  materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  selected: selected.contains(c.name),
                  onSelected: (on) {
                    final next = {...selected};
                    if (on) {
                      next.add(c.name);
                    } else {
                      next.remove(c.name);
                    }
                    onChanged(next.isEmpty ? null : '+${next.join('+')}');
                  },
                ),
              ),
          ],
        ));

      case FFOptionType.enumerated:
        return row(DropdownButton<String>(
          isExpanded: true,
          isDense: true,
          value: option.choices.any((c) => c.name == value) ? value : null,
          hint: Text(option.defaultValue ?? 'default',
              style: Theme.of(context).textTheme.bodySmall),
          items: [
            for (final c in option.choices)
              DropdownMenuItem(
                value: c.name,
                child: Text(c.help.isEmpty ? c.name : '${c.name} — ${c.help}',
                    maxLines: 1, overflow: TextOverflow.ellipsis),
              ),
          ],
          onChanged: onChanged,
        ));

      default:
        if (option.sliderFriendly) {
          final current = double.tryParse(value ?? '') ??
              double.tryParse(option.defaultValue ?? '') ??
              option.min!;
          return row(Row(
            children: [
              Expanded(
                child: Slider(
                  value: current.clamp(option.min!, option.max!),
                  min: option.min!,
                  max: option.max!,
                  divisions:
                      (option.max! - option.min!).round().clamp(1, 1000),
                  label: value ?? option.defaultValue ?? '',
                  onChanged: (v) => onChanged(option.type ==
                          FFOptionType.integer
                      ? v.round().toString()
                      : v.toStringAsFixed(2)),
                ),
              ),
              SizedBox(
                width: 64,
                child: Text(value ?? option.defaultValue ?? '',
                    textAlign: TextAlign.end,
                    style: Theme.of(context).textTheme.labelSmall),
              ),
            ],
          ));
        }
        return row(TextFormField(
          initialValue: value ?? '',
          decoration: InputDecoration(
            isDense: true,
            hintText: option.defaultValue ?? '',
            border: const OutlineInputBorder(),
          ),
          style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
          onChanged: (v) => onChanged(v.trim().isEmpty ? null : v.trim()),
        ));
    }
  }
}
