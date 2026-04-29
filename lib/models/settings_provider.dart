import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/font_scale.dart';
import '../services/tts_service.dart';

enum VoiceType {
  male('Male'),
  female('Female'),
  neutral('Neutral');

  const VoiceType(this.label);
  final String label;
}

enum DetailLevel {
  brief('Brief'),
  detailed('Rich');

  const DetailLevel(this.label);
  final String label;
}

enum HazardSensitivity {
  low('Low', 40),
  medium('Medium', 80),
  high('High', 150);

  const HazardSensitivity(this.label, this.thresholdCm);
  final String label;
  final int thresholdCm;
}

enum LiveDetectionVerbosity {
  minimal('Minimal', 'Top object, name only'),
  positional('Positional', 'Top object with direction'),
  full('Full', 'Up to 3 objects with direction');

  const LiveDetectionVerbosity(this.label, this.description);
  final String label;
  final String description;
}

enum VisionControlMode {
  cloud('Cloud'),
  local('Local'),
  live('Live');

  const VisionControlMode(this.label);
  final String label;

  VisionControlMode get next {
    return switch (this) {
      VisionControlMode.cloud => VisionControlMode.local,
      VisionControlMode.local => VisionControlMode.live,
      VisionControlMode.live => VisionControlMode.cloud,
    };
  }
}

class SettingsProvider extends ChangeNotifier {
  final TtsSettingsController ttsService;

  SettingsProvider({required this.ttsService}) {
    _load();
  }

  String _lastChangeSummary = '';
  String get lastChangeSummary => _lastChangeSummary;

  // ── Audio ──
  double get speechRate => ttsService.rate;
  double get pitch => ttsService.pitch;
  int get wordsPerMinute => _rateToWpm(ttsService.rate);
  double get volume => _volume;
  VoiceType get voiceType => _voiceType;
  String? get selectedVoiceId => ttsService.selectedVoiceId;
  SpeechEngine get speechEngine => _speechEngine;

  double _volume = 1.0;
  VoiceType _voiceType = VoiceType.neutral;
  SpeechEngine _speechEngine = SpeechEngine.nativeIos;

  void setSpeechRate(double rate) {
    ttsService.setRate(rate);
    _save('speech_rate', rate);
    _recordChange('Speed changed to ${_rateToWpm(rate)} words per minute');
    notifyListeners();
  }

  void setPitch(double pitch) {
    ttsService.setPitch(pitch);
    _save('speech_pitch', pitch);
    _recordChange('Pitch changed to ${pitch.toStringAsFixed(1)}');
    notifyListeners();
  }

  void setVolume(double vol) {
    _volume = vol.clamp(0.0, 1.0);
    ttsService.setVolume(_volume);
    _save('volume', _volume);
    _recordChange('Volume changed to ${(_volume * 100).round()}%');
    notifyListeners();
  }

  void setVoiceType(VoiceType type) {
    _voiceType = type;
    _save('voice_type', type.index);
    _recordChange('Voice type changed to ${type.label}');
    notifyListeners();
  }

  void setSpeechEngine(SpeechEngine engine) {
    _speechEngine = engine;
    if (ttsService is SpeechEngineController) {
      (ttsService as SpeechEngineController).setSpeechEngine(engine);
    }
    _save('speech_engine', engine.name);
    _recordChange('Speech engine changed to ${engine.label}');
    notifyListeners();
  }

  Future<void> restoreSafeSpeechDefaults() async {
    _volume = 1.0;
    _voiceType = VoiceType.neutral;
    _speechEngine = SpeechEngine.nativeIos;
    if (ttsService is SpeechEngineController) {
      await (ttsService as SpeechEngineController).resetSpeechDefaults();
    } else {
      ttsService.setRate(0.5);
      ttsService.setPitch(1.0);
      ttsService.setVolume(1.0);
    }
    await _save('speech_rate', 0.5);
    await _save('speech_pitch', 1.0);
    await _save('volume', 1.0);
    await _save('voice_type', VoiceType.neutral.index);
    await _save('speech_engine', SpeechEngine.nativeIos.name);
    _recordChange('Speech defaults restored');
    notifyListeners();
  }

  Future<List<TtsVoiceOption>> availableVoices() {
    return ttsService.availableVoices();
  }

  Future<void> setVoiceOption(TtsVoiceOption voice) async {
    await ttsService.setVoice(voice);
    await _save('voice_id', voice.id);
    _recordChange('Voice changed to ${voice.label}');
    notifyListeners();
  }

  Future<void> previewVoice() {
    return ttsService.previewVoice(
      'iCan will use this voice for descriptions and commands.',
    );
  }

  // ── Descriptions ──
  // Prompt tuning is internal and voice-driven; the Settings UI no longer
  // exposes mode choices for the demo path.
  DetailLevel _detailLevel = DetailLevel.detailed;
  HazardSensitivity _hazardSensitivity = HazardSensitivity.high;

  DetailLevel get detailLevel => _detailLevel;
  HazardSensitivity get hazardSensitivity => _hazardSensitivity;

  void setDetailLevel(DetailLevel level) {
    _detailLevel = level;
    _save('detail_level', level.index);
    _recordChange('Detail changed to ${level.label}');
    notifyListeners();
  }

