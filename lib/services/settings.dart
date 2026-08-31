import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/convert.dart';
import '../models/download.dart';

/// Persisted defaults for new tasks and conversions.
class Settings extends ChangeNotifier {
  SharedPreferences? _prefs;
  bool _loaded = false;
  bool get loaded => _loaded;

  // ---- Converting ----
  /// Use a hardware encoder whenever this machine has one. Faster, at a
  /// small quality cost, so it stays an opt-out.
  bool preferHardware = true;
  RateMode rateMode = RateMode.constantQuality;

  /// Start from the quality whose estimated size is closest to the
  /// source file, rather than the codec's own default.
  bool matchOriginalSize = true;
  int? audioKbps;
  String videoBitrate = '4M';
  String defaultContainer = 'mp4';

  // ---- Downloading ----
  int maxConcurrent = 3;
  int maxParallelItems = 5;
  PresetId? forcedPreset; // null = auto-pick per site
  bool convertAfterDownload = false;
  String? convertAfterContainer;

  // ---- Tools ----
  bool checkUpdatesOnLaunch = true;

  Future<void> load() async {
    _prefs = await SharedPreferences.getInstance();
    final p = _prefs!;
    preferHardware = p.getBool('preferHardware') ?? true;
    rateMode = (p.getString('rateMode') == 'cbr')
        ? RateMode.constantBitrate
        : RateMode.constantQuality;
    matchOriginalSize = p.getBool('matchOriginalSize') ?? true;
    audioKbps = p.getInt('audioKbps');
    videoBitrate = p.getString('videoBitrate') ?? '4M';
    defaultContainer = p.getString('defaultContainer') ?? 'mp4';
    maxConcurrent = p.getInt('maxConcurrent') ?? 3;
    maxParallelItems = p.getInt('maxParallelItems') ?? 5;
    final preset = p.getString('forcedPreset');
    forcedPreset = preset == null
        ? null
        : PresetId.values.firstWhere((x) => x.name == preset,
            orElse: () => PresetId.balanced);
    convertAfterDownload = p.getBool('convertAfterDownload') ?? false;
    convertAfterContainer = p.getString('convertAfterContainer');
    checkUpdatesOnLaunch = p.getBool('checkUpdatesOnLaunch') ?? true;
    _loaded = true;
    notifyListeners();
  }

  void _set(void Function() change) {
    change();
    notifyListeners();
  }

  void setPreferHardware(bool v) => _set(() {
        preferHardware = v;
        _prefs?.setBool('preferHardware', v);
      });

  void setRateMode(RateMode v) => _set(() {
        rateMode = v;
        _prefs?.setString(
            'rateMode', v == RateMode.constantBitrate ? 'cbr' : 'cq');
      });

  void setMatchOriginalSize(bool v) => _set(() {
        matchOriginalSize = v;
        _prefs?.setBool('matchOriginalSize', v);
      });

  void setAudioKbps(int? v) => _set(() {
        audioKbps = v;
        if (v == null) {
          _prefs?.remove('audioKbps');
        } else {
          _prefs?.setInt('audioKbps', v);
        }
      });

  void setVideoBitrate(String v) => _set(() {
        videoBitrate = v.trim().isEmpty ? '4M' : v.trim();
        _prefs?.setString('videoBitrate', videoBitrate);
      });

  void setDefaultContainer(String v) => _set(() {
        defaultContainer = v;
        _prefs?.setString('defaultContainer', v);
      });

  void setMaxConcurrent(int v) => _set(() {
        maxConcurrent = v.clamp(1, 10);
        _prefs?.setInt('maxConcurrent', maxConcurrent);
      });

  void setMaxParallelItems(int v) => _set(() {
        maxParallelItems = v.clamp(1, 10);
        _prefs?.setInt('maxParallelItems', maxParallelItems);
      });

  void setForcedPreset(PresetId? v) => _set(() {
        forcedPreset = v;
        if (v == null) {
          _prefs?.remove('forcedPreset');
        } else {
          _prefs?.setString('forcedPreset', v.name);
        }
      });

  void setConvertAfterDownload(bool v) => _set(() {
        convertAfterDownload = v;
        _prefs?.setBool('convertAfterDownload', v);
      });

  void setConvertAfterContainer(String? v) => _set(() {
        convertAfterContainer = v;
        if (v == null) {
          _prefs?.remove('convertAfterContainer');
        } else {
          _prefs?.setString('convertAfterContainer', v);
        }
      });

  void setCheckUpdatesOnLaunch(bool v) => _set(() {
        checkUpdatesOnLaunch = v;
        _prefs?.setBool('checkUpdatesOnLaunch', v);
      });

  /// Apply the saved defaults to a freshly planned conversion.
  void applyTo(TranscodeSettings st) {
    st.mode = rateMode;
    st.audioKbps = audioKbps;
    st.videoBitrate = videoBitrate;
  }
}
