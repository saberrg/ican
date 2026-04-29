import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:provider/provider.dart';

import '../core/theme.dart';
import '../models/settings_provider.dart';
import '../protocol/ble_protocol.dart';
import '../services/app_log_service.dart';
import '../services/ble_service.dart';
import '../services/on_device_vision_service.dart';
import '../services/tts_service.dart';
import '../widgets/accessible_button.dart';

/// Discrete states the live-detection loop can occupy. Enforced by
/// [_LiveDetectionScreenState._setLive] so transitions are always logged and
/// illegal jumps (e.g. transferring -> stopping without a cooldown) don't
/// silently corrupt the UI or TTS queue.
enum LiveState {
  idle,
  starting,
  transferring,
  analyzing,
  speaking,
  cooldown,
  stopping,
  error,
}

class _DetectionEvent {
  final String label;
  final String position;
  final double confidence;
  final DateTime timestamp;

  _DetectionEvent({
    required this.label,
    required this.position,
    required this.confidence,
    required this.timestamp,
  });
}

enum _LiveDetectionMode { full, basic, eyeAssisted }

class LiveDetectionScreen extends StatefulWidget {
  const LiveDetectionScreen({super.key});

  @override
  State<LiveDetectionScreen> createState() => _LiveDetectionScreenState();
}

class _LiveDetectionScreenState extends State<LiveDetectionScreen> {
  final OnDeviceVisionService _vision = OnDeviceVisionService();
  final TtsService _tts = TtsService.instance;
  final BleService _ble = BleService.instance;

  bool _checkingPrereqs = true;
  String? _errorMessage;
  String? _errorHint;

  StreamSubscription<Uint8List>? _imageSub;
  StreamSubscription<void>? _connectionSub;
  _LiveDetectionMode _mode = _LiveDetectionMode.basic;
  String? _modeHint;

  LiveState _state = LiveState.idle;
  Completer<void>? _inflightAnalysis;
  DateTime? _lastDisconnectSpokenAt;
  // How long to stay in cooldown between frames. Keeps us from starting the
  // next analysis back-to-back before TTS finishes speaking the last one.
  static const Duration _cooldownDuration = Duration(milliseconds: 600);

  Uint8List? _latestImage;
  List<SpatialObjectData> _detections = [];
  final List<_DetectionEvent> _log = [];
  final Map<String, DateTime> _lastAnnounced = {};

  @override
  void initState() {
    super.initState();
    _checkPrerequisites();
  }

  /// Centralised state transition. Logs every change and blocks illegal
  /// jumps; returns true if the transition happened.
  bool _setLive(LiveState next) {
    if (!mounted) return false;
    if (_state == next) return true;
    final allowed = _isTransitionAllowed(_state, next);
    if (!allowed) {
      debugPrint(
        '[LiveDetection] Rejected transition ${_state.name} -> ${next.name}',
      );
      return false;
    }
    AppLogService.instance.record(
      'Live state ${_state.name} -> ${next.name}',
      source: 'live',
    );
    setState(() => _state = next);
    return true;
  }

  bool _isTransitionAllowed(LiveState from, LiveState to) {
    // `error` and `stopping` are always reachable — they terminate loops.
    if (to == LiveState.error || to == LiveState.stopping) return true;
    switch (from) {
      case LiveState.idle:
        return to == LiveState.starting;
      case LiveState.starting:
        return to == LiveState.transferring || to == LiveState.idle;
      case LiveState.transferring:
        return to == LiveState.analyzing || to == LiveState.cooldown;
      case LiveState.analyzing:
        return to == LiveState.speaking || to == LiveState.cooldown;
      case LiveState.speaking:
        return to == LiveState.cooldown;
      case LiveState.cooldown:
        return to == LiveState.transferring || to == LiveState.idle;
      case LiveState.stopping:
        return to == LiveState.idle;
      case LiveState.error:
        return to == LiveState.idle;
    }
  }

