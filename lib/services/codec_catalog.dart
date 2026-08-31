/// Codec metadata: what each one is good for, how to drive its
/// encoder, and rough numbers for size estimation.
///
/// The catalog is curated and ranked; anything else the local FFmpeg
/// build can encode is offered too (see [CodecCatalog.forContainer]),
/// so a permissive container like MKV really does list everything,
/// with the codecs people actually use at the top.
library;

class CodecInfo {
  final String id; // ffprobe codec_name
  final String label;
  final String kind; // 'video' | 'audio'
  final String description;
  final String shortDescription;

  /// Preferred software encoder, then fallbacks if it isn't built in.
  final List<String> encoders;

  /// Quality scale for constant-quality mode. Lower is better quality.
  final int crfDefault, crfMin, crfMax;
  final bool supportsCrf;

  /// Bits per pixel at [crfDefault], used for size estimates.
  final double bpp;

  final int defaultKbps; // audio
  final bool lossless;

  /// Sort order: popularity and compatibility first.
  final int rank;

  const CodecInfo({
    required this.id,
    required this.label,
    required this.kind,
    required this.description,
    required this.shortDescription,
    required this.encoders,
    this.crfDefault = 0,
    this.crfMin = 0,
    this.crfMax = 0,
    this.supportsCrf = false,
    this.bpp = 0,
    this.defaultKbps = 0,
    this.lossless = false,
    this.rank = 500,
  });

  String get encoder => encoders.first;
}

/// A hardware encoder family. Hardware encoding is much faster but
/// gives slightly lower quality than software at the same size, and
/// not every family supports constant quality.
class HwFamily {
  final String id;
  final String label;
  final bool supportsConstantQuality;

  /// The family's own quality scale, which is not FFmpeg's CRF.
  final int cqMin, cqMax, cqDefault;

  /// Flag used to express constant quality, for the args builder.
  final String cqFlag;

  const HwFamily({
    required this.id,
    required this.label,
    required this.supportsConstantQuality,
    this.cqMin = 0,
    this.cqMax = 51,
    this.cqDefault = 26,
    this.cqFlag = '',
  });
}

const hwFamilies = <String, HwFamily>{
  'nvenc': HwFamily(
    id: 'nvenc',
    label: 'NVIDIA NVENC',
    supportsConstantQuality: true,
    cqMin: 10, cqMax: 45, cqDefault: 24,
    cqFlag: '-cq',
  ),
  'vaapi': HwFamily(
    id: 'vaapi',
    label: 'VA-API',
    supportsConstantQuality: true,
    cqMin: 10, cqMax: 46, cqDefault: 24,
    cqFlag: '-qp',
  ),
  'qsv': HwFamily(
    id: 'qsv',
    label: 'Intel Quick Sync',
    supportsConstantQuality: true,
    cqMin: 10, cqMax: 45, cqDefault: 24,
    cqFlag: '-global_quality',
  ),
  'amf': HwFamily(
    id: 'amf',
    label: 'AMD AMF',
    supportsConstantQuality: true,
    cqMin: 10, cqMax: 45, cqDefault: 24,
    cqFlag: '-qp_i',
  ),
  // VideoToolbox encodes at a target bitrate; its quality control is
  // not a dependable constant-quality mode, so Multi disables the
  // constant-quality option when it is selected.
  'videotoolbox': HwFamily(
    id: 'videotoolbox',
    label: 'Apple VideoToolbox',
    supportsConstantQuality: false,
  ),
  'vulkan': HwFamily(
    id: 'vulkan',
    label: 'Vulkan',
    supportsConstantQuality: true,
    cqMin: 10, cqMax: 45, cqDefault: 24,
    cqFlag: '-qp',
  ),
};

