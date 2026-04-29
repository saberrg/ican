import 'dart:async';

import 'package:flutter/foundation.dart';

import '../protocol/ble_protocol.dart';
import '../models/settings_provider.dart';
import 'ble_service.dart';
import 'livex_stream_service.dart';
import 'on_device_vision_service.dart';
import 'tts_service.dart';

enum LiveDetectionState { idle, starting, running, stopping, error }

class LiveDetectionController extends ChangeNotifier {
  LiveDetectionController({
    BleService? bleService,
    OnDeviceVisionService? onDeviceService,
    SpeechOutput? ttsService,
    ValueGetter<LiveDetectionVerbosity>? verbosityProvider,
    this.intervalMs = 900,
  }) : _ble = bleService ?? BleService.instance,
       _vision = onDeviceService ?? OnDeviceVisionService(),
       _tts = ttsService ?? TtsService.instance,
       _verbosityProvider =
           verbosityProvider ?? (() => LiveDetectionVerbosity.full);

  final BleService _ble;
  final OnDeviceVisionService _vision;
  final SpeechOutput _tts;
  final ValueGetter<LiveDetectionVerbosity> _verbosityProvider;
  final int intervalMs;

  StreamSubscription<Uint8List>? _imageSub;
  StreamSubscription<BleConnectionEvent>? _connectionSub;
  Timer? _cooldownTimer;
  var _state = LiveDetectionState.idle;
  var _busy = false;
  var _skipUntil = DateTime.fromMillisecondsSinceEpoch(0);
  var _consecutiveFailures = 0;
  var _preferFullPerception = true;
  var _basicFallbackFramesRemaining = 0;
  String _lastMessage = '';
  String? _lastError;

  static const int _maxConsecutiveFailures = 3;
  static const int _fullPerceptionRetryFrames = 8;
  static const Duration _analysisTimeout = Duration(milliseconds: 4500);
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
    _preferFullPerception = true;
    _basicFallbackFramesRemaining = 0;
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
      await _safeSpeak('LiveX started.');
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
      await LiveXStreamService.instance.stopStream();
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
      final result = await _analyzeFrame(jpeg);
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

  Future<VisionAnalysis> _analyzeFrame(Uint8List jpeg) async {
    if (_preferFullPerception) {
      try {
        return await _vision.analyzeScene(jpeg).timeout(_analysisTimeout);
      } catch (e) {
        debugPrint('[LiveDetectionController] full perception unavailable: $e');
        _preferFullPerception = false;
        _basicFallbackFramesRemaining = _fullPerceptionRetryFrames;
      }
    } else if (_basicFallbackFramesRemaining > 0) {
      _basicFallbackFramesRemaining -= 1;
    } else {
      _preferFullPerception = true;
    }

    return _vision.analyzeLiveFrame(jpeg).timeout(_analysisTimeout);
  }

  String _messageFor(VisionAnalysis result) {
    final verbosity = _verbosityProvider();
    if (result is ScenePerceptionResult && result.detectedObjects.isNotEmpty) {
      final objects =
          result.detectedObjects
              .where((object) => object.confidence >= 0.35)
              .toList()
            ..sort(_compareSpatialObjects);
      if (objects.isNotEmpty) {
        return _spatialMessage(objects, result, verbosity: verbosity);
      }
    }

    if (result.personCount > 0) {
      return _peopleMessage(result, verbosity);
    }
    if (result.ocrTexts.isNotEmpty) {
      return 'Text reads ${result.ocrTexts.take(2).join(', ')}.';
    }
    if (verbosity == LiveDetectionVerbosity.full &&
        result.sceneClassification != 'unknown' &&
        result.sceneConfidence > 0.35) {
      return '${result.sceneClassification.replaceAll('_', ' ')} setting ahead.';
    }
    return '';
  }

  static int _compareSpatialObjects(SpatialObjectData a, SpatialObjectData b) {
    final depthCompare = (a.relativeDepth ?? 1.0).compareTo(
      b.relativeDepth ?? 1.0,
    );
    if (depthCompare != 0) return depthCompare;
    return b.confidence.compareTo(a.confidence);
  }

  String _spatialMessage(
    List<SpatialObjectData> objects,
    ScenePerceptionResult result, {
    required LiveDetectionVerbosity verbosity,
  }) {
    final count = switch (verbosity) {
      LiveDetectionVerbosity.minimal => 1,
      LiveDetectionVerbosity.positional => 2,
      LiveDetectionVerbosity.full => 3,
    };
    final spokenObjects = objects.take(count).map((object) {
      final clock = _clockLabel(object.clockPosition);
      final distance = _distancePhrase(object.relativeDepth);
      return switch (verbosity) {
        LiveDetectionVerbosity.minimal => object.label,
        LiveDetectionVerbosity.positional =>
          '${object.label} at your $clock o\'clock',
        LiveDetectionVerbosity.full =>
          'There is a ${object.label} at your $clock o\'clock$distance',
      };
    }).toList();

    final parts = <String>[spokenObjects.join('. ')];
    if (verbosity == LiveDetectionVerbosity.full) {
      if (result.personCount > 0 &&
          !objects.any((object) => object.label.toLowerCase() == 'person')) {
        parts.add(_peopleMessage(result, verbosity));
      }
      if (result.ocrTexts.isNotEmpty) {
        parts.add('Text reads ${result.ocrTexts.take(2).join(', ')}');
      }
      if (result.sceneClassification != 'unknown' &&
          result.sceneConfidence > 0.35) {
        parts.add('${result.sceneClassification.replaceAll('_', ' ')} setting');
      }
    }
    return '${parts.where((part) => part.trim().isNotEmpty).join('. ')}.';
  }

  String _peopleMessage(
    VisionAnalysis result,
    LiveDetectionVerbosity verbosity,
  ) {
    if (verbosity == LiveDetectionVerbosity.minimal ||
        result.personRects.isEmpty) {
      return result.personCount == 1
          ? '1 person detected.'
          : '${result.personCount} people detected.';
    }
    final first = result.personRects.first;
    final centerX = (first['x'] ?? 0.5) + ((first['w'] ?? 0) / 2);
    final clock = _clockFromCenterX(centerX);
    return result.personCount == 1
        ? 'Person at your $clock o\'clock.'
        : '${result.personCount} people detected; nearest at your $clock o\'clock.';
  }

  static int _clockFromCenterX(double centerX) {
    if (centerX < 0.17) return 10;
    if (centerX < 0.34) return 11;
    if (centerX < 0.66) return 12;
    if (centerX < 0.83) return 1;
    return 2;
  }

  static int _clockLabel(int clock) {
    if (clock >= 1 && clock <= 12) return clock;
    return 12;
  }

  static String _distancePhrase(double? relativeDepth) {
    if (relativeDepth == null) return '';
    if (relativeDepth < 0.30) return ', within reach';
    if (relativeDepth < 0.50) return ', a step or two away';
    if (relativeDepth < 0.70) return ', several steps ahead';
    return ', farther out';
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
