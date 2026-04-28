import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;

import '../protocol/describe_attempt_trace.dart';
import '../protocol/eye_capture_diagnostics.dart';
import '../protocol/ble_protocol.dart';
import '../services/app_log_service.dart';
import '../services/ble_service.dart';
import '../services/on_device_vision_service.dart';
import '../services/scene_description_service.dart';
import '../services/scene_prompt_builder.dart';
import '../services/tts_service.dart';
import '../services/vertex_ai_service.dart';
import '../services/vision_health_service.dart';
import 'settings_provider.dart';

export 'font_scale.dart';

class DescriptionEntry {
  final String text;
  final DateTime timestamp;
  bool isImportant;

  DescriptionEntry({
    required this.text,
    required this.timestamp,
    this.isImportant = false,
  });
}

enum _CapturedImageFailure { corrupt, incomplete }

enum _LiveVisionMode { full, basic }

class HomeViewModel extends ChangeNotifier {
  final SceneDescriptionService sceneService;
  final SpeechOutput ttsService;
  final SettingsProvider settingsProvider;
  final DescribeAttemptTraceStore _traceStore;
  final Duration _processingTimeoutDuration;

  HomeViewModel({
    required this.sceneService,
    required this.ttsService,
    required this.settingsProvider,
    DescribeAttemptTraceStore? traceStore,
    Duration processingTimeout = const Duration(seconds: 60),
  }) : _traceStore = traceStore ?? DescribeAttemptTraceStore(),
       _processingTimeoutDuration = processingTimeout {
    _init();
  }

  final List<DescriptionEntry> _history = [];
  String _lastDescription = '';
  bool _isPaused = false;
  bool _isProcessing = false;
  bool _waitingForCaptureImage = false;
  bool _disposed = false;
  String? _lastImageFingerprint;
  DateTime? _lastImageTime;
  int _batteryPercent = -1;
  Timer? _processingTimeout;
  final ScenePromptBuilder _promptBuilder = const ScenePromptBuilder();

  StreamSubscription<ObstacleAlert>? _obstacleSub;
  StreamSubscription<Uint8List>? _imageSub;
  StreamSubscription<EyeCaptureDiagnostic>? _eyeDiagnosticSub;
  StreamSubscription<BleConnectionEvent>? _connectionEventSub;
  StreamSubscription<void>? _captureSub;
  StreamSubscription<TelemetryPacket>? _telemetrySub;
  VoidCallback? _bleListener;
  VoidCallback? _sceneServiceListener;
  Completer<String>? _describeNowCompleter;
  String _lastDiagnostic = '';
  DescribeAttemptTrace? _currentTrace;
  String? _lastBleAnnouncementKey;

  // ── Live vision mode state ──
  bool _liveVisionActive = false;
  bool get liveVisionActive => _liveVisionActive;
  final OnDeviceVisionService _onDeviceVision = OnDeviceVisionService();
  OfflineVisionStatus? _offlineVisionStatus;
  VisionRuntimeStatus? _visionRuntimeStatus;
  StreamSubscription<Uint8List>? _liveImageSub;
  final Map<String, DateTime> _liveLastAnnounced = {};
  bool _liveProcessing = false;
  _LiveVisionMode _liveMode = _LiveVisionMode.basic;

  // ── Public getters ──
  BleConnectionState get caneConnection => BleService.instance.caneState;
  BleConnectionState get eyeConnection => BleService.instance.state;
  int get batteryPercent => _batteryPercent;

  String get lastDescription => _lastDescription;
  String get lastDiagnostic => _lastDiagnostic;
  String get latestFailureSummary =>
      _lastDiagnostic.isEmpty ? 'No failure recorded.' : _lastDiagnostic;
  String get visionStatusSummary {
    final backend = sceneService.lastBackend?.name ?? 'none yet';
    final cloudFailure = sceneService.lastCloudFailure == null
        ? 'no cloud failure'
        : _cloudFailureDiagnostic(sceneService.lastCloudFailure!);
    return 'Vision mode ${sceneService.mode.label}. Last backend $backend. $cloudFailure.';
  }