const _video = <CodecInfo>[
  CodecInfo(
    id: 'h264', label: 'H.264 (AVC)', kind: 'video', rank: 1,
    shortDescription: 'plays everywhere, fastest to encode',
    description:
        'The safe default. Plays on everything and encodes fastest — at the cost of larger files than newer codecs.',
    encoders: ['libx264', 'libopenh264'],
    crfDefault: 20, crfMin: 14, crfMax: 32, supportsCrf: true, bpp: 0.100,
  ),
  CodecInfo(
    id: 'hevc', label: 'HEVC (H.265)', kind: 'video', rank: 2,
    shortDescription: '~40% smaller, slower, less compatible',
    description:
        'Roughly 40% smaller than H.264 at the same quality, but slower to encode and some older devices and browsers can\'t play it.',
    encoders: ['libx265', 'libkvazaar'],
    crfDefault: 24, crfMin: 18, crfMax: 34, supportsCrf: true, bpp: 0.062,
  ),
  CodecInfo(
    id: 'av1', label: 'AV1', kind: 'video', rank: 3,
    shortDescription: 'smallest files, newest devices only',
    description:
        'The most efficient codec — about half the size of H.264 — but the slowest to encode, and only recent devices play it.',
    encoders: ['libsvtav1', 'libaom-av1', 'librav1e'],
    crfDefault: 30, crfMin: 22, crfMax: 45, supportsCrf: true, bpp: 0.050,
  ),
  CodecInfo(
    id: 'vp9', label: 'VP9', kind: 'video', rank: 4,
    shortDescription: 'efficient, made for the web',
    description:
        'The web-video codec (YouTube uses it). Good efficiency, wide browser support, the natural fit for WebM. Slowish to encode.',
    encoders: ['libvpx-vp9'],
    crfDefault: 32, crfMin: 24, crfMax: 45, supportsCrf: true, bpp: 0.062,
  ),
  CodecInfo(
    id: 'vp8', label: 'VP8', kind: 'video', rank: 5,
    shortDescription: 'older WebM codec, very compatible on the web',
    description:
        'VP9\'s predecessor. Less efficient, but plays in anything that handles WebM, including quite old browsers.',
    encoders: ['libvpx'],
    crfDefault: 31, crfMin: 20, crfMax: 45, supportsCrf: true, bpp: 0.090,
  ),
  CodecInfo(
    id: 'mpeg4', label: 'MPEG-4 (Xvid-era)', kind: 'video', rank: 10,
    shortDescription: 'legacy — only for very old players',
    description:
        'Legacy DivX/Xvid-generation codec. Poor efficiency — only useful for very old players, car stereos, and set-top boxes.',
    encoders: ['libxvid', 'mpeg4'],
    crfDefault: 5, crfMin: 2, crfMax: 20, supportsCrf: true, bpp: 0.160,
  ),
  CodecInfo(
    id: 'mpeg2video', label: 'MPEG-2', kind: 'video', rank: 11,
    shortDescription: 'DVD and broadcast standard, very inefficient',
    description:
        'What DVDs and older digital broadcast use. Universally playable on old hardware, but files are large.',
    encoders: ['mpeg2video'],
    crfDefault: 5, crfMin: 2, crfMax: 20, supportsCrf: true, bpp: 0.300,
  ),
  CodecInfo(
    id: 'prores', label: 'ProRes', kind: 'video', rank: 12,
    shortDescription: 'editing master, very large files',
    description:
        'Editing intermediate for video work: virtually lossless and effortless to scrub, but the files are enormous.',
    encoders: ['prores_ks', 'prores', 'prores_aw'],
    bpp: 1.2,
  ),
  CodecInfo(
    id: 'dnxhd', label: 'DNxHD / DNxHR', kind: 'video', rank: 13,
    shortDescription: 'Avid editing master, very large files',
    description:
        'Avid\'s editing intermediate, the DNx equivalent of ProRes. Great for editing, wasteful for delivery.',
    encoders: ['dnxhd'],
    bpp: 1.1,
  ),
  CodecInfo(
    id: 'ffv1', label: 'FFV1', kind: 'video', rank: 14,
    shortDescription: 'lossless, used for archiving',
    description:
        'Mathematically lossless video, the archival choice (used by national libraries). Large, but never loses a pixel.',
    encoders: ['ffv1'],
    bpp: 2.5, lossless: true,
  ),
  CodecInfo(
    id: 'utvideo', label: 'Ut Video', kind: 'video', rank: 15,
    shortDescription: 'lossless, fast to encode and decode',
    description:
        'Lossless codec designed for speed rather than compression — popular for screen capture and editing.',
    encoders: ['utvideo'],
    bpp: 3.0, lossless: true,
  ),
  CodecInfo(
    id: 'huffyuv', label: 'HuffYUV', kind: 'video', rank: 16,
    shortDescription: 'lossless, old but widely readable',
    description:
        'An old lossless codec. Simple and fast, superseded by FFV1 and Ut Video but still widely supported.',
    encoders: ['ffvhuff', 'huffyuv'],
    bpp: 3.2, lossless: true,
  ),
  CodecInfo(
    id: 'magicyuv', label: 'MagicYUV', kind: 'video', rank: 17,
    shortDescription: 'lossless, faster than FFV1',
    description:
        'Modern lossless codec aimed at capture and editing: better compression than HuffYUV, very fast.',
    encoders: ['magicyuv'],
    bpp: 2.8, lossless: true,
  ),
  CodecInfo(
    id: 'mjpeg', label: 'Motion JPEG', kind: 'video', rank: 18,
    shortDescription: 'every frame a JPEG — simple, inefficient',
    description:
        'Each frame stored as a separate JPEG. Trivial to decode and edit, common in cameras, but very inefficient.',
    encoders: ['mjpeg'],
    crfDefault: 5, crfMin: 2, crfMax: 20, supportsCrf: true, bpp: 0.500,
  ),
  CodecInfo(
    id: 'theora', label: 'Theora', kind: 'video', rank: 19,
    shortDescription: 'obsolete open codec, use VP9 instead',
    description:
        'An early royalty-free codec for OGG. Superseded by VP8/VP9 in every respect; kept for legacy files.',
    encoders: ['libtheora'],
    crfDefault: 6, crfMin: 2, crfMax: 10, supportsCrf: true, bpp: 0.180,
  ),
  CodecInfo(
    id: 'wmv2', label: 'Windows Media Video', kind: 'video', rank: 20,
    shortDescription: 'legacy Windows format',
    description:
        'Microsoft\'s legacy codec for .wmv files. Only worth choosing for old Windows-only players.',
    encoders: ['wmv2', 'wmv1'],
    bpp: 0.180,
  ),
  CodecInfo(
    id: 'flv1', label: 'Sorenson Spark (FLV)', kind: 'video', rank: 21,
    shortDescription: 'obsolete Flash video codec',
    description:
        'The old Flash video codec. Obsolete — only for compatibility with legacy .flv files.',
    encoders: ['flv'],
    bpp: 0.200,
  ),
  CodecInfo(
    id: 'dvvideo', label: 'DV', kind: 'video', rank: 22,
    shortDescription: 'camcorder tape format, fixed bitrate',
    description:
        'The MiniDV camcorder format. Fixed ~25 Mbps, so quality settings do nothing — useful for tape workflows.',
    encoders: ['dvvideo'],
    bpp: 0.420,
  ),
  CodecInfo(
    id: 'gif', label: 'GIF', kind: 'video', rank: 23,
    shortDescription: '256 colors, huge files, no audio',
    description:
        'Animated image limited to 256 colors, with no sound and poor compression. For short soundless clips only.',
    encoders: ['gif'],
    bpp: 0.800,
  ),
  CodecInfo(
    id: 'rawvideo', label: 'Raw video', kind: 'video', rank: 40,
    shortDescription: 'uncompressed, colossal files',
    description:
        'No compression at all. Perfect fidelity and gigantic files — normally only used as a pipe format.',
    encoders: ['rawvideo'],
    bpp: 12.0, lossless: true,
  ),
];

