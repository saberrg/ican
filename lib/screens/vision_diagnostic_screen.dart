import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/theme.dart';
import '../services/ble_service.dart';
import '../services/on_device_vision_service.dart';
import '../widgets/accessible_button.dart';

class VisionDiagnosticScreen extends StatefulWidget {
  const VisionDiagnosticScreen({super.key, this.onDeviceService});

  final OnDeviceVisionService? onDeviceService;

  @override
  State<VisionDiagnosticScreen> createState() => _VisionDiagnosticScreenState();
}

class _VisionDiagnosticScreenState extends State<VisionDiagnosticScreen> {
  late final OnDeviceVisionService _vision =
      widget.onDeviceService ?? OnDeviceVisionService();
  String _report = 'Diagnostics not run yet.';
  var _running = false;

  // ── Model download state ──
  ModelStatus _modelStatus = ModelStatus.notDownloaded;
  String _fmReason = 'unknown';
  StreamSubscription<ModelDownloadEvent>? _downloadSub;
  double _downloadProgress = 0;
  String _downloadPhase = '';
  String? _downloadError;

  @override
  void initState() {
    super.initState();
    unawaited(_refreshQuickStatus());
  }

  @override
  void dispose() {
    _downloadSub?.cancel();
    super.dispose();
  }

  Future<void> _refreshQuickStatus() async {
    try {
      final status = await _vision.getModelStatus();
      final reason = await _vision.foundationModelsAvailabilityReason();
      if (!mounted) return;
      setState(() {
        _modelStatus = status;
        _fmReason = reason;
      });
    } catch (_) {
      // Silent — the full diagnostic run will surface errors.
    }
  }

  Future<void> _runDiagnostics() async {
    setState(() => _running = true);
    final ble = BleService.instance;
    final lines = <String>[
      'iCan Eye diagnostics',
      'Connection: ${ble.state.name}',
      'Readiness: ${ble.eyeReadinessStatus.phase.name}',
      'Ready: ${ble.eyeReadinessStatus.ready}',
      if (ble.eyeReadinessStatus.lastError != null)
        'BLE error: ${ble.eyeReadinessStatus.lastError}',
    ];
    final eyeStatus = ble.lastEyeStatus;
    if (eyeStatus != null) {
      lines.addAll([
        'Firmware: ${eyeStatus.firmwareVersion ?? 'unknown'}',
        'Profile: ${eyeStatus.profileName ?? 'unknown'}',
        'Mode: ${eyeStatus.mode ?? 'unknown'}',
        'Interval: ${eyeStatus.intervalMs ?? 0} ms',
        'Free PSRAM: ${eyeStatus.freePsramBytes ?? 0}',
        'MTU: ${eyeStatus.negotiatedMtu ?? 0}',
        'Payload cap: ${eyeStatus.payloadCap ?? 0}',
        'Last Eye error: ${eyeStatus.lastError ?? 'none'}',
        'Camera sensor: ${eyeStatus.cameraSensor ?? 'unknown'}',
        'Last stream: ${eyeStatus.lastStreamBytes ?? 0} bytes, '
            '${eyeStatus.lastStreamChunks ?? 0} chunks, '
            '${eyeStatus.lastStreamMs ?? 0} ms',
        'Image quality: ${eyeStatus.qualityFlagLabel}',
        'Brightness estimate: ${eyeStatus.brightnessEstimate ?? 0}',
        'Contrast estimate: ${eyeStatus.contrastEstimate ?? 0}',
        'Eye tune: ${eyeStatus.tuneAction ?? 'unknown'}',
      ]);
    }

    try {
      final nativeReady = await _vision.pingNativeChannel();
      final appleVision = nativeReady && await _vision.isAppleVisionAvailable();
      final offline = await _vision.getOfflineVisionStatus();
      final fmReason = await _vision.foundationModelsAvailabilityReason();
      final nativeModels = await _vision.getOfflineVisionDiagnostics();
      final readinessSnapshot = await _vision
          .getSmolVlmReadinessSupportSnapshot();
      var smolVlmLoad = 'skipped';
      if (offline.modelStatus == ModelStatus.loaded) {
        smolVlmLoad = 'already loaded';
      } else if (offline.modelStatus == ModelStatus.ready) {
        final loaded = await _vision.loadVlmModel();
        smolVlmLoad = loaded ? 'loaded successfully' : 'load failed';
      }
      lines.addAll([
        'Native channel: ${nativeReady ? 'ready' : 'unavailable'}',
        'Apple Vision: ${appleVision ? 'ready' : 'unavailable'}',
        'Foundation Models: ${_foundationModelsLine(fmReason)}',
        'SmolVLM2 status: ${_modelStatusLabel(offline.modelStatus)}',
        'SmolVLM2 load: $smolVlmLoad',
        'Vision template fallback: ${appleVision ? 'ready' : 'unavailable'}',
        'Best local backend: ${offline.bestLocalBackendLabel}',
        'YOLOv3 Tiny: ${offline.objectDetectionAvailable ? 'ready' : 'unavailable'}',
        'Depth Anything: ${offline.depthEstimationAvailable ? 'ready' : 'unavailable'}',
        'YOLO detail: ${nativeModels.objectDetector.message}',
        'Depth detail: ${nativeModels.depthEstimator.message}',
        'SmolVLM2 readiness snapshot:',
        readinessSnapshot,
      ]);
      if (mounted) {
        setState(() {
          _modelStatus = offline.modelStatus;
          _fmReason = fmReason;
        });
      }
    } catch (e) {
      lines.add('Native diagnostics failed: $e');
    }

    if (!mounted) return;
    setState(() {
      _report = lines.join('\n');
      _running = false;
    });
  }