  VisionMode get visionMode => sceneService.mode;
  bool get isPaused => _isPaused;
  bool get isProcessing => _isProcessing;
  List<DescriptionEntry> get history => List.unmodifiable(_history);
  bool get hasAnyDevice => isEyeConnected || isCaneConnected;
  OfflineVisionStatus? get offlineVisionStatus => _offlineVisionStatus;
  VisionRuntimeStatus? get visionRuntimeStatus => _visionRuntimeStatus;

  bool get isEyeConnected =>
      BleService.instance.state == BleConnectionState.connected;
  bool get isCaneConnected =>
      BleService.instance.caneState == BleConnectionState.connected;
  bool get canDescribe =>
      isEyeConnected && !_isProcessing && !_isPaused && !_liveVisionActive;

  void _init() {
    _bleListener = () {
      if (_liveVisionActive &&
          BleService.instance.state != BleConnectionState.connected) {
        _stopLiveVisionInternal();
      }
      // Reset stuck processing if Eye disconnects mid-capture
      if (!isEyeConnected && _isProcessing) {
        final wasWaitingForCapture = _waitingForCaptureImage;
        _isProcessing = false;
        _waitingForCaptureImage = false;
        _processingTimeout?.cancel();
        if (wasWaitingForCapture) {
          _recordDescribeLog(
            'Eye disconnected while awaiting capture start. '
            'readiness=${BleService.instance.eyeReadinessStatus.phase.name}',
          );
          unawaited(
            _speakEyeCaptureDiagnostic(
              const EyeCaptureDiagnostic(
                code: EyeCaptureDiagnosticCode.noCaptureStartOrSize,
                captureStarted: false,
                sizeArrived: false,
                expectedBytes: 0,
                receivedBytes: 0,
                uniqueChunks: 0,
                duplicateChunks: 0,
                endArrived: false,
                jpegMagicValid: false,
                jpegEndValid: false,
                timeoutStage: EyeTransferTimeoutStage.awaitingCaptureStart,
              ),
            ),
          );
        }
      }
      notifyListeners();
    };
    BleService.instance.addListener(_bleListener!);

    _sceneServiceListener = notifyListeners;
    sceneService.addListener(_sceneServiceListener!);

    _obstacleSub = BleService.instance.obstacleStream.listen((alert) {
      notifyListeners();
    });

    _captureSub = BleService.instance.captureStartedStream.listen((_) {
      if (!_liveVisionActive) {
        _isProcessing = true;
        _waitingForCaptureImage = true;
        _recordDescribeLog('Eye capture start observed.');
        unawaited(_updateDescribeTrace(DescribePipelineStage.captureStarted));
        notifyListeners();
        _startProcessingTimeout(cameraTransfer: true);
      }
    });

    _telemetrySub = BleService.instance.telemetryStream.listen((pkt) {
      _batteryPercent = pkt.batteryPercent;
      notifyListeners();
    });

    _imageSub = BleService.instance.imageStream.listen((
      Uint8List imageBytes,
    ) async {
      if (_isPaused || _liveVisionActive) return;
      final now = DateTime.now();
      final fingerprint = _computeFingerprint(imageBytes);
      if (_lastImageFingerprint == fingerprint &&
          _lastImageTime != null &&
          now.difference(_lastImageTime!) < const Duration(seconds: 2)) {
        return;
      }
      _lastImageFingerprint = fingerprint;
      _lastImageTime = now;
      _waitingForCaptureImage = false;
      await _processImage(imageBytes);
    });

    _eyeDiagnosticSub = BleService.instance.eyeCaptureDiagnosticStream.listen((
      diagnostic,
    ) {
      if (_liveVisionActive) return;
      _handleEyeCaptureDiagnostic(diagnostic);
    });

    _connectionEventSub = BleService.instance.connectionEventStream.listen((
      event,
    ) {
      if (event.deviceKind != BleDeviceKind.eye) return;
      if (event.ready) {
        _speakBleTransition('eye-ready', 'iCan Eye connected.');
      } else if (event.phase == BleReadinessPhase.idle) {
        _speakBleTransition('eye-idle', 'iCan Eye disconnected.');
      }
    });

    _announceStartup();
    unawaited(_surfaceUnfinishedDescribeTrace());
    unawaited(refreshOfflineVisionStatus());
  }

