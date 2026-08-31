/// What FFmpeg itself says a given encoder or muxer can do.
///
/// Rather than hard-coding option lists that drift out of date, Multi
/// asks the local build: `ffmpeg -h encoder=libx264` and
/// `ffmpeg -h muxer=mp4` print every option with its type, range,
/// default and enum values, plus the pixel formats, sample rates and
/// channel layouts the encoder accepts. Everything the Convert page
/// offers is derived from that, so it always matches the binary that
/// will actually run and never offers something unsupported.
library;

import 'dart:io';

enum FFOptionType { boolean, integer, decimal, text, enumerated, flags, binary, duration, rational }

FFOptionType _typeOf(String raw) => switch (raw) {
      'boolean' => FFOptionType.boolean,
      'int' || 'int64' => FFOptionType.integer,
      'float' || 'double' => FFOptionType.decimal,
      'flags' => FFOptionType.flags,
      'binary' => FFOptionType.binary,
      'duration' => FFOptionType.duration,
      'rational' || 'video_rate' || 'image_size' => FFOptionType.rational,
      _ => FFOptionType.text,
    };

class FFOptionChoice {
  final String name;
  final String value;
  final String help;
  const FFOptionChoice(this.name, this.value, this.help);
}

class FFOption {
  final String name;
  final FFOptionType type;
  final String help;
  final double? min, max;
  final String? defaultValue;
  final List<FFOptionChoice> choices;
  final bool video, audio, subtitle;

  const FFOption({
    required this.name,
    required this.type,
    this.help = '',
    this.min,
    this.max,
    this.defaultValue,
    this.choices = const [],
    this.video = false,
    this.audio = false,
    this.subtitle = false,
  });

  bool get isEnum => choices.isNotEmpty;

  /// A slider is only sensible for a bounded, sanely sized range.
  bool get sliderFriendly =>
      !isEnum &&
      (type == FFOptionType.integer || type == FFOptionType.decimal) &&
      min != null &&
      max != null &&
      max! > min! &&
      max! - min! <= 100000 &&
      min! > -1e9 &&
      max! < 1e9;
}

class EncoderCaps {
  final String name;
  final String description;
  final List<String> pixelFormats;
  final List<int> sampleRates;
  final List<String> sampleFormats;
  final List<String> channelLayouts;
  final List<FFOption> options;

  const EncoderCaps({
    required this.name,
    this.description = '',
    this.pixelFormats = const [],
    this.sampleRates = const [],
    this.sampleFormats = const [],
    this.channelLayouts = const [],
    this.options = const [],
  });

  FFOption? option(String name) {
    for (final o in options) {
      if (o.name == name) return o;
    }
    return null;
  }
}

class MuxerCaps {
  final String name;
  final String description;
  final List<String> extensions;
  final String? defaultVideoCodec;
  final String? defaultAudioCodec;
  final List<FFOption> options;

  const MuxerCaps({
    required this.name,
    this.description = '',
    this.extensions = const [],
    this.defaultVideoCodec,
    this.defaultAudioCodec,
    this.options = const [],
  });
}

/// Parses and caches `ffmpeg -h ...` output.
class FfmpegCapabilities {
  final String Function() ffmpegPath;
  FfmpegCapabilities(this.ffmpegPath);

  final Map<String, EncoderCaps?> _encoders = {};
  final Map<String, MuxerCaps?> _muxers = {};

  Future<EncoderCaps?> encoder(String name) async {
    if (_encoders.containsKey(name)) return _encoders[name];
    final text = await _run(['-hide_banner', '-h', 'encoder=$name']);
    final caps = text == null ? null : parseEncoder(name, text);
    _encoders[name] = caps;
    return caps;
  }

  Future<MuxerCaps?> muxer(String name) async {
    if (_muxers.containsKey(name)) return _muxers[name];
    final text = await _run(['-hide_banner', '-h', 'muxer=$name']);
    final caps = text == null ? null : parseMuxer(name, text);
    _muxers[name] = caps;
    return caps;
  }

  Future<String?> _run(List<String> args) async {
    try {
      final r = await Process.run(ffmpegPath(), args)
          .timeout(const Duration(seconds: 20));
      final out = '${r.stdout}${r.stderr}';
      return out.trim().isEmpty ? null : out;
    } catch (_) {
      return null;
    }
  }

  // ---- parsing ----

  static final _optionLine =
      RegExp(r'^\s{2}-([A-Za-z0-9_\-]+)\s+<(\w+)>\s+([EDA-Z.]{11})\s*(.*)$');
  static final _choiceLine =
      RegExp(r'^\s{4,}([A-Za-z0-9_\-.]+)\s+(-?[A-Za-z0-9_.\-]+)\s+([EDA-Z.]{11})\s*(.*)$');
  static final _range = RegExp(r'\(from (\S+) to (\S+)\)');
  static final _default = RegExp(r'\(default ([^)]*)\)');

