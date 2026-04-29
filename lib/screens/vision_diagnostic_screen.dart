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
        'Foundation Models: ${offline.foundationModelsAvailable ? 'ready' : 'unavailable'}',
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
    } catch (e) {
      lines.add('Native diagnostics failed: $e');
    }

    if (!mounted) return;
    setState(() {
      _report = lines.join('\n');
      _running = false;
    });
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
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: AppColors.surfaceCardLight,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: AppColors.borderLight),
                  ),
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.all(AppSpacing.sm),
                    child: SelectableText(_report),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