  Future<void> _surfaceUnfinishedDescribeTrace() async {
    final trace = await _traceStore.loadLastUnfinished();
    if (_disposed || trace == null) return;
    final message =
        'Previous Describe did not finish. Last stage: ${trace.stage.label}. '
        'Mode: ${trace.visionMode}. Detail: ${trace.detailLevel}.';
    _setLastDiagnostic(
      trace.lastError == null ? message : '$message ${trace.lastError}',
    );
  }

  Future<void> refreshOfflineVisionStatus() async {
    final status = await _onDeviceVision.getOfflineVisionStatus();
    final runtimeStatus = await VisionHealthService(
      onDeviceService: _onDeviceVision,
      cloudService: sceneService.cloudService,
    ).check(eyeConnected: isEyeConnected, includeNetworkCheck: false);
    if (_disposed) return;
    _offlineVisionStatus = status;
    _visionRuntimeStatus = runtimeStatus;
    notifyListeners();
  }

  void _startProcessingTimeout({bool cameraTransfer = false}) {
    _processingTimeout?.cancel();
    _processingTimeout = Timer(_processingTimeoutDuration, () {
      if (_isProcessing) {
        final wasWaitingForCapture = cameraTransfer && _waitingForCaptureImage;
        _isProcessing = false;
        _waitingForCaptureImage = false;
        _processingTimeout?.cancel();
        notifyListeners();
        if (wasWaitingForCapture) {
          unawaited(
            _speakEyeCaptureDiagnostic(
              const EyeCaptureDiagnostic(
                code: EyeCaptureDiagnosticCode.noCaptureStartOrSize,
                captureStarted: false,
                sizeArrived: false,
                expectedBytes: 0,
                receivedBytes: 0,
                uniqueChunks: 0,
                duplicateChunks: 0,
                endArrived: false,
                jpegMagicValid: false,
                jpegEndValid: false,
                timeoutStage: EyeTransferTimeoutStage.awaitingCaptureStart,
              ),
            ),
          );
          _recordDescribeLog('Capture timeout from Home timer before image.');
        }
      }
    });
  }

  Future<void> _announceStartup() async {
    final parts = <String>['Home screen.'];
    if (isEyeConnected) parts.add('Camera connected.');
    if (isCaneConnected) parts.add('Cane connected.');
    if (!isEyeConnected && !isCaneConnected) {
      parts.add('No devices connected yet.');
    }
    await ttsService.speak(parts.join(' '));
  }

  void _speakBleTransition(String key, String message) {
    if (_lastBleAnnouncementKey == key) return;
    _lastBleAnnouncementKey = key;
    unawaited(
      ttsService.speak(message).catchError((Object e) {
        debugPrint('[HomeViewModel] BLE announcement failed: $e');
      }),
    );
  }

  // ── Live Vision Mode ──

  Future<void> startLiveVision() async {
    if (_liveVisionActive || !isEyeConnected) return;
    final status = await _onDeviceVision.getOfflineVisionStatus();
    _offlineVisionStatus = status;
    _liveMode = status.objectDetectionAvailable
        ? _LiveVisionMode.full
        : _LiveVisionMode.basic;
    _liveVisionActive = true;
    _liveLastAnnounced.clear();
    notifyListeners();

    await BleService.instance.setEyeProfile(0);
    await BleService.instance.startLiveCapture(intervalMs: 1500);

    _liveImageSub = BleService.instance.imageStream.listen((
      Uint8List imageBytes,
    ) async {
      if (!_liveVisionActive || _liveProcessing) return;
      _liveProcessing = true;
      try {
        await _processLiveFrame(imageBytes);
      } catch (e) {
        debugPrint('[HomeViewModel] Live frame error: $e');
      }
      _liveProcessing = false;
    });

    try {
      await ttsService.speak(
        _liveMode == _LiveVisionMode.full
            ? 'Full live detection started.'
            : 'Basic live mode started. Object detection is degraded.',
      );
    } catch (_) {}
  }

