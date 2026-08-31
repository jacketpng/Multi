import '../models/download.dart';

/// GUI-configurable options per engine. Everything not covered here is
/// reachable through the free-form "extra arguments" field.
class EngineOptions {
  static List<OptionDef> forEngine(Engine e) => switch (e) {
        Engine.ytDlp => ytDlp,
        Engine.galleryDl => galleryDl,
        Engine.aria2 => aria2,
      };

  static const ytDlp = <OptionDef>[
    // ---- Format (fallback when no custom format is picked) ----
    ChoiceOption(
      id: 'format',
      label: 'Quality (when no custom format picked)',
      group: 'Format',
      choices: {
        '': 'Best available (default)',
        '-S\x00vcodec:h264,acodec:aac': 'Most compatible',
        '-f\x00bv*[height<=2160]+ba/b': 'Up to 4K',
        '-f\x00bv*[height<=1440]+ba/b': 'Up to 1440p',
        '-f\x00bv*[height<=1080]+ba/b': 'Up to 1080p',
        '-f\x00bv*[height<=720]+ba/b': 'Up to 720p',
        '-f\x00bv*[height<=480]+ba/b': 'Up to 480p',
        '-x\x00--audio-format\x00mp3': 'Audio only — MP3',
        '-x\x00--audio-format\x00m4a': 'Audio only — M4A',
        '-x\x00--audio-format\x00opus': 'Audio only — Opus',
        '-x': 'Audio only — best, no conversion',
      },
      descriptions: {
        '-S\x00vcodec:h264,acodec:aac':
            'Prefers H.264 video + AAC audio when available — plays on everything',
      },
      defaultValue: '',
    ),
    ChoiceOption(
      id: 'container',
      label: 'Prefer container',
      group: 'Format',
      choices: {
        '': 'Automatic',
        '--merge-output-format\x00mp4': 'MP4',
        '--merge-output-format\x00mkv': 'MKV',
        '--merge-output-format\x00webm': 'WebM',
      },
      defaultValue: '',
    ),
    ChoiceOption(
      id: 'preferCodec',
      label: 'Prefer video codec',
      help: 'Nudges format selection toward a codec family',
      group: 'Format',
      choices: {
        '': 'No preference',
        '-S\x00vcodec:h264': 'H.264',
        '-S\x00vcodec:h265': 'HEVC',
        '-S\x00vcodec:av01': 'AV1',
        '-S\x00vcodec:vp9': 'VP9',
      },
      descriptions: {
        '-S\x00vcodec:h264': 'plays everywhere, fastest to encode',
        '-S\x00vcodec:h265': '~40% smaller, slower, less compatible',
        '-S\x00vcodec:av01': 'smallest files, newest devices only',
        '-S\x00vcodec:vp9': 'efficient, made for the web',
      },
      defaultValue: '',
    ),

    // ---- Subtitles ----
    FlagOption(
        id: 'subs',
        label: 'Embed subtitles',
        group: 'Subtitles',
        flagArgs: ['--embed-subs']),
    FlagOption(
        id: 'writeSubs',
        label: 'Save subtitles as separate files',
        group: 'Subtitles',
        flagArgs: ['--write-subs']),
    FlagOption(
        id: 'autoSubs',
        label: 'Include auto-generated subtitles',
        group: 'Subtitles',
        flagArgs: ['--write-auto-subs']),
    TextOption(
        id: 'subLangs',
        label: 'Subtitle languages',
        help: 'Comma-separated, e.g. en,es — "all" for everything',
        group: 'Subtitles',
        flag: '--sub-langs',
        placeholder: 'en.*,es'),

    // ---- Metadata & extras ----
    FlagOption(
        id: 'thumbnail',
        label: 'Embed thumbnail as cover art',
        group: 'Metadata & extras',
        flagArgs: ['--embed-thumbnail']),
    FlagOption(
        id: 'writeThumbnail',
        label: 'Save thumbnail as image file',
        group: 'Metadata & extras',
        flagArgs: ['--write-thumbnail']),
    FlagOption(
        id: 'metadata',
        label: 'Embed metadata & chapters',
        group: 'Metadata & extras',
        flagArgs: ['--embed-metadata', '--embed-chapters']),
    FlagOption(
        id: 'infoJson',
        label: 'Save info JSON next to the file',
        group: 'Metadata & extras',
        flagArgs: ['--write-info-json']),
    FlagOption(
        id: 'description',
        label: 'Save description to a file',
        group: 'Metadata & extras',
        flagArgs: ['--write-description']),
    ChoiceOption(
      id: 'sponsorblock',
      label: 'SponsorBlock',
      group: 'Metadata & extras',
      choices: {
        '': 'Off',
        '--sponsorblock-remove\x00sponsor': 'Cut sponsor segments',
        '--sponsorblock-remove\x00sponsor,intro,outro,selfpromo':
            'Cut sponsors, intros, outros, self-promo',
        '--sponsorblock-mark\x00all': 'Mark all segments as chapters',
      },
      defaultValue: '',
    ),
    FlagOption(
        id: 'chapters',
        label: 'Split into files by chapter',
        group: 'Metadata & extras',
        flagArgs: ['--split-chapters']),

    // ---- Selection ----
    TextOption(
        id: 'playlistItems',
        label: 'Playlist items',
        help: 'e.g. 1-5,8 — leave empty for all',
        group: 'Selection',
        flag: '--playlist-items',
        placeholder: '1-5,8'),
    FlagOption(
        id: 'playlistReverse',
        label: 'Download playlist in reverse order',
        group: 'Selection',
        flagArgs: ['--playlist-reverse']),
    TextOption(
        id: 'maxDownloads',
        label: 'Stop after N downloads',
        group: 'Selection',
        flag: '--max-downloads',
        placeholder: '10'),
    TextOption(
        id: 'dateAfter',
        label: 'Only uploads after date',
        group: 'Selection',
        flag: '--dateafter',
        placeholder: 'YYYYMMDD'),
    TextOption(
        id: 'dateBefore',
        label: 'Only uploads before date',
        group: 'Selection',
        flag: '--datebefore',
        placeholder: 'YYYYMMDD'),
    TextOption(
        id: 'minFilesize',
        label: 'Skip files smaller than',
        group: 'Selection',
        flag: '--min-filesize',
        placeholder: '10M'),
    TextOption(
        id: 'maxFilesize',
        label: 'Skip files larger than',
        group: 'Selection',
        flag: '--max-filesize',
        placeholder: '2G'),
    TextOption(
        id: 'matchFilter',
        label: 'Match filter',
        help: 'e.g. duration > 60 & view_count > 1000',
        group: 'Selection',
        flag: '--match-filter',
        placeholder: 'duration > 60'),
    TextOption(
        id: 'sections',
        label: 'Download only a section',
        help: 'Time range, e.g. *10:15-25:00, or a chapter regex',
        group: 'Selection',
        flag: '--download-sections',
        placeholder: '*10:15-25:00'),

    // ---- Files ----
    TextOption(
        id: 'output',
        label: 'Filename template',
        help: 'yt-dlp output template',
        group: 'Files',
        flag: '-o',
        placeholder: '%(title)s [%(id)s].%(ext)s'),
    FlagOption(
        id: 'restrictFilenames',
        label: 'ASCII-only, shell-safe filenames',
        group: 'Files',
        flagArgs: ['--restrict-filenames']),
    FlagOption(
        id: 'noOverwrites',
        label: 'Never overwrite existing files',
        group: 'Files',
        flagArgs: ['--no-overwrites']),
    TextOption(
        id: 'archive',
        label: 'Archive file (skip already-downloaded)',
        help: 'IDs are recorded here and never fetched twice',
        group: 'Files',
        flag: '--download-archive',
        placeholder: '~/yt-archive.txt'),
    FlagOption(
        id: 'keepFragments',
        label: 'Keep fragments after merging',
        group: 'Files',
        flagArgs: ['--keep-fragments']),

    // ---- Live ----
    FlagOption(
        id: 'liveFromStart',
        label: 'Download livestreams from their start',
        group: 'Live',
        flagArgs: ['--live-from-start']),
    FlagOption(
        id: 'waitForVideo',
        label: 'Wait for scheduled streams (retry each minute)',
        group: 'Live',
        flagArgs: ['--wait-for-video', '60']),

    // ---- Network ----
    FlagOption(
        id: 'aria2downloader',
        label: 'Use aria2 as the downloader (faster on plain HTTP)',
        group: 'Network',
        flagArgs: ['--downloader', 'aria2c']),
    TextOption(
        id: 'limitRate',
        label: 'Speed limit',
        group: 'Network',
        flag: '--limit-rate',
        placeholder: '5M'),
    TextOption(
        id: 'retries',
        label: 'Retries',
        group: 'Network',
        flag: '--retries',
        placeholder: '10, or "infinite"'),
    TextOption(
        id: 'proxy',
        label: 'Proxy',
        group: 'Network',
        flag: '--proxy',
        placeholder: 'socks5://127.0.0.1:9050'),
    FlagOption(
        id: 'forceIpv4',
        label: 'Force IPv4',
        group: 'Network',
        flagArgs: ['--force-ipv4']),
    FlagOption(
        id: 'noCheckCerts',
        label: 'Ignore HTTPS certificate errors',
        group: 'Network',
        flagArgs: ['--no-check-certificates']),
    TextOption(
        id: 'userAgent',
        label: 'User agent',
        group: 'Network',
        flag: '--user-agent',
        placeholder: 'Mozilla/5.0 …'),
    TextOption(
        id: 'referer',
        label: 'Referer',
        group: 'Network',
        flag: '--referer',
        placeholder: 'https://example.com'),
  ];

