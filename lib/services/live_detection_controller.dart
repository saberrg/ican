import 'dart:async';

import 'package:flutter/foundation.dart';

import '../protocol/ble_protocol.dart';
import 'ble_service.dart';
import 'on_device_vision_service.dart';
import 'tts_service.dart';

enum LiveDetectionState { idle, starting, running, stopping, error }

class LiveDetectionController extends ChangeNotifier {
  LiveDetectionController({
    BleService? bleService,
    OnDeviceVisionService? onDeviceService,
    SpeechOutput? ttsService,
    this.intervalMs = 2000,
  }) : _ble = bleService ?? BleService.instance,
       _vision = onDeviceService ?? OnDeviceVisionService(),
       _tts = ttsService ?? TtsService.instance;

  final BleService _ble;
  final OnDeviceVisionService _vision;
  final SpeechOutput _tts;
  final int intervalMs;

  StreamSubscription<Uint8List>? _imageSub;
  StreamSubscription<BleConnectionEvent>? _connectionSub;
  Timer? _cooldownTimer;
  var _state = LiveDetectionState.idle;
  var _busy = false;
  var _skipUntil = DateTime.fromMillisecondsSinceEpoch(0);
  var _consecutiveFailures = 0;
  String _lastMessage = '';
  String? _lastError;

  static const int _maxConsecutiveFailures = 3;
  static const Duration _analysisTimeout = Duration(seconds: 5);
  static const Duration _failureCooldown = Duration(seconds: 10);

  LiveDetectionState get state => _state;
  bool get active =>
      _state == LiveDetectionState.starting ||
      _state == LiveDetectionState.running;
  String get lastMessage => _lastMessage;
  String? get lastError => _lastError;

  Future<void> start() async {
    if (active || _state == LiveDetectionState.stopping) return;
    if (_ble.state != BleConnectionState.connected ||
        !_ble.eyeReadinessStatus.ready) {
      _setError('iCan Eye is not ready for Live Detection.');
      return;
    }

    _setState(LiveDetectionState.starting);
    _lastError = null;
    _busy = false;
    _consecutiveFailures = 0;
    _skipUntil = DateTime.fromMillisecondsSinceEpoch(0);

    _imageSub = _ble.imageStream.listen(
      _handleFrame,
      onError: (Object e) => _setError('Live image stream failed: $e'),
    );
    _connectionSub = _ble.connectionEventStream.listen((event) {
      if (event.deviceKind == BleDeviceKind.eye && !event.ready) {
        unawaited(stop(speak: true, reason: 'iCan Eye disconnected.'));
      }
    });

    try {
      await _ble.setEyeProfile(EyeProfileIndex.fast);
      await _ble.startLiveCapture(intervalMs: intervalMs);
      _setState(LiveDetectionState.running);
      await _safeSpeak('Live Detection started.');
    } catch (e) {
      _setError('Live Detection could not start: $e');
      await stop(speak: false);
    }
  }

  Future<void> stop({bool speak = true, String? reason}) async {
    if (_state == LiveDetectionState.idle) return;
    _setState(LiveDetectionState.stopping);
    _busy = false;
    _cooldownTimer?.cancel();
    _cooldownTimer = null;
    await _imageSub?.cancel();
    await _connectionSub?.cancel();
    _imageSub = null;
    _connectionSub = null;
    try {
      await _ble.stopLiveCapture();
    } catch (e) {
      debugPrint('[LiveDetectionController] stop failed: $e');
    }
    _setState(LiveDetectionState.idle);
    if (speak) {
      await _safeSpeak(reason ?? 'Live Detection stopped.');
    }
  }

  Future<void> _handleFrame(Uint8List jpeg) async {
    if (!active || _busy) return;
    if (DateTime.now().isBefore(_skipUntil)) return;
    if (!isLikelyValidJpeg(jpeg)) return;
    _busy = true;
    try {
      final result = await _vision
          .analyzeLiveFrame(jpeg)
          .timeout(_analysisTimeout);
      if (!active) return;
      _lastError = null;
      _consecutiveFailures = 0;
      final message = _messageFor(result);
      if (message.isEmpty || message == _lastMessage) return;
      _lastMessage = message;
      notifyListeners();
      await _safeSpeak(message);
    } catch (e) {
      debugPrint('[LiveDetectionController] frame failed: $e');
      _lastError = 'Live frame skipped: ${e.runtimeType}.';
      _consecutiveFailures += 1;
      if (_consecutiveFailures >= _maxConsecutiveFailures) {
        _skipUntil = DateTime.now().add(_failureCooldown);
        _lastError = 'Live vision cooling down after repeated local failures.';
        _cooldownTimer?.cancel();
        _cooldownTimer = Timer(_failureCooldown, () {
          _consecutiveFailures = 0;
          if (active) {
            _lastError = null;
            notifyListeners();
          }
        });
      }
      notifyListeners();
    } finally {
      _busy = false;
    }
  }

  String _messageFor(VisionAnalysis result) {
    if (result.personCount > 0) {
      return result.personCount == 1
          ? '1 person detected.'
          : '${result.personCount} people detected.';
    }
    if (result.ocrTexts.isNotEmpty) {
      return 'Text reads ${result.ocrTexts.take(2).join(', ')}.';
    }
    return '';
  }

  void _setError(String message) {
    _lastError = message;
    _setState(LiveDetectionState.error);
  }

  void _setState(LiveDetectionState state) {
    if (_state == state) return;
    _state = state;
    notifyListeners();
  }

  Future<void> _safeSpeak(String text) async {
    try {
      await _tts.speak(text);
    } catch (e) {
      debugPrint('[LiveDetectionController] TTS failed: $e');
    }
  }

  @override
  void dispose() {
    _cooldownTimer?.cancel();
    unawaited(stop(speak: false));
    super.dispose();
  }
}