// DTS is deliberately absent as an *encode* target: FFmpeg's only DTS
// encoder ("dca") is experimental and refuses to run without -strict -2,
// and its quality is poor. An existing DTS track is still copied, since
// the container tables list dts among what MP4 and MKV can carry.
const _audio = <CodecInfo>[
  CodecInfo(
    id: 'aac', label: 'AAC', kind: 'audio', rank: 1,
    shortDescription: 'standard, plays everywhere',
    description:
        'The standard audio codec — very good quality and near-universal support.',
    encoders: ['aac'],
    defaultKbps: 192,
  ),
  CodecInfo(
    id: 'opus', label: 'Opus', kind: 'audio', rank: 2,
    shortDescription: 'best quality per bit',
    description:
        'Best quality per bit of any audio codec, especially at low bitrates. Some older hardware and Apple apps don\'t play it.',
    encoders: ['libopus', 'opus'],
    defaultKbps: 128,
  ),
  CodecInfo(
    id: 'mp3', label: 'MP3', kind: 'audio', rank: 3,
    shortDescription: 'universal, slightly dated',
    description:
        'Plays literally everywhere. Slightly worse quality per megabyte than AAC or Opus.',
    encoders: ['libmp3lame'],
    defaultKbps: 192,
  ),
  CodecInfo(
    id: 'flac', label: 'FLAC', kind: 'audio', rank: 4,
    shortDescription: 'lossless, ~60% of WAV size',
    description:
        'Lossless — a perfect copy of the audio at roughly 60% of uncompressed size.',
    encoders: ['flac'],
    lossless: true,
  ),
  CodecInfo(
    id: 'alac', label: 'ALAC', kind: 'audio', rank: 5,
    shortDescription: 'lossless for Apple gear',
    description:
        'Lossless for the Apple ecosystem (iTunes, iPhone). Same idea as FLAC, slightly larger.',
    encoders: ['alac'],
    lossless: true,
  ),
  CodecInfo(
    id: 'vorbis', label: 'Vorbis', kind: 'audio', rank: 6,
    shortDescription: 'older open codec, Opus beats it',
    description:
        'Older royalty-free codec, still fine — but Opus beats it at every bitrate. Mainly for OGG and older WebM.',
    encoders: ['libvorbis', 'vorbis'],
    defaultKbps: 160,
  ),
  CodecInfo(
    id: 'ac3', label: 'AC-3 (Dolby Digital)', kind: 'audio', rank: 7,
    shortDescription: 'DVD-era surround, TVs understand it',
    description:
        'DVD-era surround sound that TVs and AV receivers understand natively. Not efficient for stereo.',
    encoders: ['ac3'],
    defaultKbps: 384,
  ),
  CodecInfo(
    id: 'eac3', label: 'E-AC-3 (Dolby Digital Plus)', kind: 'audio', rank: 8,
    shortDescription: 'streaming surround, better than AC-3',
    description:
        'The surround codec used by streaming services. More efficient than AC-3 and widely supported on modern TVs.',
    encoders: ['eac3'],
    defaultKbps: 256,
  ),
  CodecInfo(
    id: 'pcm_s16le', label: 'PCM 16-bit (WAV)', kind: 'audio', rank: 9,
    shortDescription: 'uncompressed CD quality',
    description:
        'Uncompressed studio-style audio at CD depth. Maximum compatibility and editability, large files.',
    encoders: ['pcm_s16le'],
    lossless: true,
  ),
  CodecInfo(
    id: 'pcm_s24le', label: 'PCM 24-bit', kind: 'audio', rank: 10,
    shortDescription: 'uncompressed studio depth',
    description:
        'Uncompressed audio at 24-bit depth, the usual studio recording format. Bigger than 16-bit PCM.',
    encoders: ['pcm_s24le'],
    lossless: true,
  ),
  CodecInfo(
    id: 'truehd', label: 'Dolby TrueHD', kind: 'audio', rank: 12,
    shortDescription: 'lossless surround for Blu-ray',
    description:
        'Lossless multichannel audio used on Blu-ray. Very large; only worth keeping for home-cinema setups.',
    encoders: ['truehd'],
    lossless: true,
  ),
  CodecInfo(
    id: 'wavpack', label: 'WavPack', kind: 'audio', rank: 13,
    shortDescription: 'lossless, niche but capable',
    description:
        'A lossless codec with an optional lossy mode. Well regarded but far less supported than FLAC.',
    encoders: ['wavpack'],
    lossless: true,
  ),
  CodecInfo(
    id: 'wmav2', label: 'Windows Media Audio', kind: 'audio', rank: 14,
    shortDescription: 'legacy Windows audio',
    description:
        'Microsoft\'s legacy audio codec. Only worth choosing for old Windows-only players.',
    encoders: ['wmav2', 'wmav1'],
    defaultKbps: 192,
  ),
  CodecInfo(
    id: 'mp2', label: 'MP2', kind: 'audio', rank: 15,
    shortDescription: 'broadcast standard, predates MP3',
    description:
        'MPEG-1 Layer II, still used in digital broadcasting. Robust, but far less efficient than anything modern.',
    encoders: ['mp2', 'libtwolame'],
    defaultKbps: 224,
  ),
  CodecInfo(
    id: 'tta', label: 'TTA', kind: 'audio', rank: 16,
    shortDescription: 'lossless, rarely supported',
    description:
        'The True Audio lossless codec. Compresses like FLAC but with much narrower player support.',
    encoders: ['tta'],
    lossless: true,
  ),
];

