import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show HapticFeedback;
import 'package:image/image.dart' as img;

import '../protocol/describe_attempt_trace.dart';
import '../protocol/eye_capture_diagnostics.dart';
import '../protocol/ble_protocol.dart';
import '../services/app_log_service.dart';
import '../services/ble_service.dart';
import '../services/live_detection_controller.dart';
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

enum _DescribeFlow { cloud, offline }

class HomeViewModel extends ChangeNotifier {
  final SceneDescriptionService sceneService;
  final SpeechOutput ttsService;
  final SettingsProvider settingsProvider;
  final LiveDetectionController _liveController;
  final DescribeAttemptTraceStore _traceStore;
  final Duration _processingTimeoutDuration;

  HomeViewModel({
    required this.sceneService,
    required this.ttsService,
    required this.settingsProvider,
    LiveDetectionController? liveDetectionController,
    DescribeAttemptTraceStore? traceStore,
    Duration processingTimeout = const Duration(seconds: 60),
  }) : _liveController =
           liveDetectionController ??
           LiveDetectionController(
             ttsService: ttsService,
             cloudService: sceneService.cloudService,
             sceneDescriptionService: sceneService,
             verbosityProvider: () => settingsProvider.liveDetectionVerbosity,
             cloudPolicyProvider: () => settingsProvider.liveCloudPolicy,
           ),
       _traceStore = traceStore ?? DescribeAttemptTraceStore(),
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
  _DescribeFlow? _pendingDescribeFlow;

  StreamSubscription<ObstacleAlert>? _obstacleSub;
  StreamSubscription<Uint8List>? _imageSub;
  StreamSubscription<EyeCaptureDiagnostic>? _eyeDiagnosticSub;
  StreamSubscription<BleConnectionEvent>? _connectionEventSub;
  StreamSubscription<String>? _buttonSub;
  StreamSubscription<void>? _captureSub;
  StreamSubscription<TelemetryPacket>? _telemetrySub;
  StreamSubscription<EyeWifiStatus>? _wifiStatusSub;
  VoidCallback? _bleListener;
  VoidCallback? _sceneServiceListener;
  VoidCallback? _settingsListener;
  Completer<String>? _describeNowCompleter;
  String _lastDiagnostic = '';
  DescribeAttemptTrace? _currentTrace;
  String? _lastBleAnnouncementKey;
  bool _qualityRetryUsed = false;

  // ── Live vision mode state ──
  bool get liveVisionActive => _liveController.active;
  Stream<Uint8List> get activeFrameStream => _liveController.activeFrameStream;
  int get liveCloudCallsUsed => _liveController.cloudCallsUsed;
  int get liveCloudCallsMax => _liveController.cloudCallsMax;
  final OnDeviceVisionService _onDeviceVision = OnDeviceVisionService();
  OfflineVisionStatus? _offlineVisionStatus;
  VisionRuntimeStatus? _visionRuntimeStatus;

  // ── Eye WiFi provisioning state ──
  EyeWifiStatus get wifiStatus => BleService.instance.currentWifiStatus;
  Stream<EyeWifiStatus> get wifiStatusStream =>
      BleService.instance.wifiStatusStream;

  // ── Last vision backend used ──
  VisionBackend? get lastBackend => sceneService.lastBackend;

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
  VisionControlMode get visionControlMode => settingsProvider.visionControlMode;
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
      isEyeConnected &&
      BleService.instance.eyeReadinessStatus.ready &&
      !_isProcessing &&
      !_isPaused &&
      !liveVisionActive;
  bool get canCloudDescribe => canDescribe;
  bool get canOfflineDescribe => canDescribe;