  Future<void> stopLiveVision() async {
    if (!_liveVisionActive) return;
    _stopLiveVisionInternal();
    try {
      await ttsService.speak('Live vision stopped.');
    } catch (_) {}
  }

  void _stopLiveVisionInternal() {
    _liveVisionActive = false;
    _liveProcessing = false;
    _liveImageSub?.cancel();
    _liveImageSub = null;
    _liveLastAnnounced.clear();
    BleService.instance.stopLiveCapture();
    BleService.instance.setEyeProfile(1);
    notifyListeners();
  }

  Future<void> _processLiveFrame(Uint8List imageBytes) async {
    if (imageBytes.length < 2 ||
        imageBytes[0] != 0xFF ||
        imageBytes[1] != 0xD8) {
      return;
    }

    final result = await _onDeviceVision.analyzeScene(imageBytes);
    if (!_liveVisionActive) return;

    if (_liveMode == _LiveVisionMode.basic) {
      await _processBasicLiveFrame(result);
      return;
    }

    final filtered =
        result.detectedObjects.where((o) => o.confidence >= 0.5).toList()
          ..sort((a, b) => b.confidence.compareTo(a.confidence));

    if (filtered.isEmpty) return;

    final now = DateTime.now();
    final toAnnounce = <String>[];
    final verbosity = settingsProvider.liveDetectionVerbosity;
    final maxObjects = verbosity == LiveDetectionVerbosity.full ? 3 : 1;

    for (final det in filtered.take(maxObjects)) {
      final lastTime = _liveLastAnnounced[det.label];
      if (lastTime != null &&
          now.difference(lastTime) < const Duration(seconds: 3)) {
        continue;
      }
      _liveLastAnnounced[det.label] = now;
      final position = _positionFromCenterX(det.centerX);
      switch (verbosity) {
        case LiveDetectionVerbosity.minimal:
          toAnnounce.add(det.label);
        case LiveDetectionVerbosity.positional:
        case LiveDetectionVerbosity.full:
          toAnnounce.add('${det.label} $position');
      }
    }

    if (toAnnounce.isNotEmpty && _liveVisionActive) {
      try {
        await ttsService.speak(toAnnounce.join(', '));
      } catch (_) {}
    }
  }

  Future<void> _processBasicLiveFrame(ScenePerceptionResult result) async {
    final now = DateTime.now();
    final cues = <String>[];

    if (result.personCount > 0) {
      final people = result.personCount == 1
          ? '1 person detected'
          : '${result.personCount} people detected';
      cues.add(people);
    }

    if (result.ocrTexts.isNotEmpty) {
      cues.add('Text reads ${result.ocrTexts.take(2).join(', ')}');
    }

    if (result.sceneClassification != 'unknown' &&
        result.sceneConfidence > 0.25) {
      cues.add('${result.sceneClassification.replaceAll('_', ' ')} setting');
    }

    if (cues.isEmpty) return;
    final key = cues.join('|');
    final lastTime = _liveLastAnnounced[key];
    if (lastTime != null &&
        now.difference(lastTime) < const Duration(seconds: 4)) {
      return;
    }
    _liveLastAnnounced[key] = now;
    try {
      await ttsService.speak('Basic live mode: ${cues.join(', ')}.');
    } catch (_) {}
  }

  static String _positionFromCenterX(double cx) {
    if (cx < 0.33) return 'on your left';
    if (cx < 0.66) return 'ahead';
    return 'on your right';
  }

  // ── Public methods ──
  void pauseDescriptions() {
    _isPaused = true;
    ttsService.stop();
    notifyListeners();
  }

  void resumeDescriptions() {
    _isPaused = false;
    notifyListeners();
  }