  Future<void> _checkPrerequisites() async {
    if (BleService.instance.state != BleConnectionState.connected) {
      if (!mounted) return;
      setState(() {
        _checkingPrereqs = false;
        _errorMessage = 'iCan Eye is not connected.';
        _errorHint =
            'Please pair or reconnect the Eye before using Live Detection.';
      });
      return;
    }

    final nativeReady = await _vision.pingNativeChannel();
    final appleVisionReady =
        nativeReady && await _vision.isAppleVisionAvailable();
    final status = await _vision.getOfflineVisionStatus();
    final diagnostics = await _vision.getOfflineVisionDiagnostics();
    if (!nativeReady || !appleVisionReady) {
      if (!mounted) return;
      setState(() {
        _checkingPrereqs = false;
        _mode = _LiveDetectionMode.eyeAssisted;
        _modeHint = nativeReady
            ? 'Eye-assisted live mode: Apple Vision is unavailable, so object detection is paused.'
            : 'Eye-assisted live mode: native vision is unavailable, so object detection is paused.';
      });
      _startCaptureLoop();
      return;
    }

    if (!mounted) return;
    setState(() {
      _checkingPrereqs = false;
      _mode = status.objectDetectionAvailable
          ? _LiveDetectionMode.full
          : _LiveDetectionMode.basic;
      _modeHint = switch (_mode) {
        _LiveDetectionMode.basic =>
          'Basic live mode: ${diagnostics.objectDetector.message}',
        _LiveDetectionMode.full => null,
        _LiveDetectionMode.eyeAssisted => _modeHint,
      };
    });
    _startCaptureLoop();
  }

