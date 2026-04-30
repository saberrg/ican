import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';

import '../models/home_view_model.dart';
import '../models/settings_provider.dart';
import '../services/ble_service.dart';
import '../services/stt_service.dart';
import '../services/tts_service.dart';
import '../services/voice_control_service.dart';

enum VoiceCommandState { idle, listening, processing }

abstract class VoiceCommandTts {
  Future<void> stop();
  Future<void> speak(String text);
}

abstract class VoiceCommandStt {
  bool get available;
  Stream<String> get resultStream;
  Stream<String> get partialResultStream;
  Stream<SttRecognitionError> get errorStream;
  Future<bool> init();
  Future<void> startListening({Duration listenFor, Duration pauseFor});
  Future<void> stopListening();
}

abstract class VoiceCommandBle {
  Stream<String> get buttonEventStream;
}

abstract class VoiceCommandProcessor {
  Future<VoiceActionResult> handleTranscript(String transcript);
}

class VoiceCommandService extends ChangeNotifier {
  VoiceCommandService({
    required TtsService tts,
    required SttService stt,
    required BleService ble,
    Duration listenWindow = const Duration(seconds: 8),
    Duration pauseWindow = const Duration(seconds: 3),
  }) : this.custom(
         tts: _TtsVoiceCommandAdapter(tts),
         stt: _SttVoiceCommandAdapter(stt),
         ble: _BleVoiceCommandAdapter(ble),
         target: AppVoiceControlTarget(ble: ble),
         listenWindow: listenWindow,
         pauseWindow: pauseWindow,
       );

  @visibleForTesting
  VoiceCommandService.custom({
    required VoiceCommandTts tts,
    required VoiceCommandStt stt,
    required VoiceCommandBle ble,
    AppVoiceControlTarget? target,
    VoiceCommandProcessor? processor,
    Duration listenWindow = const Duration(seconds: 8),
    Duration pauseWindow = const Duration(seconds: 3),
  }) : _tts = tts,
       _stt = stt,
       _ble = ble,
       _voiceTarget = target,
       _listenWindow = listenWindow,
       _pauseWindow = pauseWindow,
       _usesInjectedProcessor = processor != null,
       _voiceControl =
           processor ??
           _VoiceControlProcessor(VoiceControlService(target: target!)) {
    _buttonSub = _ble.buttonEventStream.listen(_onButtonEvent);
    _sttSub = _stt.resultStream.listen(_onSpeechResult);
    _sttPartialSub = _stt.partialResultStream.listen(_onPartialSpeechResult);
    _sttErrorSub = _stt.errorStream.listen(_onSpeechError);
  }

  final VoiceCommandTts _tts;
  final VoiceCommandStt _stt;
  final VoiceCommandBle _ble;
  final AppVoiceControlTarget? _voiceTarget;
  final bool _usesInjectedProcessor;
  VoiceCommandProcessor _voiceControl;
  final Duration _listenWindow;
  final Duration _pauseWindow;

  StreamSubscription<String>? _buttonSub;
  StreamSubscription<String>? _sttSub;
  StreamSubscription<String>? _sttPartialSub;
  StreamSubscription<SttRecognitionError>? _sttErrorSub;
  Timer? _silenceTimer;

  VoiceCommandState _state = VoiceCommandState.idle;
  String _partialText = '';
  String _lastResult = '';
  String _lastError = '';

  VoiceCommandState get state => _state;

  String get partialText => _partialText;

  String get lastResult => _lastResult;

  String get lastError => _lastError;

  void attachHomeViewModel(HomeViewModel vm) {
    _voiceTarget?.homeViewModel = vm;
    _voiceTarget?.sceneService = vm.sceneService;
    if (!_usesInjectedProcessor && _voiceTarget != null) {
      final target = _voiceTarget;
      _voiceControl = _VoiceControlProcessor(
        VoiceControlService(
          target: target,
          resolver: VoiceIntentResolver(
            cloudParser: GeminiVoiceIntentFallbackParser(
              service: vm.sceneService.cloudService,
            ),
          ),
        ),
      );
    }
  }

  void attachRouter(GoRouter router) {}
  void attachSettings(SettingsProvider settings) {
    _voiceTarget?.settings = settings;
  }

  void _onButtonEvent(String event) {
    // DOUBLE press is owned by HomeViewModel (Cloud <-> Local toggle) per the
    // button contract in AGENTS.md. Voice is launched via the in-app Listen
    // button only. If we re-enable a hardware voice trigger later, pick a
    // distinct gesture (e.g. an ultra-long >=3s press in Eye firmware) so it
    // can't collide with the mode toggle.
  }