  void _startDownload() {
    if (_downloadSub != null) return;
    setState(() {
      _downloadProgress = 0;
      _downloadPhase = 'Starting download...';
      _downloadError = null;
      _modelStatus = ModelStatus.downloading;
    });
    _downloadSub = _vision.startModelDownload().listen(
      (event) {
        if (!mounted) return;
        setState(() {
          _downloadProgress = event.progress.clamp(0.0, 1.0);
          final total = event.totalFiles;
          final done = event.filesDownloaded;
          if (total > 0) {
            _downloadPhase =
                'Downloading $done/$total files '
                '(${(event.progress * 100).clamp(0, 100).toStringAsFixed(0)}%)';
          } else if (event.phase.isNotEmpty) {
            _downloadPhase = event.phase;
          } else {
            _downloadPhase =
                'Downloading '
                '${(event.progress * 100).clamp(0, 100).toStringAsFixed(0)}%';
          }
        });
      },
      onError: (Object e) {
        if (!mounted) return;
        setState(() {
          _downloadError = '$e';
          _downloadPhase = 'Download failed.';
        });
        _downloadSub?.cancel();
        _downloadSub = null;
        unawaited(_refreshQuickStatus());
      },
      onDone: () {
        if (!mounted) return;
        setState(() {
          _downloadPhase = 'Download complete.';
          _downloadProgress = 1.0;
        });
        _downloadSub?.cancel();
        _downloadSub = null;
        unawaited(_refreshQuickStatus());
      },
    );
  }

  Future<void> _cancelDownload() async {
    await _vision.cancelModelDownload();
    await _downloadSub?.cancel();
    _downloadSub = null;
    if (!mounted) return;
    setState(() {
      _downloadPhase = 'Download cancelled.';
    });
    unawaited(_refreshQuickStatus());
  }

  Future<void> _deleteModel() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete SmolVLM2?'),
        content: const Text(
          'This removes the downloaded local model. You can redownload it later.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await _vision.deleteModel();
    if (!mounted) return;
    setState(() {
      _downloadProgress = 0;
      _downloadPhase = '';
    });
    await _refreshQuickStatus();
  }

  String _foundationModelsLine(String reason) {
    switch (reason) {
      case 'available':
        return 'ready';
      case 'appleIntelligenceDisabled':
        return 'turn on Apple Intelligence in Settings → Apple Intelligence & Siri';
      case 'deviceNotEligible':
        return 'not supported on this device';
      case 'modelDownloading':
        return 'system model is still downloading';
      case 'iosTooOld':
        return 'requires iOS 26 or newer';
      case 'frameworkMissing':
        return 'framework not linked in this build';
      default:
        return 'unavailable';
    }
  }