  void repeatLast() {
    if (_lastDescription.isNotEmpty) {
      ttsService.speak(_lastDescription);
    }
  }

  Future<String> describeNow() {
    final readiness = BleService.instance.eyeReadinessStatus;
    if (!canDescribe) {
      const message =
          'Eye E01: no capture start or SIZE from Eye. Stage: camera not ready; received 0/unknown bytes across 0 chunks.';
      _setLastDiagnostic(message);
      _recordDescribeLog(
        'Describe rejected. eyeConnected=$isEyeConnected '
        'processing=$_isProcessing paused=$_isPaused live=$_liveVisionActive '
        'readiness=${readiness.phase.name} ready=${readiness.ready} '
        'requiredChars=${readiness.requiredCharacteristicsReady}',
      );
      return Future.value(message);
    }
    if (_describeNowCompleter != null && !_describeNowCompleter!.isCompleted) {
      return _describeNowCompleter!.future;
    }
    _describeNowCompleter = Completer<String>();
    _isProcessing = true;
    _waitingForCaptureImage = true;
    notifyListeners();
    unawaited(
      _beginDescribeTrace(
        DescribePipelineStage.captureRequested,
        imageBytes: 0,
      ),
    );
    _recordDescribeLog(
      'Describe requested. readiness=${readiness.phase.name} '
      'ready=${readiness.ready} '
      'requiredChars=${readiness.requiredCharacteristicsReady} '
      'visionMode=${sceneService.mode.name} '
      'detail=${settingsProvider.detailLevel.name}',
    );
    _startProcessingTimeout(cameraTransfer: true);
    unawaited(
      BleService.instance.triggerEyeCapture().catchError((Object error) {
        _recordDescribeLog(
          'Capture command future failed: ${error.runtimeType}.',
        );
      }),
    );
    return _describeNowCompleter!.future;
  }

  void removeDescription(int index) {
    if (index >= 0 && index < _history.length) {
      _history.removeAt(index);
      notifyListeners();
    }
  }

  void toggleImportant(int index) {
    if (index >= 0 && index < _history.length) {
      _history[index].isImportant = !_history[index].isImportant;
      notifyListeners();
    }
  }

  void startScanForEye() => BleService.instance.startScan();
  void startScanForCane() => BleService.instance.startScanForCane();

  // ── Image processing ──
  @visibleForTesting
  Future<void> processImageForTesting(Uint8List imageBytes) {
    return _processImage(imageBytes);
  }

  @visibleForTesting
  void startCaptureTimeoutForTesting() {
    _isProcessing = true;
    _waitingForCaptureImage = true;
    _startProcessingTimeout(cameraTransfer: true);
  }

