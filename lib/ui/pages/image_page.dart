import 'package:desktop_drop/desktop_drop.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:provider/provider.dart';

import '../../app.dart';
import '../../models/convert.dart';
import '../../services/image_service.dart';
import '../../util/platform.dart';

class ImagePage extends StatefulWidget {
  const ImagePage({super.key});

  @override
  State<ImagePage> createState() => _ImagePageState();
}

class _ImagePageState extends State<ImagePage> {
  final _settings = ImageSettings();
  final _maxDimController = TextEditingController();
  bool _dragging = false;

  static const _imageExtensions = {
    'jpg', 'jpeg', 'png', 'webp', 'avif', 'gif', 'bmp', 'tiff', 'tif',
    'heic', 'heif', 'svg', 'psd', 'ico', 'jxl',
  };

  Future<void> _pickFiles() async {
    final files = await openFiles(acceptedTypeGroups: [
      const XTypeGroup(label: 'Images', extensions: [
        'jpg', 'jpeg', 'png', 'webp', 'avif', 'gif', 'bmp', 'tiff', 'tif',
        'heic', 'heif', 'svg', 'psd',
      ])
    ]);
    if (files.isEmpty) return;
    if (!mounted) return;
    final svc = context.read<ImageService>();
    svc.addFiles(files.map((f) => f.path).toList());
    svc.planAll(_settings);
  }

  void _replan() {
    context.read<ImageService>().planAll(_settings);
  }