class CodecCatalog {
  static const curated = <CodecInfo>[..._video, ..._audio];

  static CodecInfo? byId(String id) {
    for (final c in curated) {
      if (c.id == id) return c;
    }
    return null;
  }

  /// Build a stand-in entry for an encoder present in the FFmpeg build
  /// that the curated list doesn't describe.
  static CodecInfo generic(String codecId, String kind, String encoder) =>
      CodecInfo(
        id: codecId,
        label: codecId,
        kind: kind,
        shortDescription: 'supported by your FFmpeg build',
        description:
            'Encoded with FFmpeg\'s "$encoder". Multi has no tuned defaults or size estimate for this codec, so it uses the encoder\'s own.',
        encoders: [encoder],
        bpp: 0.15,
        defaultKbps: 192,
        rank: 900,
      );

  /// The first encoder of [c] that exists in this FFmpeg build.
  static String? availableEncoder(CodecInfo c, Set<String> built) {
    for (final e in c.encoders) {
      if (built.contains(e)) return e;
    }
    return null;
  }
}

/// All curated codecs.
const codecCatalog = CodecCatalog.curated;

CodecInfo? codecInfo(String id) => CodecCatalog.byId(id);

/// Short codec blurb for a raw codec string as reported by yt-dlp or
/// ffprobe ('avc1.64001f', 'mp4a.40.2', 'vp9', …), or null if unknown.
String? shortBlurbForRawCodec(String raw) {
  final base = raw.split('.').first.toLowerCase();
  final id = switch (base) {
    'avc1' || 'avc3' || 'h264' => 'h264',
    'hev1' || 'hvc1' || 'h265' || 'hevc' => 'hevc',
    'av01' || 'av1' => 'av1',
    'vp09' || 'vp9' => 'vp9',
    'vp08' || 'vp8' => 'vp8',
    'mp4a' || 'aac' => 'aac',
    'ec-3' || 'eac3' => 'eac3',
    'ac-3' || 'ac3' => 'ac3',
    _ => base,
  };
  return codecInfo(id)?.shortDescription;
}
