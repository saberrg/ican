import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_tts/flutter_tts.dart';

import 'audio_playback_service.dart';
import 'eleven_labs_tts_client.dart';

enum SpeechEngine {
  nativeIos('Native iOS'),
  elevenLabs('ElevenLabs'),
  auto('Auto');

  const SpeechEngine(this.label);

  final String label;
}

class TtsVoiceOption {
  const TtsVoiceOption({
    required this.name,
    required this.locale,
    this.identifier,
    this.quality,
    this.gender,
  });

  final String name;
  final String locale;
  final String? identifier;
  final String? quality;
  final String? gender;

  String get id => identifier?.isNotEmpty == true ? identifier! : name;

  String get label {
    final parts = <String>[name];
    if (quality != null && quality!.isNotEmpty) parts.add(quality!);
    return parts.join(' ');
  }

  bool get isEnhancedAppleVoice {
    final combined = [
      name,
      identifier,
      quality,
    ].whereType<String>().join(' ').toLowerCase();
    return combined.contains('premium') ||
        combined.contains('enhanced') ||
        combined.contains('neural') ||
        combined.contains('siri');
  }

  Map<String, String> get nativeVoice => {'name': name, 'locale': locale};

  static TtsVoiceOption? fromNative(Object? raw) {
    if (raw is! Map) return null;
    final name = raw['name']?.toString();
    final locale = raw['locale']?.toString() ?? raw['language']?.toString();
    if (name == null || name.isEmpty || locale == null || locale.isEmpty) {
      return null;
    }
    return TtsVoiceOption(
      name: name,
      locale: locale,
      identifier: raw['identifier']?.toString(),
      quality: raw['quality']?.toString(),
      gender: raw['gender']?.toString(),
    );
  }
}

abstract interface class SpeechOutput {
  Future<void> speak(String text);
  Future<void> stop();
}

abstract interface class TtsSettingsController implements SpeechOutput {
  double get rate;
  double get pitch;
  String? get selectedVoiceId;
  void setRate(double rate);
  void setPitch(double pitch);
  void setVolume(double vol);
  Future<List<TtsVoiceOption>> availableVoices();
  Future<void> setVoice(TtsVoiceOption voice);
  Future<void> previewVoice([String sample]);
}

abstract interface class SpeechEngineController {
  SpeechEngine get speechEngine;
  void setSpeechEngine(SpeechEngine engine);
  Future<void> resetSpeechDefaults();
}