  void _init() {
    _bleListener = () {
      if (liveVisionActive &&
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
    _settingsListener = notifyListeners;
    settingsProvider.addListener(_settingsListener!);
    _liveController.addListener(notifyListeners);

    _obstacleSub = BleService.instance.obstacleStream.listen((alert) {
      notifyListeners();
    });

    _captureSub = BleService.instance.captureStartedStream.listen((_) {
      if (!liveVisionActive) {
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
      if (_isPaused || liveVisionActive) return;
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
      await _processImage(
        imageBytes,
        flow: _pendingDescribeFlow ?? _DescribeFlow.cloud,
      );
    });

    _eyeDiagnosticSub = BleService.instance.eyeCaptureDiagnosticStream.listen((
      diagnostic,
    ) {
      if (liveVisionActive) return;
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

    _buttonSub = BleService.instance.buttonEventStream.listen((event) {
      // Physical button contract (see AGENTS.md):
      //   SINGLE → capture + run the current vision pipeline (Cloud or Local).
      //   DOUBLE → toggle Cloud ↔ Local describe mode.
      //   LONG   → toggle Live detection on/off.
      if (event == EyeEvents.buttonSingle) {
        unawaited(_onButtonSinglePress());
      } else if (event == EyeEvents.buttonDouble) {
        unawaited(_onButtonDoublePress());
      } else if (event == EyeEvents.buttonLong) {
        unawaited(_onButtonLongPress());
      }
    });

    _wifiStatusSub = BleService.instance.wifiStatusStream.listen((_) {
      if (_disposed) return;
      notifyListeners();
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
    try {
      final status = await _onDeviceVision.getOfflineVisionStatus();
      final runtimeStatus = await VisionHealthService(
        onDeviceService: _onDeviceVision,
        cloudService: sceneService.cloudService,
      ).check(eyeConnected: isEyeConnected, includeNetworkCheck: false);
      if (_disposed) return;
      _offlineVisionStatus = status;
      _visionRuntimeStatus = runtimeStatus;
      notifyListeners();
    } catch (e) {
      if (_disposed) return;
      final message = _localFailureDiagnostic(e);
      _setLastDiagnostic(message);
      _recordDescribeLog('Offline vision status refresh failed: $message');
    }
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

  Future<void> startLiveVision() => _liveController.start();

  Future<void> stopLiveVision() => _liveController.stop();

  void _stopLiveVisionInternal() {
    unawaited(_liveController.stop(speak: false));
  }

  // ── Public methods ──
  Future<void> setVisionControlMode(VisionControlMode mode) async {
    settingsProvider.setVisionControlMode(mode);
    if (mode == VisionControlMode.cloud) {
      await sceneService.setMode(VisionMode.cloudOnly);
    } else if (mode == VisionControlMode.local) {
      await sceneService.setMode(VisionMode.offlineOnly);
    }
  }

  Future<String> cycleVisionControlMode({bool speak = true}) async {
    final next = settingsProvider.visionControlMode.next;
    await setVisionControlMode(next);
    final message = '${next.label} mode selected.';
    if (speak) {
      unawaited(ttsService.speak(message));
    }
    return message;
  }

  Future<String> executeActiveVisionMode() async {
    return switch (settingsProvider.visionControlMode) {
      VisionControlMode.cloud => _runCloudMode(),
      VisionControlMode.local => _runLocalMode(),
      VisionControlMode.live => _toggleLiveMode(),
    };
  }

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

  Future<String> describeNow() => describeCloudNow();

  Future<String> describeCloudNow() => _describeNow(_DescribeFlow.cloud);

  Future<String> describeOfflineNow() => _describeNow(_DescribeFlow.offline);

  Future<String> _runCloudMode() async {
    await sceneService.setMode(VisionMode.cloudOnly);
    return describeCloudNow();
  }

  Future<String> _runLocalMode() async {
    await sceneService.setMode(VisionMode.offlineOnly);
    await refreshOfflineVisionStatus();
    if (_visionRuntimeStatus?.basicLocalVisionReady != true) {
      const message =
          'Local vision is unavailable until Apple Vision passes health checks.';
      _setLastDiagnostic('Local L02: $message');
      await ttsService.speak(message);
      return message;
    }
    return describeOfflineNow();
  }

  Future<String> _toggleLiveMode() async {
    if (liveVisionActive) {
      await stopLiveVision();
      return 'Live mode stopped.';
    }
    final readiness = BleService.instance.eyeReadinessStatus;
    if (!isEyeConnected || !readiness.ready) {
      const message = 'iCan Eye is not ready for Live mode.';
      _setLastDiagnostic(message);
      await ttsService.speak(message);
      return message;
    }
    await startLiveVision();
    final error = _liveController.lastError;
    if (liveVisionActive) return 'Live mode started.';
    return error ?? 'Live mode could not start.';
  }

  // ── Physical-button handlers (see AGENTS.md button contract) ──────────
  //
  // SINGLE → run the current mode's describe. If Live is on, no-op so the
  //          ladder isn't interrupted.
  // DOUBLE → toggle Cloud ↔ Local describe mode. Stops Live first if it's
  //          running, so the user lands in a stable state after the swap.
  // LONG   → toggle Live detection on/off.

  Future<void> _onButtonSinglePress() async {
    HapticFeedback.lightImpact();
    if (liveVisionActive) return;
    final mode = settingsProvider.visionControlMode;
    if (mode == VisionControlMode.live) {
      await _toggleLiveMode();
      return;
    }
    await executeActiveVisionMode();
  }

  Future<void> _onButtonDoublePress() async {
    HapticFeedback.mediumImpact();
    if (liveVisionActive) {
      await stopLiveVision();
    }
    final current = settingsProvider.visionControlMode;
    final next = switch (current) {
      VisionControlMode.cloud => VisionControlMode.local,
      VisionControlMode.local => VisionControlMode.cloud,
      VisionControlMode.live => VisionControlMode.cloud,
    };
    await setVisionControlMode(next);
    unawaited(ttsService.speak('${next.label} mode.'));
  }

  Future<void> _onButtonLongPress() async {
    HapticFeedback.heavyImpact();
    await _toggleLiveMode();
  }

  Future<String> _describeNow(_DescribeFlow flow) {
    final readiness = BleService.instance.eyeReadinessStatus;
    if (!canDescribe) {
      const message =
          'Eye E01: no capture start or SIZE from Eye. Stage: camera not ready; received 0/unknown bytes across 0 chunks.';
      _setLastDiagnostic(message);
      _recordDescribeLog(
        'Describe rejected. eyeConnected=$isEyeConnected '
        'processing=$_isProcessing paused=$_isPaused live=$liveVisionActive '
        'readiness=${readiness.phase.name} ready=${readiness.ready} '
        'requiredChars=${readiness.requiredCharacteristicsReady}',
      );
      return Future.value(message);
    }
    if (_describeNowCompleter != null && !_describeNowCompleter!.isCompleted) {
      return _describeNowCompleter!.future;
    }
    _describeNowCompleter = Completer<String>();
    _pendingDescribeFlow = flow;
    _isProcessing = true;
    _waitingForCaptureImage = true;
    _qualityRetryUsed = false;
    notifyListeners();
    _recordDescribeLog(
      'Describe requested. readiness=${readiness.phase.name} '
      'ready=${readiness.ready} '
      'requiredChars=${readiness.requiredCharacteristicsReady} '
      'flow=${flow.name} '
      'hazardSensitivity=${settingsProvider.hazardSensitivity.name}',
    );
    unawaited(
      _beginDescribeTrace(
        DescribePipelineStage.captureRequested,
        imageBytes: 0,
      ).then((_) => _requestEyeProfileAndCapture(flow)),
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
  Future<void> processImageForTesting(
    Uint8List imageBytes, {
    bool offline = false,
  }) {
    return _processImage(
      imageBytes,
      flow: offline ? _DescribeFlow.offline : _DescribeFlow.cloud,
    );
  }

  @visibleForTesting
  void startCaptureTimeoutForTesting() {
    _isProcessing = true;
    _waitingForCaptureImage = true;
    _startProcessingTimeout(cameraTransfer: true);
  }

  Future<void> _processImage(
    Uint8List imageBytes, {
    required _DescribeFlow flow,
  }) async {
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
      final SceneDescriptionResult result;
      if (flow == _DescribeFlow.cloud) {
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
        await _updateDescribeTrace(DescribePipelineStage.cloudRequest);
        result = await sceneService.describeCloud(
          enhancedBytes,
          promptContext: _scenePromptContext(),
        );
      } else {
        await _updateDescribeTrace(DescribePipelineStage.offlineRequest);
        result = await sceneService.describeOffline(
          imageBytes,
          promptContext: _scenePromptContext(),
        );
      }

      final fullText = _isPaused ? '' : result.text.trim();
      var recaptureQueued = false;
      if (!_isPaused && _shouldRetryAfterEyeQualityTune(fullText)) {
        recaptureQueued = true;
        _qualityRetryUsed = true;
        _recordDescribeLog(
          'Describe queued one Eye quality retry. '
          'flags=${BleService.instance.lastEyeStatus?.qualityFlagLabel ?? 'unknown'} '
          'tune=${BleService.instance.lastEyeStatus?.tuneAction ?? 'unknown'}.',
        );
        await _updateDescribeTrace(
          DescribePipelineStage.captureRequested,
          lastError: 'Retrying once after Eye image-quality tune.',
        );
        _waitingForCaptureImage = true;
        _isProcessing = true;
        notifyListeners();
        _startProcessingTimeout(cameraTransfer: true);
        unawaited(
          BleService.instance.triggerEyeCapture().catchError((Object error) {
            _recordDescribeLog(
              'Quality retry capture command future failed: '
              '${error.runtimeType}.',
            );
          }),
        );
      }
      if (fullText.isNotEmpty && !recaptureQueued) {
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
      } else if (!recaptureQueued &&
          _shouldRetryAfterEyeQualityTune(fullText)) {
        _qualityRetryUsed = true;
        _recordDescribeLog(
          'Describe produced no output; retrying Eye capture.',
        );
        await _updateDescribeTrace(
          DescribePipelineStage.captureRequested,
          lastError: 'Retrying once after empty output and Eye quality flag.',
        );
        _waitingForCaptureImage = true;
        _isProcessing = true;
        notifyListeners();
        _startProcessingTimeout(cameraTransfer: true);
        unawaited(
          BleService.instance.triggerEyeCapture().catchError((Object error) {
            _recordDescribeLog(
              'Quality retry capture command future failed: '
              '${error.runtimeType}.',
            );
          }),
        );
        recaptureQueued = true;
      }
    } catch (e) {
      debugPrint('[HomeViewModel] Error processing image: $e');
      await _updateDescribeTrace(
        DescribePipelineStage.failed,
        lastError: _processingErrorMessage(e),
      );
      await _speakProcessingError(e);
    } finally {
      if (!_waitingForCaptureImage) {
        _isProcessing = false;
        _pendingDescribeFlow = null;
        _qualityRetryUsed = false;
        _processingTimeout?.cancel();
        if (_describeNowCompleter != null &&
            !_describeNowCompleter!.isCompleted) {
          _completeDescribeNow('Scene description produced no output.');
        }
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

  bool _shouldRetryAfterEyeQualityTune(String text) {
    if (_qualityRetryUsed) return false;
    final status = BleService.instance.lastEyeStatus;
    if (status == null || !status.hasImageQualityIssue) return false;
    final normalized = text.toLowerCase();
    if (normalized.trim().isEmpty) return true;
    return normalized.contains('unclear') ||
        normalized.contains('could not be clearly identified') ||
        normalized.contains('scene analysis unavailable') ||
        normalized.contains('too dark') ||
        normalized.contains('low contrast');
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

  Future<void> _requestEyeProfileAndCapture(_DescribeFlow flow) async {
    const requestedProfile = EyeProfileIndex.balanced;
    final requestedLabel = _eyeProfileLabel(requestedProfile);
    await _updateDescribeTrace(
      DescribePipelineStage.captureRequested,
      requestedEyeProfile: requestedLabel,
    );
    _recordDescribeLog(
      'Eye profile requested for Describe: $requestedLabel '
      'flow=${flow.name}.',
    );
    try {
      await BleService.instance
          .setEyeProfile(requestedProfile)
          .timeout(const Duration(milliseconds: 900));
      _recordDescribeLog('Eye profile ack received: $requestedLabel.');
    } on TimeoutException {
      final current = BleService.instance.currentEyeProfileLabel ?? 'unknown';
      _recordDescribeLog(
        'Eye profile ack timed out for $requestedLabel; '
        'continuing Describe with current ready profile $current.',
      );
    } catch (error) {
      final current = BleService.instance.currentEyeProfileLabel ?? 'unknown';
      _recordDescribeLog(
        'Eye profile request failed for $requestedLabel: '
        '${error.runtimeType}; continuing with $current.',
      );
    }
    if (_disposed || !_isProcessing || !_waitingForCaptureImage) return;
    _startProcessingTimeout(cameraTransfer: true);
    unawaited(
      BleService.instance.triggerEyeCapture().catchError((Object error) {
        _recordDescribeLog(
          'Capture command future failed: ${error.runtimeType}.',
        );
      }),
    );
  }

  ScenePromptContext _scenePromptContext() {
    return ScenePromptContext.fromSettings(settingsProvider);
  }

  String _eyeProfileLabel(int profileIndex) {
    return switch (profileIndex) {
      EyeProfileIndex.fast => 'FAST',
      EyeProfileIndex.balanced => 'BALANCED',
      EyeProfileIndex.quality => 'QUALITY',
      EyeProfileIndex.max => 'MAX',
      _ => 'UNKNOWN:$profileIndex',
    };
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
      hazardSensitivity: settingsProvider.hazardSensitivity.name,
    );
    _currentTrace = trace;
    _recordDescribeLog('Describe attempt ${trace.attemptId} ${stage.name}.');
    await _traceStore.save(trace);
  }

  Future<void> _updateDescribeTrace(
    DescribePipelineStage stage, {
    int? imageBytes,
    String? lastError,
    String? requestedEyeProfile,
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
      hazardSensitivity: settingsProvider.hazardSensitivity.name,
      requestedEyeProfile: requestedEyeProfile,
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
    if (liveVisionActive) {
      _stopLiveVisionInternal();
    }
    _disposed = true;
    _obstacleSub?.cancel();
    _imageSub?.cancel();
    _eyeDiagnosticSub?.cancel();
    _connectionEventSub?.cancel();
    _buttonSub?.cancel();
    _captureSub?.cancel();
    _telemetrySub?.cancel();
    _wifiStatusSub?.cancel();
    _processingTimeout?.cancel();
    if (_bleListener != null) {
      BleService.instance.removeListener(_bleListener!);
    }
    if (_sceneServiceListener != null) {
      sceneService.removeListener(_sceneServiceListener!);
    }
    if (_settingsListener != null) {
      settingsProvider.removeListener(_settingsListener!);
    }
    _liveController.removeListener(notifyListeners);
    _liveController.dispose();
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