  static String? _unquote(String? s) {
    if (s == null) return null;
    if (s.length >= 2 && s.startsWith('"') && s.endsWith('"')) {
      return s.substring(1, s.length - 1);
    }
    return s;
  }

  static double? _num(String s) {
    if (s == 'INT_MIN') return -2147483648;
    if (s == 'INT_MAX') return 2147483647;
    if (s == 'FLT_MIN') return -3.4e38;
    if (s == 'FLT_MAX') return 3.4e38;
    if (s == 'I64_MIN') return -9.2e18;
    if (s == 'I64_MAX') return 9.2e18;
    return double.tryParse(s);
  }

  /// Shared option-table parser: FFmpeg prints the same shape for
  /// encoders and muxers.
  static List<FFOption> parseOptions(String text) {
    final options = <FFOption>[];
    var pendingChoices = <FFOptionChoice>[];

    void flush() {
      if (options.isEmpty || pendingChoices.isEmpty) {
        pendingChoices = [];
        return;
      }
      final last = options.removeLast();
      options.add(FFOption(
        name: last.name,
        // A numeric option with named values is really an enum.
        type: last.type == FFOptionType.flags
            ? FFOptionType.flags
            : FFOptionType.enumerated,
        help: last.help,
        min: last.min,
        max: last.max,
        defaultValue: last.defaultValue,
        choices: pendingChoices,
        video: last.video,
        audio: last.audio,
        subtitle: last.subtitle,
      ));
      pendingChoices = [];
    }

    for (final line in text.split('\n')) {
      final opt = _optionLine.firstMatch(line);
      if (opt != null) {
        flush();
        final flags = opt.group(3)!;
        final tail = opt.group(4)!;
        final range = _range.firstMatch(tail);
        final def = _default.firstMatch(tail);
        var help = tail;
        if (range != null) help = help.replaceAll(range.group(0)!, '');
        if (def != null) help = help.replaceAll(def.group(0)!, '');
        options.add(FFOption(
          name: opt.group(1)!,
          type: _typeOf(opt.group(2)!),
          help: help.trim(),
          min: range == null ? null : _num(range.group(1)!),
          max: range == null ? null : _num(range.group(2)!),
          // FFmpeg quotes string defaults: (default "medium").
          defaultValue: _unquote(def?.group(1)?.trim()),
          video: flags.length > 3 && flags[3] == 'V',
          audio: flags.length > 4 && flags[4] == 'A',
          subtitle: flags.length > 5 && flags[5] == 'S',
        ));
        continue;
      }
      final choice = _choiceLine.firstMatch(line);
      if (choice != null && options.isNotEmpty) {
        pendingChoices.add(FFOptionChoice(
            choice.group(1)!, choice.group(2)!, choice.group(4)!.trim()));
      }
    }
    flush();
    return options;
  }

  static List<String> _listAfter(String text, String label) {
    for (final line in text.split('\n')) {
      final t = line.trim();
      if (t.startsWith(label)) {
        return t
            .substring(label.length)
            .trim()
            .split(RegExp(r'\s+'))
            .where((s) => s.isNotEmpty)
            .toList();
      }
    }
    return const [];
  }

  static EncoderCaps parseEncoder(String name, String text) {
    final header = RegExp(r'^Encoder \S+ \[(.*)\]:', multiLine: true)
        .firstMatch(text);
    return EncoderCaps(
      name: name,
      description: header?.group(1) ?? '',
      pixelFormats: _listAfter(text, 'Supported pixel formats:'),
      sampleRates: _listAfter(text, 'Supported sample rates:')
          .map(int.tryParse)
          .whereType<int>()
          .toList(),
      sampleFormats: _listAfter(text, 'Supported sample formats:'),
      channelLayouts: _listAfter(text, 'Supported channel layouts:'),
      options: parseOptions(text),
    );
  }

  static MuxerCaps parseMuxer(String name, String text) {
    final header =
        RegExp(r'^Muxer \S+ \[(.*)\]:', multiLine: true).firstMatch(text);
    String? after(String label) {
      for (final line in text.split('\n')) {
        final t = line.trim();
        if (t.startsWith(label)) {
          return t.substring(label.length).trim().replaceAll('.', '');
        }
      }
      return null;
    }

    return MuxerCaps(
      name: name,
      description: header?.group(1) ?? '',
      extensions:
          (after('Common extensions:') ?? '').split(',').where((s) => s.isNotEmpty).toList(),
      defaultVideoCodec: after('Default video codec:'),
      defaultAudioCodec: after('Default audio codec:'),
      options: parseOptions(text),
    );
  }
}