  Future<void> _processImage(Uint8List imageBytes) async {
    _waitingForCaptureImage = false;
    await _updateDescribeTrace(
      DescribePipelineStage.jpegValidation,
      imageBytes: imageBytes.length,
    );
    final imageFailure = _validateCapturedJpeg(imageBytes);
    if (imageFailure != null) {
      _isProcessing = false;
      _processingTimeout?.cancel();
      notifyListeners();
      await _speakImageFailure(imageFailure, imageBytes.length);
      return;
    }

    _isProcessing = true;
    notifyListeners();
    _startProcessingTimeout();

    try {
      await _updateDescribeTrace(DescribePipelineStage.imageEnhancement);
      var enhancedBytes = imageBytes;
      try {
        enhancedBytes = await compute(_enhanceImageForApi, imageBytes);
      } catch (e) {
        debugPrint('[HomeViewModel] Image enhancement failed: $e');
        await _updateDescribeTrace(
          DescribePipelineStage.imageEnhancement,
          lastError: 'Image enhancement failed; using original JPEG.',
        );
      }
      final fullTextBuffer = StringBuffer();
      final prompt = _promptBuilder.build(
        detailLevel: settingsProvider.detailLevel,
        promptProfile: settingsProvider.promptProfile,
      );

      await _updateDescribeTrace(DescribePipelineStage.cloudRequest);
      await for (final chunk in sceneService.describeScene(
        enhancedBytes,
        systemPrompt: prompt.systemPrompt,
        userPrompt: prompt.userPrompt,
        maxOutputTokens: prompt.maxOutputTokens,
        onStatusUpdate: (_, __) {},
      )) {
        if (_isPaused) continue;
        fullTextBuffer.write(chunk);
      }

      final fullText = fullTextBuffer.toString().trim();
      if (fullText.isNotEmpty) {
        if (!_isPaused) {
          await _updateDescribeTrace(DescribePipelineStage.speech);
          try {
            await ttsService.speak(fullText);
          } catch (e) {
            _setLastDiagnostic('Speech S01: playback failed. $e');
            await _updateDescribeTrace(
              DescribePipelineStage.speech,
              lastError: 'Speech playback failed: $e',
            );
          }
        }
        _lastDescription = fullText;
        if (!_lastDiagnostic.startsWith('Speech S01:')) {
          _clearLastDiagnostic();
        }
        _history.insert(
          0,
          DescriptionEntry(text: fullText, timestamp: DateTime.now()),
        );
        await _updateDescribeTrace(DescribePipelineStage.completed);
        _completeDescribeNow('Scene description complete.');
      }
    } catch (e) {
      debugPrint('[HomeViewModel] Error processing image: $e');
      await _updateDescribeTrace(
        DescribePipelineStage.failed,
        lastError: _processingErrorMessage(e),
      );
      await _speakProcessingError(e);
    } finally {
      _isProcessing = false;
      _waitingForCaptureImage = false;
      _processingTimeout?.cancel();
      if (_describeNowCompleter != null &&
          !_describeNowCompleter!.isCompleted) {
        _completeDescribeNow('Scene description produced no output.');
      }
      notifyListeners();
    }
  }

  _CapturedImageFailure? _validateCapturedJpeg(Uint8List imageBytes) {
    if (imageBytes.length < 2 ||
        imageBytes[0] != 0xFF ||
        imageBytes[1] != 0xD8) {
      return _CapturedImageFailure.corrupt;
    }
    if (imageBytes.length < 4 ||
        imageBytes[imageBytes.length - 2] != 0xFF ||
        imageBytes[imageBytes.length - 1] != 0xD9) {
      return _CapturedImageFailure.incomplete;
    }
    return null;
  }

  Future<void> _speakImageFailure(
    _CapturedImageFailure failure,
    int receivedBytes,
  ) async {
    final diagnostic = EyeCaptureDiagnostic(
      code: EyeCaptureDiagnosticCode.corruptOrIncompleteJpeg,
      captureStarted: true,
      sizeArrived: true,
      expectedBytes: receivedBytes,
      receivedBytes: receivedBytes,
      uniqueChunks: 0,
      duplicateChunks: 0,
      endArrived: true,
      jpegMagicValid: failure != _CapturedImageFailure.corrupt,
      jpegEndValid: failure != _CapturedImageFailure.incomplete,
    );
    await _updateDescribeTrace(
      DescribePipelineStage.failed,
      lastError: diagnostic.spokenMessage,
    );
    await _speakEyeCaptureDiagnostic(diagnostic);
  }

  void _handleEyeCaptureDiagnostic(EyeCaptureDiagnostic diagnostic) {
    unawaited(_handleEyeCaptureDiagnosticAsync(diagnostic));
  }

  Future<void> _handleEyeCaptureDiagnosticAsync(
    EyeCaptureDiagnostic diagnostic,
  ) async {
    if (!_isProcessing && !_waitingForCaptureImage) return;
    _isProcessing = false;
    _waitingForCaptureImage = false;
    _processingTimeout?.cancel();
    notifyListeners();
    await _speakEyeCaptureDiagnostic(diagnostic);
  }

  Future<void> _speakEyeCaptureDiagnostic(
    EyeCaptureDiagnostic diagnostic,
  ) async {
    final message = diagnostic.spokenMessage;
    _recordDescribeLog('Eye diagnostic ${diagnostic.stableCode}: $message');
    _setLastDiagnostic(message);
    await _updateDescribeTrace(
      DescribePipelineStage.failed,
      lastError: message,
    );
    _completeDescribeNow(message);
    try {
      await ttsService.speak(message);
    } catch (_) {}
  }