  static const galleryDl = <OptionDef>[
    // ---- Selection ----
    TextOption(
        id: 'range',
        label: 'Item range',
        help: 'e.g. 1-20 downloads only the first 20 items',
        group: 'Selection',
        flag: '--range',
        placeholder: '1-20'),
    TextOption(
        id: 'filter',
        label: 'Filter expression',
        help: 'Python expression, e.g. image_width >= 1000',
        group: 'Selection',
        flag: '--filter',
        placeholder: "extension not in ('gif',)"),
    TextOption(
        id: 'chapterRange',
        label: 'Chapter range (manga sites)',
        group: 'Selection',
        flag: '--chapter-range',
        placeholder: '1-10'),

    // ---- Files ----
    TextOption(
        id: 'filename',
        label: 'Filename format',
        help: 'gallery-dl filename template',
        group: 'Files',
        flag: '--filename',
        placeholder: '{category}_{id}.{extension}'),
    TextOption(
        id: 'archive',
        label: 'Archive file (skip already-downloaded)',
        help: 'Path to a download archive database',
        group: 'Files',
        flag: '--download-archive',
        placeholder: '~/gallery-archive.sqlite3'),
    FlagOption(
        id: 'metadata',
        label: 'Write metadata JSON next to files',
        group: 'Files',
        flagArgs: ['--write-metadata']),
    FlagOption(
        id: 'writeInfoJson',
        label: 'Write gallery info JSON',
        group: 'Files',
        flagArgs: ['--write-info-json']),
    FlagOption(
        id: 'writeTags',
        label: 'Write tags to .txt files',
        group: 'Files',
        flagArgs: ['--write-tags']),
    FlagOption(
        id: 'zip',
        label: 'Store each gallery as a ZIP',
        group: 'Files',
        flagArgs: ['--zip']),
    FlagOption(
        id: 'noMtime',
        label: 'Don\'t set file dates from the site',
        group: 'Files',
        flagArgs: ['--no-mtime']),
    FlagOption(
        id: 'noPart',
        label: 'Write directly (no .part files)',
        group: 'Files',
        flagArgs: ['--no-part']),
    ChoiceOption(
      id: 'ugoira',
      label: 'Pixiv ugoira animations',
      group: 'Files',
      choices: {
        '': 'Keep as ZIP of frames',
        '--ugoira\x00webm': 'Convert to WebM',
        '--ugoira\x00mp4': 'Convert to MP4',
        '--ugoira\x00gif': 'Convert to GIF',
      },
      defaultValue: '',
    ),

    // ---- Network ----
    TextOption(
        id: 'limitRate',
        label: 'Speed limit',
        group: 'Network',
        flag: '--limit-rate',
        placeholder: '2M'),
    TextOption(
        id: 'retries',
        label: 'Retries',
        group: 'Network',
        flag: '--retries',
        placeholder: '4'),
    TextOption(
        id: 'timeout',
        label: 'HTTP timeout (seconds)',
        group: 'Network',
        flag: '--http-timeout',
        placeholder: '30'),
    TextOption(
        id: 'proxy',
        label: 'Proxy',
        group: 'Network',
        flag: '--proxy',
        placeholder: 'socks5://127.0.0.1:9050'),
    TextOption(
        id: 'userAgent',
        label: 'User agent',
        group: 'Network',
        flag: '--user-agent',
        placeholder: 'Mozilla/5.0 …'),
    FlagOption(
        id: 'noCheckCerts',
        label: 'Ignore HTTPS certificate errors',
        group: 'Network',
        flagArgs: ['--no-check-certificate']),
    TextOption(
        id: 'sleepOverride',
        label: 'Sleep between downloads (overrides preset)',
        help: 'Seconds, or a range like 3.0-8.5',
        group: 'Network',
        flag: '--sleep',
        placeholder: '3.0-8.5'),
  ];