  String _modelStatusLabel(ModelStatus status) {
    switch (status) {
      case ModelStatus.notAvailable:
        return 'runtime unavailable';
      case ModelStatus.notDownloaded:
        return 'not downloaded';
      case ModelStatus.downloading:
        return 'downloading';
      case ModelStatus.ready:
        return 'downloaded';
      case ModelStatus.loaded:
        return 'loaded';
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.backgroundLight,
      appBar: AppBar(title: const Text('Dev Diagnostics')),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.sm),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              AccessibleButton(
                label: _running ? 'Running Diagnostics' : 'Run Diagnostics',
                hint: 'Checks BLE Eye status and native offline vision health',
                onPressed: _running ? null : _runDiagnostics,
              ),
              const SizedBox(height: AppSpacing.sm),
              AccessibleButton(
                label: 'Copy Diagnostics',
                hint: 'Copies the diagnostic report',
                onPressed: () =>
                    Clipboard.setData(ClipboardData(text: _report)),
              ),
              const SizedBox(height: AppSpacing.sm),
              Expanded(
                child: SingleChildScrollView(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      _buildModelSection(),
                      const SizedBox(height: AppSpacing.sm),
                      _buildFoundationModelsRow(),
                      const SizedBox(height: AppSpacing.sm),
                      DecoratedBox(
                        decoration: BoxDecoration(
                          color: AppColors.surfaceCardLight,
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(color: AppColors.borderLight),
                        ),
                        child: Padding(
                          padding: const EdgeInsets.all(AppSpacing.sm),
                          child: SelectableText(_report),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildModelSection() {
    final isDownloading =
        _downloadSub != null || _modelStatus == ModelStatus.downloading;
    return Container(
      padding: const EdgeInsets.all(AppSpacing.sm),
      decoration: BoxDecoration(
        color: AppColors.surfaceCardLight,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: AppColors.borderLight),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'Local Vision Model (SmolVLM2)',
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w700,
              color: AppColors.textOnLight,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            'Status: ${_modelStatusLabel(_modelStatus)}',
            style: const TextStyle(color: AppColors.textSecondaryOnLight),
          ),
          if (isDownloading) ...[
            const SizedBox(height: AppSpacing.xs),
            LinearProgressIndicator(value: _downloadProgress),
            const SizedBox(height: 4),
            Text(
              _downloadPhase,
              style: const TextStyle(color: AppColors.textSecondaryOnLight),
            ),
            const SizedBox(height: AppSpacing.xs),
            AccessibleButton(
              label: 'Cancel Download',
              hint: 'Stops the SmolVLM2 download',
              onPressed: _cancelDownload,
            ),
          ] else if (_modelStatus == ModelStatus.notDownloaded) ...[
            const SizedBox(height: AppSpacing.xs),
            Text(
              'About 500 MB. Wi-Fi recommended.',
              style: const TextStyle(color: AppColors.textSecondaryOnLight),
            ),
            const SizedBox(height: AppSpacing.xs),
            AccessibleButton(
              label: 'Download SmolVLM2',
              hint:
                  'Downloads the local vision model so Local mode works offline',
              onPressed: _startDownload,
            ),
          ] else if (_modelStatus == ModelStatus.ready ||
              _modelStatus == ModelStatus.loaded) ...[
            const SizedBox(height: AppSpacing.xs),
            AccessibleButton(
              label: 'Delete Downloaded Model',
              hint: 'Removes the local SmolVLM2 files',
              onPressed: _deleteModel,
            ),
          ],
          if (_downloadError != null) ...[
            const SizedBox(height: 4),
            Text(
              'Error: $_downloadError',
              style: const TextStyle(color: Colors.redAccent),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildFoundationModelsRow() {
    return Container(
      padding: const EdgeInsets.all(AppSpacing.sm),
      decoration: BoxDecoration(
        color: AppColors.surfaceCardLight,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: AppColors.borderLight),
      ),
      child: Row(
        children: [
          const Icon(Icons.auto_awesome, color: AppColors.textSecondaryOnLight),
          const SizedBox(width: AppSpacing.xs),
          Expanded(
            child: Text(
              'Foundation Models: ${_foundationModelsLine(_fmReason)}',
              style: const TextStyle(color: AppColors.textOnLight),
            ),
          ),
        ],
      ),
    );
  }
}