  @visibleForTesting
  Future<void> handleEyeCaptureDiagnosticForTesting(
    EyeCaptureDiagnostic diagnostic,
  ) async {
    await _handleEyeCaptureDiagnosticAsync(diagnostic);
  }

  Future<void> _speakProcessingError(Object error) async {
    final message = _processingErrorMessage(error);
    _setLastDiagnostic(message);
    _completeDescribeNow(message);
    try {
      await ttsService.speak(message);
    } catch (_) {}
  }

  String _processingErrorMessage(Object error) {
    if (error is CloudVisionException) {
      return _cloudFailureDiagnostic(error);
    }
    if (error is SceneDescriptionException) {
      if (error.stage == SceneDescriptionFailureStage.cloudVision) {
        final cause = error.cause;
        if (cause is CloudVisionException) {
          return _cloudFailureDiagnostic(cause);
        }
        return 'Cloud C03: cloud timeout/network failure.';
      }
      final local = _localFailureDiagnostic(error.cause);
      if (error.cloudFailure != null) {
        return '${_cloudFailureDiagnostic(error.cloudFailure!)} $local';
      }
      return local;
    }
    return _localFailureDiagnostic(error);
  }

  static String _localFailureDiagnostic(Object failure) {
    if (failure is LocalVisionException) return failure.userMessage;
    return 'Local L03: Apple Vision or Core ML failed.';
  }

  static String _cloudFailureDiagnostic(Object failure) {
    if (failure is SceneDescriptionException) {
      return failure.userMessage;
    }
    if (failure is! CloudVisionException) {
      return 'Cloud C03: cloud timeout/network failure.';
    }
    final error = failure;
    switch (error.kind) {
      case CloudVisionFailureKind.missingApiKey:
        return 'Cloud C01: missing API key/config.';
      case CloudVisionFailureKind.httpStatus:
        return 'Cloud C02: Gemini HTTP status failure ${error.statusCode}.';
      case CloudVisionFailureKind.timeout:
      case CloudVisionFailureKind.network:
        return 'Cloud C03: cloud timeout/network failure.';
      case CloudVisionFailureKind.malformedResponse:
        return 'Cloud C03: cloud timeout/network failure.';
    }
  }

  void _completeDescribeNow(String message) {
    final completer = _describeNowCompleter;
    if (completer != null && !completer.isCompleted) {
      completer.complete(message);
    }
    _describeNowCompleter = null;
  }

  void _setLastDiagnostic(String message) {
    if (_lastDiagnostic == message) return;
    _lastDiagnostic = message;
    if (!_disposed) notifyListeners();
  }

  void _clearLastDiagnostic() {
    if (_lastDiagnostic.isEmpty) return;
    _lastDiagnostic = '';
    if (!_disposed) notifyListeners();
  }

  Future<void> _beginDescribeTrace(
    DescribePipelineStage stage, {
    required int imageBytes,
  }) async {
    final now = DateTime.now();
    final trace = DescribeAttemptTrace(
      attemptId: now.microsecondsSinceEpoch.toString(),
      stage: stage,
      startedAt: now,
      updatedAt: now,
      imageBytes: imageBytes,
      visionMode: sceneService.mode.name,
      detailLevel: settingsProvider.detailLevel.name,
    );
    _currentTrace = trace;
    _recordDescribeLog('Describe attempt ${trace.attemptId} ${stage.name}.');
    await _traceStore.save(trace);
  }