  static const aria2 = <OptionDef>[
    // ---- Connection ----
    ChoiceOption(
      id: 'connections',
      label: 'Connections per file',
      group: 'Connection',
      choices: {
        '': 'From preset',
        '--max-connection-per-server=1\x00--split=1': '1 (gentle)',
        '--max-connection-per-server=4\x00--split=4': '4',
        '--max-connection-per-server=8\x00--split=8': '8',
        '--max-connection-per-server=16\x00--split=16': '16 (max)',
      },
      defaultValue: '',
    ),
    TextOption(
        id: 'minSplit',
        label: 'Min split size',
        help: 'Don\'t split pieces smaller than this',
        group: 'Connection',
        flag: '--min-split-size',
        placeholder: '1M'),
    TextOption(
        id: 'maxTries',
        label: 'Max tries per download',
        group: 'Connection',
        flag: '--max-tries',
        placeholder: '5'),
    TextOption(
        id: 'retryWait',
        label: 'Wait between retries (seconds)',
        group: 'Connection',
        flag: '--retry-wait',
        placeholder: '5'),
    TextOption(
        id: 'timeout',
        label: 'Timeout (seconds)',
        group: 'Connection',
        flag: '--timeout',
        placeholder: '60'),
    TextOption(
        id: 'lowestSpeed',
        label: 'Give up below speed',
        help: 'Close connection when slower than this',
        group: 'Connection',
        flag: '--lowest-speed-limit',
        placeholder: '10K'),

    // ---- Behavior ----
    FlagOption(
        id: 'continue',
        label: 'Resume partial downloads',
        group: 'Behavior',
        flagArgs: ['--continue=true'],
        defaultValue: true),
    FlagOption(
        id: 'autoRename',
        label: 'Auto-rename if file exists',
        group: 'Behavior',
        flagArgs: ['--auto-file-renaming=true'],
        defaultValue: true),
    ChoiceOption(
      id: 'fileAllocation',
      label: 'File allocation',
      group: 'Behavior',
      choices: {
        '': 'Default',
        '--file-allocation=none': 'None (start instantly)',
        '--file-allocation=falloc': 'falloc (fast, modern filesystems)',
        '--file-allocation=prealloc': 'Preallocate (slow start, no fragmentation)',
      },
      defaultValue: '',
    ),
    TextOption(
        id: 'out',
        label: 'Save as filename',
        group: 'Behavior',
        flag: '--out',
        placeholder: 'file.zip'),
    TextOption(
        id: 'checksum',
        label: 'Verify checksum',
        help: 'TYPE=HASH, e.g. sha-256=abcd…',
        group: 'Behavior',
        flag: '--checksum',
        placeholder: 'sha-256=…'),

    // ---- HTTP ----
    TextOption(
        id: 'referer',
        label: 'Referer header',
        help: 'Some hosts refuse downloads without the right referer',
        group: 'HTTP',
        flag: '--referer',
        placeholder: 'https://example.com'),
    TextOption(
        id: 'userAgent',
        label: 'User agent',
        group: 'HTTP',
        flag: '--user-agent',
        placeholder: 'Mozilla/5.0 …'),
    TextOption(
        id: 'header',
        label: 'Extra header',
        help: 'One "Name: value" header',
        group: 'HTTP',
        flag: '--header',
        placeholder: 'Authorization: Bearer …'),
    TextOption(
        id: 'proxy',
        label: 'Proxy',
        group: 'HTTP',
        flag: '--all-proxy',
        placeholder: 'http://127.0.0.1:8080'),

    // ---- Speed ----
    TextOption(
        id: 'limitRate',
        label: 'Overall download limit',
        group: 'Speed',
        flag: '--max-overall-download-limit',
        placeholder: '5M'),
    TextOption(
        id: 'perFileLimit',
        label: 'Per-download limit',
        group: 'Speed',
        flag: '--max-download-limit',
        placeholder: '2M'),

    // ---- BitTorrent ----
    FlagOption(
        id: 'noSeed',
        label: 'Don\'t seed after torrent completes',
        group: 'BitTorrent',
        flagArgs: ['--seed-time=0']),
    TextOption(
        id: 'maxUpload',
        label: 'Max upload speed',
        group: 'BitTorrent',
        flag: '--max-overall-upload-limit',
        placeholder: '256K'),
    TextOption(
        id: 'btTracker',
        label: 'Extra trackers',
        help: 'Comma-separated announce URLs',
        group: 'BitTorrent',
        flag: '--bt-tracker',
        placeholder: 'udp://tracker…'),
  ];
}