  @override
  Widget build(BuildContext context) {
    return DropTarget(
      enable: PageVisibility.of(context),
      onDragEntered: (_) => setState(() => _dragging = true),
      onDragExited: (_) => setState(() => _dragging = false),
      onDragDone: (detail) {
        setState(() => _dragging = false);
        final paths = detail.files
            .map((f) => f.path)
            .where((path) => _imageExtensions.contains(
                path.split('.').last.toLowerCase()))
            .toList();
        if (paths.isEmpty) return;
        final svc = context.read<ImageService>();
        svc.addFiles(paths);
        svc.planAll(_settings);
      },
      child: Stack(
        children: [
          _body(context),
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
                        child: Text('Drop images to add them',
                            style: Theme.of(context).textTheme.titleMedium),
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

  Widget _body(BuildContext context) {
    final svc = context.watch<ImageService>();
    final fmt =
        imageFormats.firstWhere((f) => f.id == _settings.targetFormat);
    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        Text('Images', style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: 4),
        Text(
          'Convert with ImageMagick. The plan under each file says exactly what happens to the pixels before anything runs.',
          style: Theme.of(context)
              .textTheme
              .bodySmall
              ?.copyWith(color: Theme.of(context).colorScheme.outline),
        ),
        const SizedBox(height: 16),
        Row(
          children: [
            FilledButton.tonalIcon(
              onPressed: _pickFiles,
              icon: const Icon(Icons.add_photo_alternate_outlined),
              label: const Text('Add images'),
            ),
            const SizedBox(width: 10),
            Text('or drop them here',
                style: Theme.of(context)
                    .textTheme
                    .bodySmall
                    ?.copyWith(color: Theme.of(context).colorScheme.outline)),
            const SizedBox(width: 12),
            if (svc.items.any((i) => i.status == JobStatus.done))
              TextButton(
                onPressed: svc.clearFinished,
                child: const Text('Clear finished'),
              ),
          ],
        ),
        const SizedBox(height: 16),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text('Convert to',
                        style: Theme.of(context).textTheme.titleSmall),
                    const SizedBox(width: 16),
                    Wrap(
                      spacing: 8,
                      children: [
                        for (final f in imageFormats)
                          ChoiceChip(
                            label: Text(f.label),
                            selected: _settings.targetFormat == f.id,
                            onSelected: (_) {
                              setState(() => _settings.targetFormat = f.id);
                              _replan();
                            },
                          ),
                      ],
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                if (fmt.supportsLosslessMode)
                  SwitchListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    title: Text('Lossless ${fmt.label}'),
                    subtitle: const Text(
                        'Bigger files, pixel-perfect. Off = lossy with the quality below.'),
                    value: _settings.losslessMode,
                    onChanged: (v) {
                      setState(() => _settings.losslessMode = v);
                      _replan();
                    },
                  ),
                if ((fmt.supportsQuality) &&
                    !(fmt.supportsLosslessMode && _settings.losslessMode))
                  Row(
                    children: [
                      const Text('Quality'),
                      Expanded(
                        child: Slider(
                          value: _settings.quality.toDouble(),
                          min: 10,
                          max: 100,
                          divisions: 90,
                          label: '${_settings.quality}',
                          onChanged: (v) {
                            setState(() => _settings.quality = v.round());
                          },
                          onChangeEnd: (_) => _replan(),
                        ),
                      ),
                      SizedBox(
                          width: 32, child: Text('${_settings.quality}')),
                    ],
                  ),
                Row(
                  children: [
                    const Text('Fit within'),
                    const SizedBox(width: 8),
                    SizedBox(
                      width: 100,
                      child: TextField(
                        controller: _maxDimController,
                        keyboardType: TextInputType.number,
                        decoration: const InputDecoration(
                          hintText: 'e.g. 2048',
                          suffixText: 'px',
                          isDense: true,
                        ),
                        onChanged: (v) {
                          _settings.maxDimension = int.tryParse(v);
                          _replan();
                        },
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text('longest edge — empty keeps original size',
                        style: Theme.of(context).textTheme.bodySmall),
                  ],
                ),
                CheckboxListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  controlAffinity: ListTileControlAffinity.leading,
                  title: const Text('Strip metadata (EXIF, GPS location)'),
                  value: _settings.stripMetadata,
                  onChanged: (v) {
                    setState(() => _settings.stripMetadata = v ?? false);
                    _replan();
                  },
                ),
                TextFormField(
                  initialValue: _settings.extraArgs,
                  decoration: InputDecoration(
                    labelText: 'Extra ImageMagick arguments',
                    hintText: '-sharpen 0x1 -colorspace Gray …',
                    isDense: true,
                    border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(8)),
                  ),
                  style:
                      const TextStyle(fontFamily: 'monospace', fontSize: 13),
                  onChanged: (v) {
                    _settings.extraArgs = v;
                    _replan();
                  },
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 16),
        if (svc.items.isNotEmpty)
          Align(
            alignment: Alignment.centerLeft,
            child: FilledButton.icon(
              onPressed: svc.running ? null : () => svc.runAll(_settings),
              icon: const Icon(Icons.play_arrow),
              label: Text(svc.running
                  ? 'Converting…'
                  : 'Convert ${svc.items.where((i) => i.status == JobStatus.queued).length} images'),
            ),
          ),
        const SizedBox(height: 8),
        for (final item in svc.items) _ImageTile(item: item),
      ],
    );
  }
}

class _ImageTile extends StatelessWidget {
  final ImageJobItem item;
  const _ImageTile({required this.item});

  @override
  Widget build(BuildContext context) {
    final svc = context.read<ImageService>();
    final cs = Theme.of(context).colorScheme;
    final color = switch (item.status) {
      JobStatus.done => Colors.green,
      JobStatus.failed => cs.error,
      JobStatus.running => cs.primary,
      _ => cs.outline,
    };
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: ListTile(
        leading: Icon(
            switch (item.status) {
              JobStatus.done => Icons.check_circle_outline,
              JobStatus.failed => Icons.error_outline,
              JobStatus.running => Icons.hourglass_top,
              _ => Icons.image_outlined,
            },
            color: color),
        title: Text(p.basename(item.inputPath),
            maxLines: 1, overflow: TextOverflow.ellipsis),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (item.plan != null && item.status == JobStatus.queued)
              for (final op in item.plan!.operations)
                Row(
                  children: [
                    Icon(Icons.subdirectory_arrow_right,
                        size: 14, color: cs.outline),
                    const SizedBox(width: 4),
                    Expanded(
                      child: Text(op,
                          style: Theme.of(context)
                              .textTheme
                              .bodySmall
                              ?.copyWith(
                                  color: op.contains('lossy')
                                      ? Colors.orange
                                      : cs.outline)),
                    ),
                  ],
                ),
            if (item.statusLine.isNotEmpty)
              Text(item.statusLine,
                  style: Theme.of(context)
                      .textTheme
                      .bodySmall
                      ?.copyWith(color: color)),
          ],
        ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (item.status == JobStatus.done && item.outputPath != null)
              IconButton(
                tooltip: 'Open folder',
                icon: const Icon(Icons.folder_open),
                onPressed: () => PlatformUtil.revealInFileManager(
                    p.dirname(item.outputPath!)),
              ),
            IconButton(
              tooltip: 'Remove',
              icon: const Icon(Icons.close),
              onPressed: () => svc.remove(item),
            ),
          ],
        ),
      ),
    );
  }
}