  Future<void> _updateDescribeTrace(
    DescribePipelineStage stage, {
    int? imageBytes,
    String? lastError,
  }) async {
    var trace = _currentTrace;
    if (trace == null) {
      await _beginDescribeTrace(stage, imageBytes: imageBytes ?? 0);
      trace = _currentTrace;
      if (trace == null) return;
    }
    final next = trace.copyWith(
      stage: stage,
      imageBytes: imageBytes,
      visionMode: sceneService.mode.name,
      detailLevel: settingsProvider.detailLevel.name,
      lastError: lastError,
    );
    _currentTrace = next;
    final errorSuffix = lastError == null
        ? ''
        : ' error=${_shortLog(lastError)}';
    _recordDescribeLog(
      'Describe attempt ${next.attemptId} ${stage.name}$errorSuffix',
    );
    await _traceStore.save(next);
  }

  String _shortLog(String message) {
    if (message.length <= 160) return message;
    return '${message.substring(0, 160)}...';
  }

  void _recordDescribeLog(String message) {
    unawaited(AppLogService.instance.record(message, source: 'describe'));
  }

  String _computeFingerprint(Uint8List data) {
    if (data.isEmpty) return 'empty';
    final headLen = data.length < 16 ? data.length : 16;
    final tailLen = data.length < 16 ? data.length : 16;
    final head = data.sublist(0, headLen);
    final tail = data.sublist(data.length - tailLen);
    return '${data.length}:${head.join(',')}:${tail.join(',')}';
  }

  @override
  void dispose() {
    if (_liveVisionActive) {
      _stopLiveVisionInternal();
    }
    _disposed = true;
    _obstacleSub?.cancel();
    _imageSub?.cancel();
    _eyeDiagnosticSub?.cancel();
    _connectionEventSub?.cancel();
    _liveImageSub?.cancel();
    _captureSub?.cancel();
    _telemetrySub?.cancel();
    _processingTimeout?.cancel();
    if (_bleListener != null) {
      BleService.instance.removeListener(_bleListener!);
    }
    if (_sceneServiceListener != null) {
      sceneService.removeListener(_sceneServiceListener!);
    }
    _completeDescribeNow('Home closed before scene description completed.');
    super.dispose();
  }
}

// ── Image enhancement (top-level for compute() isolate) ──

Uint8List _enhanceImageForApi(Uint8List rawBytes) {
  final decoded = img.decodeJpg(rawBytes);
  if (decoded == null) return rawBytes;

  var image = decoded;

  final isTruncated =
      rawBytes.length < 2 ||
      rawBytes[rawBytes.length - 2] != 0xFF ||
      rawBytes[rawBytes.length - 1] != 0xD9;
  if (isTruncated) {
    image = _cropBottomBlackBar(image);
  }

  final meanLuma = _computeMeanLuminance(image);
  if (meanLuma < 80) {
    image = img.normalize(image, min: 10, max: 245);
  } else if (meanLuma <= 180) {
    image = img.adjustColor(image, contrast: 1.1);
  }

  image = img.convolution(
    image,
    filter: [0, -1, 0, -1, 5, -1, 0, -1, 0],
    amount: 0.3,
  );

  return Uint8List.fromList(img.encodeJpg(image, quality: 85));
}

double _computeMeanLuminance(img.Image src) {
  double sum = 0;
  int count = 0;
  for (int y = 0; y < src.height; y += 8) {
    for (int x = 0; x < src.width; x += 8) {
      final p = src.getPixel(x, y);
      sum +=
          0.299 * p.r.toDouble() +
          0.587 * p.g.toDouble() +
          0.114 * p.b.toDouble();
      count++;
    }
  }
  return count > 0 ? sum / count : 128;
}

img.Image _cropBottomBlackBar(img.Image src) {
  const brightnessThreshold = 20;
  for (int y = src.height - 1; y >= src.height * 2 ~/ 3; y--) {
    for (int x = 0; x < src.width; x += 16) {
      final p = src.getPixel(x, y);
      if (p.r > brightnessThreshold ||
          p.g > brightnessThreshold ||
          p.b > brightnessThreshold) {
        final cropTo = y + 1;
        if (cropTo < src.height - 8) {
          return img.copyCrop(
            src,
            x: 0,
            y: 0,
            width: src.width,
            height: cropTo,
          );
        }
        return src;
      }
    }
  }
  return src;
}