  Future<void> _startCaptureLoop() async {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      SemanticsService.announce(
        _mode == _LiveDetectionMode.full
            ? 'Full live detection started. Objects will be announced as they are detected.'
            : _mode == _LiveDetectionMode.basic
            ? 'Basic live mode started. Text, people, and scene cues will be announced.'
            : 'Eye-assisted live mode started. Camera frames and Eye health will be monitored.',
        TextDirection.ltr,
      );
    });

    _setLive(LiveState.starting);

    _imageSub = _ble.imageStream.listen(
      _handleImage,
      onError: (Object e) {
        debugPrint('[LiveDetection] imageStream error: $e');
      },
    );

    // Listen for Eye disconnect mid-session so we can cleanly shut down TTS,
    // cancel in-flight analysis, and announce the failure exactly once.
    _connectionSub = _ble.connectionEventStream
        .where(
          (event) =>
              event.deviceKind == BleDeviceKind.eye && event.ready == false,
        )
        .listen((_) => _handleEyeDisconnected());

    await _ble.setEyeProfile(EyeProfileIndex.fast);
    await _ble.startLiveCapture(intervalMs: 1500);
    // Transition into transferring so the first incoming chunk is accepted.
    _setLive(LiveState.transferring);
  }

  Future<void> _handleImage(Uint8List imageBytes) async {
    if (!mounted) return;
    // Drop frames that arrive while we're already busy analyzing/speaking.
    // Only transferring/cooldown are valid entry points.
    if (_state != LiveState.transferring && _state != LiveState.cooldown) {
      return;
    }

    if (mounted) {
      setState(() => _latestImage = imageBytes);
    }
    if (_mode == _LiveDetectionMode.eyeAssisted) {
      _handleEyeAssistedFrame();
      return;
    }
    if (!_setLive(LiveState.analyzing)) return;

    final completer = Completer<void>();
    _inflightAnalysis = completer;

    try {
      final result = await _vision.analyzeScene(imageBytes);
      // Caller aborted (disconnect/stop) while we were analyzing.
      if (!mounted || completer != _inflightAnalysis) {
        completer.complete();
        return;
      }

      if (_mode == _LiveDetectionMode.basic) {
        _handleBasicResult(result);
        _enterCooldown(completer);
        return;
      }

      final filtered =
          result.detectedObjects.where((o) => o.confidence >= 0.5).toList()
            ..sort((a, b) => b.confidence.compareTo(a.confidence));

      if (mounted) {
        setState(() => _detections = filtered);
      }

      if (filtered.isNotEmpty && mounted) {
        final verbosity = context
            .read<SettingsProvider>()
            .liveDetectionVerbosity;
        final now = DateTime.now();

        switch (verbosity) {
          case LiveDetectionVerbosity.minimal:
            final top = filtered.first;
            final lastTime = _lastAnnounced[top.label];
            if (lastTime == null ||
                now.difference(lastTime) >= const Duration(seconds: 3)) {
              _lastAnnounced[top.label] = now;
              _tts.speak(top.label);
            }
            _addLogEntry(top.label, '', top.confidence, now);

          case LiveDetectionVerbosity.positional:
            final top = filtered.first;
            final position = _positionFromCenterX(top.centerX);
            final lastTime = _lastAnnounced[top.label];
            if (lastTime == null ||
                now.difference(lastTime) >= const Duration(seconds: 3)) {
              _lastAnnounced[top.label] = now;
              _tts.speak('${top.label} $position');
            }
            _addLogEntry(top.label, position, top.confidence, now);

          case LiveDetectionVerbosity.full:
            final topN = filtered.take(3).toList();
            final anyRecentlyAnnounced = topN.any((d) {
              final t = _lastAnnounced[d.label];
              return t != null &&
                  now.difference(t) < const Duration(seconds: 3);
            });
            if (!anyRecentlyAnnounced) {
              final parts = topN
                  .map((d) {
                    final pos = _positionFromCenterX(d.centerX);
                    return '${d.label} $pos';
                  })
                  .join(', ');
              _tts.speak(parts);
              for (final d in topN) {
                _lastAnnounced[d.label] = now;
              }
            }
            for (final d in topN) {
              _addLogEntry(
                d.label,
                _positionFromCenterX(d.centerX),
                d.confidence,
                now,
              );
            }
        }
      }
    } catch (e) {
      debugPrint('[LiveDetection] analyzeScene failed: $e');
    }

    _enterCooldown(completer);
  }

  void _enterCooldown(Completer<void> completer) {
    if (!mounted || completer != _inflightAnalysis) {
      completer.complete();
      return;
    }
    _setLive(LiveState.cooldown);
    Future<void>.delayed(_cooldownDuration, () {
      if (!mounted) return;
      if (_inflightAnalysis != completer) return;
      if (_state != LiveState.cooldown) return;
      _setLive(LiveState.transferring);
      _inflightAnalysis = null;
      completer.complete();
    });
  }

  Future<void> _handleEyeDisconnected() async {
    if (!mounted) return;
    // Debounce: speak the disconnect notice at most once every 5 seconds.
    final now = DateTime.now();
    final last = _lastDisconnectSpokenAt;
    if (last == null || now.difference(last) >= const Duration(seconds: 5)) {
      _lastDisconnectSpokenAt = now;
      unawaited(_tts.speak('iCan Eye disconnected. Live mode stopped.'));
    }
    _inflightAnalysis = null;
    await _tts.stop();
    _setLive(LiveState.stopping);
    _stopLoop();
    if (mounted) _setLive(LiveState.idle);
  }

  void _handleBasicResult(ScenePerceptionResult result) {
    final now = DateTime.now();
    final cues = <_DetectionEvent>[];

    if (result.personCount > 0) {
      cues.add(
        _DetectionEvent(
          label: result.personCount == 1
              ? '1 person detected'
              : '${result.personCount} people detected',
          position: '',
          confidence: 1,
          timestamp: now,
        ),
      );
    }

    if (result.ocrTexts.isNotEmpty) {
      cues.add(
        _DetectionEvent(
          label: 'Text: ${result.ocrTexts.take(2).join(', ')}',
          position: '',
          confidence: 1,
          timestamp: now,
        ),
      );
    }

    if (result.sceneClassification != 'unknown' &&
        result.sceneConfidence > 0.25) {
      cues.add(
        _DetectionEvent(
          label: '${result.sceneClassification.replaceAll('_', ' ')} setting',
          position: '',
          confidence: result.sceneConfidence,
          timestamp: now,
        ),
      );
    }

    if (cues.isEmpty) return;
    final spoken = cues.map((cue) => cue.label).join(', ');
    final lastTime = _lastAnnounced[spoken];
    if (lastTime == null ||
        now.difference(lastTime) >= const Duration(seconds: 4)) {
      _lastAnnounced[spoken] = now;
      _tts.speak('Basic live mode: $spoken.');
    }

    if (!mounted) return;
    setState(() {
      for (final cue in cues.reversed) {
        _log.insert(0, cue);
      }
      if (_log.length > 50) {
        _log.removeRange(50, _log.length);
      }
      _detections = const [];
    });
  }

  void _handleEyeAssistedFrame() {
    final now = DateTime.now();
    final status = _ble.lastEyeStatus;
    final label = status == null
        ? 'Camera frame received'
        : 'Camera frame received; quality ${status.qualityFlagLabel}';
    final lastTime = _lastAnnounced[label];
    if (lastTime == null ||
        now.difference(lastTime) >= const Duration(seconds: 6)) {
      _lastAnnounced[label] = now;
      _addLogEntry(label, '', 1, now);
    }
    _setLive(LiveState.cooldown);
    Future<void>.delayed(_cooldownDuration, () {
      if (!mounted) return;
      if (_state == LiveState.cooldown) _setLive(LiveState.transferring);
    });
  }

  static String _positionFromCenterX(double cx) {
    if (cx < 0.33) return 'on your left';
    if (cx < 0.66) return 'ahead';
    return 'on your right';
  }

  void _addLogEntry(
    String label,
    String position,
    double confidence,
    DateTime ts,
  ) {
    if (!mounted) return;
    setState(() {
      _log.insert(
        0,
        _DetectionEvent(
          label: label,
          position: position,
          confidence: confidence,
          timestamp: ts,
        ),
      );
      if (_log.length > 50) _log.removeLast();
    });
  }

  void _stopLoop() {
    // Only send commands if a capture has actually started. `starting` also
    // counts so we unwind partial setup cleanly.
    final wasActive = _state != LiveState.idle && _state != LiveState.error;
    if (wasActive) {
      // Best-effort: abort any in-flight transfer, stop live mode on the Eye.
      unawaited(_ble.sendEyeAbort());
      unawaited(_ble.stopLiveCapture());
    }
    _imageSub?.cancel();
    _imageSub = null;
    _connectionSub?.cancel();
    _connectionSub = null;
    _inflightAnalysis = null;
  }

  @override
  void dispose() {
    _stopLoop();
    _tts.stop();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_checkingPrereqs) {
      return Scaffold(
        backgroundColor: AppColors.backgroundLight,
        body: const Center(child: CircularProgressIndicator()),
      );
    }

    if (_errorMessage != null) {
      return _buildErrorView();
    }

    return _buildDetectionView();
  }

  Widget _buildErrorView() {
    return Scaffold(
      backgroundColor: AppColors.backgroundLight,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.md),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.error_outline, size: 64, color: AppColors.textOnLight),
              const SizedBox(height: AppSpacing.md),
              Semantics(
                header: true,
                label: _errorMessage,
                child: Text(
                  _errorMessage!,
                  style: TextStyle(
                    fontSize: 22.sp,
                    fontWeight: FontWeight.bold,
                    color: AppColors.textOnLight,
                  ),
                  textAlign: TextAlign.center,
                ),
              ),
              if (_errorHint != null) ...[
                const SizedBox(height: AppSpacing.sm),
                Semantics(
                  label: _errorHint,
                  child: Text(
                    _errorHint!,
                    style: TextStyle(
                      fontSize: 16.sp,
                      color: AppColors.textSecondaryOnLight,
                      height: 1.5,
                    ),
                    textAlign: TextAlign.center,
                  ),
                ),
              ],
              const SizedBox(height: AppSpacing.lg),
              AccessibleButton(
                label: 'Back',
                hint: 'Returns to the previous screen',
                onPressed: () => Navigator.of(context).pop(),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildDetectionView() {
    return Scaffold(
      backgroundColor: AppColors.backgroundLight,
      body: SafeArea(
        child: Column(
          children: [
            if (_mode != _LiveDetectionMode.full) _buildBasicModeBanner(),

            // Image + bounding box overlay
            Expanded(flex: 3, child: _buildImageArea()),

            // Detection log
            Expanded(flex: 2, child: _buildLogArea()),

            // Stop button
            Padding(
              padding: const EdgeInsets.all(AppSpacing.sm),
              child: AccessibleButton(
                label: 'Stop',
                hint: 'Stops live detection and returns to the previous screen',
                onPressed: () {
                  _stopLoop();
                  _tts.stop();
                  Navigator.of(context).pop();
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildBasicModeBanner() {
    final text = _modeHint ?? 'Basic live mode is active.';
    return Semantics(
      label: text,
      child: Container(
        width: double.infinity,
        color: const Color(0xFFFFF4D6),
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.sm,
          vertical: AppSpacing.xs,
        ),
        child: Text(
          text,
          style: TextStyle(
            fontSize: 14.sp,
            fontWeight: FontWeight.w600,
            color: AppColors.textOnLight,
          ),
        ),
      ),
    );
  }

  Widget _buildImageArea() {
    return Semantics(
      label: _mode == _LiveDetectionMode.basic
          ? 'Camera feed. Basic live mode active.'
          : _mode == _LiveDetectionMode.eyeAssisted
          ? 'Camera feed. Eye-assisted live mode active.'
          : _detections.isEmpty
          ? 'Camera feed. No objects detected.'
          : 'Camera feed. ${_detections.length} objects detected.',
      image: true,
      child: Container(
        width: double.infinity,
        color: Colors.black,
        child: _latestImage == null
            ? Center(
                child: Text(
                  'Waiting for camera…',
                  style: TextStyle(color: Colors.white70, fontSize: 16.sp),
                ),
              )
            : LayoutBuilder(
                builder: (context, constraints) {
                  return Stack(
                    fit: StackFit.expand,
                    children: [
                      Image.memory(
                        _latestImage!,
                        fit: BoxFit.contain,
                        gaplessPlayback: true,
                      ),
                      if (_detections.isNotEmpty)
                        CustomPaint(
                          painter: _BoundingBoxPainter(
                            detections: _detections,
                            imageBytes: _latestImage!,
                            containerSize: Size(
                              constraints.maxWidth,
                              constraints.maxHeight,
                            ),
                          ),
                        ),
                    ],
                  );
                },
              ),
      ),
    );
  }

  Widget _buildLogArea() {
    return Container(
      width: double.infinity,
      constraints: const BoxConstraints(minHeight: 150),
      decoration: BoxDecoration(
        color: AppColors.surfaceCardLight,
        border: Border(top: BorderSide(color: AppColors.borderLight, width: 1)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(
              AppSpacing.sm,
              AppSpacing.xs,
              AppSpacing.sm,
              0,
            ),
            child: ExcludeSemantics(
              child: Text(
                _mode == _LiveDetectionMode.basic
                    ? 'Basic Live Log'
                    : _mode == _LiveDetectionMode.eyeAssisted
                    ? 'Eye Live Log'
                    : 'Detection Log',
                style: TextStyle(
                  fontSize: 14.sp,
                  fontWeight: FontWeight.w600,
                  color: AppColors.textSecondaryOnLight,
                ),
              ),
            ),
          ),
          Expanded(
            child: _log.isEmpty
                ? Center(
                    child: Semantics(
                      label: 'No detections yet',
                      child: Text(
                        'No detections yet',
                        style: TextStyle(
                          fontSize: 14.sp,
                          color: AppColors.disabledOnLight,
                          fontStyle: FontStyle.italic,
                        ),
                      ),
                    ),
                  )
                : ListView.builder(
                    padding: const EdgeInsets.symmetric(
                      horizontal: AppSpacing.sm,
                      vertical: AppSpacing.xs,
                    ),
                    itemCount: _log.length,
                    itemBuilder: (context, index) {
                      final event = _log[index];
                      final time =
                          '${event.timestamp.hour.toString().padLeft(2, '0')}:'
                          '${event.timestamp.minute.toString().padLeft(2, '0')}:'
                          '${event.timestamp.second.toString().padLeft(2, '0')}';
                      final pct = (event.confidence * 100).round();
                      final desc = event.position.isEmpty
                          ? event.label
                          : '${event.label} ${event.position}';
                      return Semantics(
                        label: '$desc, $pct percent confidence, at $time',
                        child: Padding(
                          padding: const EdgeInsets.symmetric(vertical: 2),
                          child: Text(
                            '$time  $desc ($pct%)',
                            style: TextStyle(
                              fontSize: 14.sp,
                              color: AppColors.textOnLight,
                              fontFamily: 'monospace',
                            ),
                          ),
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}

class _BoundingBoxPainter extends CustomPainter {
  final List<SpatialObjectData> detections;
  final Uint8List imageBytes;
  final Size containerSize;

  _BoundingBoxPainter({
    required this.detections,
    required this.imageBytes,
    required this.containerSize,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final image = _decodeImageSize(imageBytes);
    if (image == null) return;

    final imageW = image.width.toDouble();
    final imageH = image.height.toDouble();

    final scaleX = containerSize.width / imageW;
    final scaleY = containerSize.height / imageH;
    final scale = scaleX < scaleY ? scaleX : scaleY;

    final renderedW = imageW * scale;
    final renderedH = imageH * scale;
    final offsetX = (containerSize.width - renderedW) / 2;
    final offsetY = (containerSize.height - renderedH) / 2;

    final boxPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.0
      ..color = const Color(0xFF00E676);

    final fillPaint = Paint()
      ..style = PaintingStyle.fill
      ..color = const Color(0x3300E676);

    final textStyle = TextStyle(
      color: const Color(0xFF00E676),
      fontSize: 13,
      fontWeight: FontWeight.bold,
      backgroundColor: const Color(0xCC000000),
    );

    for (final det in detections) {
      if (det.bboxX == null ||
          det.bboxY == null ||
          det.bboxW == null ||
          det.bboxH == null) {
        continue;
      }

      final left = offsetX + det.bboxX! * renderedW;
      final top = offsetY + det.bboxY! * renderedH;
      final width = det.bboxW! * renderedW;
      final height = det.bboxH! * renderedH;
      final rect = Rect.fromLTWH(left, top, width, height);

      canvas.drawRect(rect, fillPaint);
      canvas.drawRect(rect, boxPaint);

      final tp = TextPainter(
        text: TextSpan(
          text: ' ${det.label} ${(det.confidence * 100).round()}% ',
          style: textStyle,
        ),
        textDirection: TextDirection.ltr,
      )..layout();

      final labelY = top - tp.height - 2;
      tp.paint(canvas, Offset(left, labelY < offsetY ? top : labelY));
    }
  }

  @override
  bool shouldRepaint(_BoundingBoxPainter oldDelegate) =>
      !listEquals(oldDelegate.detections, detections) ||
      !identical(oldDelegate.imageBytes, imageBytes);

  static _ImageSize? _decodeImageSize(Uint8List data) {
    if (data.length < 4) return null;
    if (data[0] == 0xFF && data[1] == 0xD8) {
      int i = 2;
      while (i < data.length - 9) {
        if (data[i] != 0xFF) break;
        final marker = data[i + 1];
        if (marker == 0xC0 || marker == 0xC2) {
          final h = (data[i + 5] << 8) | data[i + 6];
          final w = (data[i + 7] << 8) | data[i + 8];
          if (w > 0 && h > 0) return _ImageSize(w, h);
        }
        final segLen = (data[i + 2] << 8) | data[i + 3];
        i += 2 + segLen;
      }
    }
    return null;
  }
}

class _ImageSize {
  final int width;
  final int height;
  const _ImageSize(this.width, this.height);
}