  Future<void> activateVoiceCommand() async {
    if (_state != VoiceCommandState.idle) return;

    _partialText = '';
    _lastError = '';
    _setState(VoiceCommandState.listening);
    HapticFeedback.mediumImpact();

    await _stopTtsSafely();
    await _speakSafely('Listening.');

    if (!_stt.available) {
      final ok = await _stt.init();
      if (!ok) {
        await _speakSafely(
          'Microphone not available. Check permissions in settings.',
        );
        _lastResult = 'Microphone not available.';
        _setState(VoiceCommandState.idle);
        return;
      }
    }

    try {
      await _stt.startListening(
        listenFor: _listenWindow,
        pauseFor: _pauseWindow,
      );
    } catch (e) {
      _lastError = 'Speech recognition failed to start: $e';
      _lastResult = 'Speech recognition failed to start.';
      await _speakSafely(_lastResult);
      _setState(VoiceCommandState.idle);
      return;
    }

    _silenceTimer?.cancel();
    _silenceTimer = Timer(_listenWindow + _pauseWindow, () {
      if (_state == VoiceCommandState.listening) {
        _stt.stopListening();
        _onNoSpeech();
      }
    });
  }

  void _onPartialSpeechResult(String text) {
    if (_state != VoiceCommandState.listening) return;
    _partialText = text;
    notifyListeners();
  }

  void _onSpeechResult(String text) {
    _silenceTimer?.cancel();
    if (_state != VoiceCommandState.listening) return;
    _partialText = text;
    notifyListeners();
    _processCommand(text);
  }

  Future<void> _onSpeechError(SttRecognitionError error) async {
    if (_state != VoiceCommandState.listening) return;
    _silenceTimer?.cancel();
    _lastError = error.message;
    await _stt.stopListening();
    if (error.isNoSpeech) {
      await _onNoSpeech();
      return;
    }
    _lastResult = error.permanent
        ? 'Microphone error. Check speech recognition permissions.'
        : 'I had trouble hearing that. Tap Listen to try again.';
    await _speakSafely(_lastResult);
    _setState(VoiceCommandState.idle);
  }

  Future<void> _onNoSpeech() async {
    await _speakSafely(
      "I didn't hear a command. Double-tap the screen or tap Listen to try again.",
    );
    _lastResult = "I didn't hear anything.";
    _setState(VoiceCommandState.idle);
  }

  Future<void> _processCommand(String text) async {
    _setState(VoiceCommandState.processing);
    HapticFeedback.lightImpact();

    final normalized = text.toLowerCase().trim();
    debugPrint('[VoiceCmd] Recognized: "$normalized"');

    try {
      final result = await _voiceControl.handleTranscript(normalized);
      _lastResult = result.spokenConfirmation;
      await _speakSafely(result.spokenConfirmation);
    } catch (e) {
      debugPrint('[VoiceCmd] Action error: $e');
      _lastResult = 'Sorry, something went wrong.';
      await _speakSafely(_lastResult);
    }

    _setState(VoiceCommandState.idle);
  }

  Future<void> _stopTtsSafely() async {
    try {
      await _tts.stop();
    } catch (e) {
      debugPrint('[VoiceCmd] TTS stop failed: $e');
    }
  }

  Future<void> _speakSafely(String text) async {
    try {
      await _tts.speak(text);
    } catch (e) {
      _lastError = 'TTS failed: $e';
      debugPrint('[VoiceCmd] TTS speak failed: $e');
    }
  }

  void _setState(VoiceCommandState newState) {
    _state = newState;
    notifyListeners();
  }

  @override
  void dispose() {
    _buttonSub?.cancel();
    _sttSub?.cancel();
    _sttPartialSub?.cancel();
    _sttErrorSub?.cancel();
    _silenceTimer?.cancel();
    super.dispose();
  }
}

class _TtsVoiceCommandAdapter implements VoiceCommandTts {
  _TtsVoiceCommandAdapter(this._tts);

  final TtsService _tts;

  @override
  Future<void> speak(String text) => _tts.speak(text);

  @override
  Future<void> stop() => _tts.stop();
}

class _SttVoiceCommandAdapter implements VoiceCommandStt {
  _SttVoiceCommandAdapter(this._stt);

  final SttService _stt;

  @override
  bool get available => _stt.available;

  @override
  Stream<String> get resultStream => _stt.resultStream;

  @override
  Stream<String> get partialResultStream => _stt.partialResultStream;

  @override
  Stream<SttRecognitionError> get errorStream => _stt.errorStream;

  @override
  Future<bool> init() => _stt.init();

  @override
  Future<void> startListening({
    Duration listenFor = const Duration(seconds: 8),
    Duration pauseFor = const Duration(seconds: 3),
  }) {
    return _stt.startListening(listenFor: listenFor, pauseFor: pauseFor);
  }

  @override
  Future<void> stopListening() => _stt.stopListening();
}

class _BleVoiceCommandAdapter implements VoiceCommandBle {
  _BleVoiceCommandAdapter(this._ble);

  final BleService _ble;

  @override
  Stream<String> get buttonEventStream => _ble.buttonEventStream;
}

class _VoiceControlProcessor implements VoiceCommandProcessor {
  _VoiceControlProcessor(this._voiceControl);

  final VoiceControlService _voiceControl;

  @override
  Future<VoiceActionResult> handleTranscript(String transcript) {
    return _voiceControl.handleTranscript(transcript);
  }
}