  void setHazardSensitivity(HazardSensitivity sensitivity) {
    _hazardSensitivity = sensitivity;
    _save('hazard_sensitivity', sensitivity.index);
    _recordChange('Hazard alerts changed to ${sensitivity.label}');
    notifyListeners();
  }

  // ── Live Detection ──
  LiveDetectionVerbosity _liveDetectionVerbosity = LiveDetectionVerbosity.full;
  VisionControlMode _visionControlMode = VisionControlMode.cloud;

  LiveDetectionVerbosity get liveDetectionVerbosity => _liveDetectionVerbosity;
  VisionControlMode get visionControlMode => _visionControlMode;

  void setLiveDetectionVerbosity(LiveDetectionVerbosity v) {
    _liveDetectionVerbosity = v;
    _save('live_detection_verbosity', v.index);
    _recordChange('Live detection changed to ${v.label}');
    notifyListeners();
  }

  void setVisionControlMode(VisionControlMode mode) {
    _visionControlMode = mode;
    _save('vision_control_mode', mode.name);
    _recordChange('Mode changed to ${mode.label}');
    notifyListeners();
  }

  // ── Accessibility ──
  FontScale _fontScale = FontScale.normal;
  bool _highContrast = true;
  bool _reduceMotion = false;

  FontScale get fontScale => _fontScale;
  bool get highContrast => _highContrast;
  bool get reduceMotion => _reduceMotion;

  void setFontScale(FontScale scale) {
    _fontScale = scale;
    _save('font_scale', scale.index);
    _recordChange('Text size changed to ${scale.label}');
    notifyListeners();
  }

  void setHighContrast(bool value) {
    _highContrast = value;
    _save('high_contrast', value);
    _recordChange('High contrast ${value ? 'enabled' : 'disabled'}');
    notifyListeners();
  }

  void setReduceMotion(bool value) {
    _reduceMotion = value;
    _save('reduce_motion', value);
    _recordChange('Reduce motion ${value ? 'enabled' : 'disabled'}');
    notifyListeners();
  }

  // ── Persistence ──
  Future<void> _load() async {
    try {
      final prefs = await SharedPreferences.getInstance();

      final rate = prefs.getDouble('speech_rate');
      if (rate != null) ttsService.setRate(rate);

      final pitch = prefs.getDouble('speech_pitch');
      if (pitch != null) ttsService.setPitch(pitch);

      _volume = prefs.getDouble('volume') ?? 1.0;
      ttsService.setVolume(_volume);

      final speechEngineName = prefs.getString('speech_engine');
      if (speechEngineName != null) {
        _speechEngine = SpeechEngine.values.firstWhere(
          (engine) => engine.name == speechEngineName,
          orElse: () => SpeechEngine.nativeIos,
        );
      }
      if (ttsService is SpeechEngineController) {
        (ttsService as SpeechEngineController).setSpeechEngine(_speechEngine);
      }

      final voiceIdx = prefs.getInt('voice_type');
      if (voiceIdx != null && voiceIdx < VoiceType.values.length) {
        _voiceType = VoiceType.values[voiceIdx];
      }

      final voiceId = prefs.getString('voice_id');
      if (voiceId != null && voiceId.isNotEmpty) {
        final voices = await ttsService.availableVoices();
        final matching = voices.where((voice) => voice.id == voiceId);
        if (matching.isNotEmpty) {
          await ttsService.setVoice(matching.first);
        }
      }

      final detailIdx = prefs.getInt('detail_level');
      if (detailIdx != null && detailIdx < DetailLevel.values.length) {
        _detailLevel = DetailLevel.values[detailIdx];
      }

      final hazardIdx = prefs.getInt('hazard_sensitivity');
      if (hazardIdx != null && hazardIdx < HazardSensitivity.values.length) {
        _hazardSensitivity = HazardSensitivity.values[hazardIdx];
      }

      final verbIdx = prefs.getInt('live_detection_verbosity');
      if (verbIdx != null && verbIdx < LiveDetectionVerbosity.values.length) {
        _liveDetectionVerbosity = LiveDetectionVerbosity.values[verbIdx];
      }

      final modeName = prefs.getString('vision_control_mode');
      if (modeName != null) {
        _visionControlMode = VisionControlMode.values.firstWhere(
          (mode) => mode.name == modeName,
          orElse: () => VisionControlMode.cloud,
        );
      }

      final fontIdx = prefs.getInt('font_scale');
      if (fontIdx != null && fontIdx < FontScale.values.length) {
        _fontScale = FontScale.values[fontIdx];
      }

      _highContrast = prefs.getBool('high_contrast') ?? true;
      _reduceMotion = prefs.getBool('reduce_motion') ?? false;

      notifyListeners();
    } catch (e) {
      debugPrint('[Settings] Failed to load: $e');
    }
  }

  Future<void> _save(String key, dynamic value) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (value is double) {
        await prefs.setDouble(key, value);
      } else if (value is int) {
        await prefs.setInt(key, value);
      } else if (value is bool) {
        await prefs.setBool(key, value);
      } else if (value is String) {
        await prefs.setString(key, value);
      }
    } catch (e) {
      debugPrint('[Settings] Failed to save $key: $e');
    }
  }

  static int _rateToWpm(double rate) => (100 + (rate * 200)).round();
  static double wpmToRate(int wpm) => ((wpm - 100) / 200).clamp(0.0, 1.0);

  void _recordChange(String summary) {
    _lastChangeSummary = summary;
  }
}
