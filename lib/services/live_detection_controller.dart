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
  var _state = LiveDetectionState.idle;
  var _busy = false;
  String _lastMessage = '';
  String? _lastError;

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
    if (!_hasJpegEnvelope(jpeg)) return;
    _busy = true;
    try {
      final result = await _vision.analyzeScene(jpeg);
      if (!active) return;
      final message = _messageFor(result);
      if (message.isEmpty || message == _lastMessage) return;
      _lastMessage = message;
      notifyListeners();
      await _safeSpeak(message);
    } catch (e) {
      debugPrint('[LiveDetectionController] frame failed: $e');
      _lastError = 'Live frame skipped: ${e.runtimeType}.';
      notifyListeners();
    } finally {
      _busy = false;
    }
  }

  String _messageFor(ScenePerceptionResult result) {
    final closeObjects = result.detectedObjects
        .where((o) => (o.relativeDepth ?? 1.0) < 0.50 && o.confidence >= 0.45)
        .take(2)
        .map((o) => o.spatialLabel)
        .toList();
    if (closeObjects.isNotEmpty) {
      return 'Caution: ${closeObjects.join(', ')}.';
    }
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

  static bool _hasJpegEnvelope(Uint8List bytes) {
    return bytes.length >= 4 &&
        bytes[0] == 0xff &&
        bytes[1] == 0xd8 &&
        bytes[bytes.length - 2] == 0xff &&
        bytes[bytes.length - 1] == 0xd9;
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
    unawaited(stop(speak: false));
    super.dispose();
  }
}