class TtsService extends ChangeNotifier
    implements TtsSettingsController, SpeechEngineController {
  TtsService._({
    ElevenLabsTtsClient? elevenLabsClient,
    Mp3AudioPlayer? audioPlayer,
  }) : _elevenLabsClient = elevenLabsClient ?? ElevenLabsTtsClient(),
       _audioPlayer = audioPlayer ?? NativeMp3AudioPlayer();

  @visibleForTesting
  factory TtsService.testing({
    ElevenLabsTtsClient? elevenLabsClient,
    Mp3AudioPlayer? audioPlayer,
  }) {
    return TtsService._(
      elevenLabsClient: elevenLabsClient,
      audioPlayer: audioPlayer,
    );
  }

  static final TtsService instance = TtsService._();

  final FlutterTts _flutterTts = FlutterTts();
  final ElevenLabsTtsClient _elevenLabsClient;
  final Mp3AudioPlayer _audioPlayer;

  bool _initialized = false;
  bool get initialized => _initialized;

  bool _isSpeaking = false;
  bool get isSpeaking => _isSpeaking;

  double _rate = 0.5;
  @override
  double get rate => _rate;

  double _pitch = 1.0;
  @override
  double get pitch => _pitch;

  double _volume = 1.0;
  double get volume => _volume;

  SpeechEngine _speechEngine = SpeechEngine.nativeIos;
  @override
  SpeechEngine get speechEngine => _speechEngine;

  List<TtsVoiceOption> _voices = const [];
  TtsVoiceOption? _selectedVoice;

  @override
  String? get selectedVoiceId => _selectedVoice?.id;

  Future<void> init() async {
    if (_initialized) return;

    await _tryNativeSetup(
      'set default language',
      () => _flutterTts.setLanguage('en-US'),
    );
    await _tryNativeSetup(
      'set default rate',
      () => _flutterTts.setSpeechRate(_rate),
    );
    await _tryNativeSetup(
      'set default pitch',
      () => _flutterTts.setPitch(_pitch),
    );
    await _tryNativeSetup(
      'set default volume',
      () => _flutterTts.setVolume(_volume),
    );

    if (Platform.isIOS) {
      await _tryNativeSetup(
        'set shared iOS TTS instance',
        () => _flutterTts.setSharedInstance(true),
      );
      await _tryNativeSetup(
        'set iOS audio category',
        () => _flutterTts
            .setIosAudioCategory(IosTextToSpeechAudioCategory.playback, [
              IosTextToSpeechAudioCategoryOptions.allowBluetooth,
              IosTextToSpeechAudioCategoryOptions.allowBluetoothA2DP,
              IosTextToSpeechAudioCategoryOptions.defaultToSpeaker,
            ], IosTextToSpeechAudioMode.defaultMode),
      );
    }

    await _loadNativeVoices();

    if (Platform.isWindows || Platform.isIOS || Platform.isMacOS) {
      await _tryNativeSetup(
        'enable speak completion',
        () => _flutterTts.awaitSpeakCompletion(true),
      );
      debugPrint(
        '[TTS] Using awaitSpeakCompletion mode (platform: ${Platform.operatingSystem}).',
      );
    } else {
      _flutterTts.setCompletionHandler(() {
        Future.microtask(() {
          _isSpeaking = false;
          notifyListeners();
        });
      });
      _flutterTts.setCancelHandler(() {
        Future.microtask(() {
          _isSpeaking = false;
          notifyListeners();
        });
      });
      _flutterTts.setErrorHandler((msg) {
        debugPrint('[TTS] Native error: $msg');
        Future.microtask(() {
          _isSpeaking = false;
          notifyListeners();
        });
      });
    }

    _initialized = true;
    debugPrint('[TTS] Initialized.');
  }

  @override
  Future<void> speak(String text) async {
    if (text.isEmpty) return;

    try {
      _isSpeaking = true;
      notifyListeners();

      debugPrint('[TTS] Speaking (${text.length} chars): "$text"');
      await stop();
      _isSpeaking = true;
      notifyListeners();

      if (_shouldUseElevenLabs(text)) {
        try {
          final audio = await _elevenLabsClient.synthesizeMp3(text);
          await _audioPlayer.playMp3(audio);
          _isSpeaking = false;
          notifyListeners();
          return;
        } catch (e) {
          debugPrint('[TTS] ElevenLabs failed; falling back to native: $e');
        }
      }

      await _speakNative(text);

      if (Platform.isWindows || Platform.isIOS || Platform.isMacOS) {
        _isSpeaking = false;
        notifyListeners();
      }
    } on PlatformException catch (e) {
      debugPrint('[TTS] Platform error: ${e.code} - "${e.message}"');
      _isSpeaking = false;
      notifyListeners();
    } catch (e) {
      debugPrint('[TTS] Error: $e');
      _isSpeaking = false;
      notifyListeners();
    }
  }

  Future<void> _speakNative(String text) {
    return _flutterTts.speak(text);
  }

  bool _shouldUseElevenLabs(String text) {
    if (!_elevenLabsClient.isConfigured) return false;
    switch (_speechEngine) {
      case SpeechEngine.nativeIos:
        return false;
      case SpeechEngine.elevenLabs:
        return true;
      case SpeechEngine.auto:
        return text.trim().length >= 80;
    }
  }

  @override
  Future<void> stop() async {
    try {
      await _audioPlayer.stop();
    } catch (e) {
      debugPrint('[TTS] Error stopping cloud audio: $e');
    }
    try {
      await _flutterTts.stop();
    } catch (e) {
      debugPrint('[TTS] Error stopping: $e');
    }
    _isSpeaking = false;
    notifyListeners();
  }

  @override
  void setRate(double rate) {
    _rate = rate.clamp(0.0, 1.0);
    _runNativeSetter('set rate', _flutterTts.setSpeechRate(_rate));
  }

  @override
  void setPitch(double pitch) {
    _pitch = pitch.clamp(0.5, 2.0);
    _runNativeSetter('set pitch', _flutterTts.setPitch(_pitch));
  }

  @override
  void setVolume(double vol) {
    _volume = vol.clamp(0.0, 1.0);
    _runNativeSetter('set volume', _flutterTts.setVolume(_volume));
  }

  @override
  void setSpeechEngine(SpeechEngine engine) {
    if (_speechEngine == engine) return;
    _speechEngine = engine;
    notifyListeners();
  }

  @override
  Future<void> resetSpeechDefaults() async {
    await stop();
    _rate = 0.5;
    _pitch = 1.0;
    _volume = 1.0;
    _selectedVoice = null;
    _speechEngine = SpeechEngine.nativeIos;
    await _tryNativeSetup(
      'reset language',
      () => _flutterTts.setLanguage('en-US'),
    );
    await _tryNativeSetup('reset rate', () => _flutterTts.setSpeechRate(_rate));
    await _tryNativeSetup('reset pitch', () => _flutterTts.setPitch(_pitch));
    await _tryNativeSetup('reset volume', () => _flutterTts.setVolume(_volume));
    if (Platform.isIOS) {
      await _tryNativeSetup(
        'reset shared iOS TTS instance',
        () => _flutterTts.setSharedInstance(true),
      );
      await _tryNativeSetup(
        'reset iOS audio category',
        () => _flutterTts
            .setIosAudioCategory(IosTextToSpeechAudioCategory.playback, [
              IosTextToSpeechAudioCategoryOptions.allowBluetooth,
              IosTextToSpeechAudioCategoryOptions.allowBluetoothA2DP,
              IosTextToSpeechAudioCategoryOptions.defaultToSpeaker,
            ], IosTextToSpeechAudioMode.defaultMode),
      );
    }
    notifyListeners();
  }

  @override
  Future<List<TtsVoiceOption>> availableVoices() async {
    if (_voices.isEmpty) {
      await _loadNativeVoices();
    }
    return List.unmodifiable(_voices);
  }

  @override
  Future<void> setVoice(TtsVoiceOption voice) async {
    try {
      await _flutterTts.setVoice(voice.nativeVoice);
      _selectedVoice = voice;
      notifyListeners();
    } on PlatformException catch (e) {
      debugPrint('[TTS] Failed to set voice ${voice.label}: ${e.message}');
    } catch (e) {
      debugPrint('[TTS] Failed to set voice ${voice.label}: $e');
    }
  }

  @override
  Future<void> previewVoice([
    String sample = 'This is the selected iCan voice.',
  ]) async {
    await speak(sample);
  }

  Future<void> _loadNativeVoices() async {
    try {
      final rawVoices = await _flutterTts.getVoices;
      if (rawVoices is! List) return;
      final parsed =
          rawVoices
              .map(TtsVoiceOption.fromNative)
              .whereType<TtsVoiceOption>()
              .where((voice) => voice.locale.toLowerCase().startsWith('en'))
              .toList()
            ..sort(_voiceSort);
      _voices = parsed;
      debugPrint('[TTS] Loaded ${_voices.length} English voices.');
    } catch (e) {
      debugPrint('[TTS] Failed to enumerate voices: $e');
      _voices = const [];
    }
  }

  Future<void> _tryNativeSetup(
    String step,
    Future<dynamic> Function() action,
  ) async {
    try {
      await action();
    } on PlatformException catch (e) {
      debugPrint('[TTS] Native setup failed ($step): ${e.code} ${e.message}');
    } catch (e) {
      debugPrint('[TTS] Native setup failed ($step): $e');
    }
  }

  void _runNativeSetter(String step, Future<dynamic> future) {
    unawaited(
      future.catchError((Object e) {
        debugPrint('[TTS] Native setter failed ($step): $e');
      }),
    );
  }

  static int _voiceSort(TtsVoiceOption a, TtsVoiceOption b) {
    final quality = b.isEnhancedAppleVoice.toString().compareTo(
      a.isEnhancedAppleVoice.toString(),
    );
    if (quality != 0) return quality;
    final locale = a.locale.compareTo(b.locale);
    if (locale != 0) return locale;
    return a.name.compareTo(b.name);
  }

  @override
  void dispose() {
    _flutterTts.stop();
    _elevenLabsClient.close();
    super.dispose();
  }
}
