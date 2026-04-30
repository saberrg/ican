import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image/image.dart' as image_codec;
import 'package:image_picker/image_picker.dart';

import '../core/theme.dart';
import '../services/ble_service.dart';
import '../services/on_device_vision_service.dart';
import '../widgets/accessible_button.dart';

class VisionDiagnosticScreen extends StatefulWidget {
  const VisionDiagnosticScreen({
    super.key,
    this.onDeviceService,
    this.pickTestImageBytes,
  });

  final OnDeviceVisionService? onDeviceService;
  final Future<Uint8List?> Function()? pickTestImageBytes;

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
  StreamSubscription<ModelDownloadEvent>? _downloadSub;
  double _downloadProgress = 0;
  String _downloadPhase = '';
  String? _downloadError;
  bool _loading = false;
  bool _pickingPhoto = false;
  Uint8List? _selectedTestImageBytes;
  String? _testImageStatus;

  static final Uint8List _gemmaProbeJpegBytes = Uint8List.fromList(
    base64Decode(
      '/9j/4AAQSkZJRgABAQEAYABgAAD/2wBDAAMCAgMCAgMDAwMEAwMEBQgFBQQEBQoH'
      'BwYIDAoMDAsKCwsNDhIQDQ4RDgsLEBYQERMUFRUVDA8XGBYUGBIUFRT/2wBDAQME'
      'BAUEBQkFBQkUDQsNFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQU'
      'FBQUFBQUFBQUFBQUFBT/wAARCAABAAEDASIAAhEBAxEB/8QAHwAAAQUBAQEBAQE'
      'AAAAAAAAAAAECAwQFBgcICQoL/8QAtRAAAgEDAwIEAwUFBAQAAAF9AQIDAAQRB'
      'RIhMUEGE1FhByJxFDKBkaEII0KxwRVS0fAkM2JyggkKFhcYGRolJicoKSo0NTY3'
      'ODk6Q0RFRkdISUpTVFVWV1hZWmNkZWZnaGlqc3R1dnd4eXqDhIWGh4iJipKTlJW'
      'Wl5iZmqKjpKWmp6ipqrKztLW2t7i5usLDxMXGx8jJytLT1NXW19jZ2uHi4+Tl5u'
      'fo6erx8vP09fb3+Pn6/8QAHwEAAwEBAQEBAQEBAQAAAAAAAAECAwQFBgcICQoL'
      '/8QAtREAAgECBAQDBAcFBAQAAQJ3AAECAxEEBSExBhJBUQdhcRMiMoEIFEKRob'
      'HBCSMzUvAVYnLRChYkNOEl8RcYGRomJygpKjU2Nzg5OkNERUZHSElKU1RVVldYW'
      'VpjZGVmZ2hpanN0dXZ3eHl6goOEhYaHiImKkpOUlZaXmJmaoqOkpaanqKmqsrO0'
      'tba3uLm6wsPExcbHyMnK0tPU1dbX2Nna4uPk5ebn6Onq8vP09fb3+Pn6/9oADA'
      'MBAAIRAxEAPwD9U6KKKAP/2Q==',
    ),
  );

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
      if (!mounted) return;
      setState(() {
        _modelStatus = status;
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
      final nativeModels = await _vision.getOfflineVisionDiagnostics();
      var gemmaLoad = 'skipped';
      GemmaReadinessReport? readinessReport;
      final probeImage = _selectedTestImageBytes ?? _gemmaProbeJpegBytes;
      if (offline.modelStatus == ModelStatus.loaded) {
        gemmaLoad = 'already loaded';
      } else if (offline.modelStatus == ModelStatus.ready) {
        final loaded = await _vision.loadGemmaModel();
        gemmaLoad = loaded ? 'loaded successfully' : 'load failed';
      }
      if (offline.modelStatus == ModelStatus.ready ||
          offline.modelStatus == ModelStatus.loaded) {
        readinessReport = await _vision.runGemmaReadinessProbe(probeImage);
      }
      final readinessSnapshot = await _vision
          .getGemmaReadinessSupportSnapshot();
      lines.addAll([
        'Native channel: ${nativeReady ? 'ready' : 'unavailable'}',
        'Apple Vision: ${appleVision ? 'ready' : 'unavailable'}',
        'Gemma 4 E2B status: ${_modelStatusLabel(offline.modelStatus)}',
        'Gemma 4 E2B load: $gemmaLoad',
        'Gemma probe image: ${_selectedTestImageBytes == null ? 'built-in test JPEG' : 'selected phone photo (${_selectedTestImageBytes!.length} bytes)'}',
        if (readinessReport != null)
          'Gemma 4 E2B readiness probe: ${readinessReport.passed ? 'passed' : 'failed'}',
        if (readinessReport != null && !readinessReport.passed)
          'Gemma 4 E2B failure reason: ${readinessReport.failureReason}',
        'Best local backend: ${offline.bestLocalBackendLabel}',
        'YOLOv3 Tiny: ${offline.objectDetectionAvailable ? 'ready' : 'unavailable'}',
        'Depth Anything: ${offline.depthEstimationAvailable ? 'ready' : 'unavailable'}',
        'YOLO detail: ${nativeModels.objectDetector.message}',
        'Depth detail: ${nativeModels.depthEstimator.message}',
        'Gemma 4 E2B readiness snapshot:',
        readinessSnapshot,
      ]);
      if (mounted) {
        setState(() {
          _modelStatus = offline.modelStatus;
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

  Future<void> _loadModelNow() async {
    setState(() => _loading = true);
    var loaded = false;
    try {
      loaded = await _vision.loadGemmaModel();
    } catch (_) {
      // loadGemmaModel already handles its own errors and returns false.
    }
    if (!mounted) return;
    setState(() {
      _loading = false;
      _downloadPhase = loaded
          ? 'Gemma 4 E2B loaded.'
          : 'Gemma 4 E2B load failed. Run Diagnostics for details.';
    });
    await _refreshQuickStatus();
  }

  Future<void> _pickTestPhoto() async {
    if (_pickingPhoto) return;
    setState(() {
      _pickingPhoto = true;
      _testImageStatus = 'Opening photo library...';
    });

    try {
      final bytes = await (widget.pickTestImageBytes ?? _pickGalleryJpeg)();
      if (!mounted) return;
      if (bytes == null) {
        setState(() {
          _pickingPhoto = false;
          _testImageStatus = 'No test photo selected.';
        });
        return;
      }
      setState(() {
        _pickingPhoto = false;
        _selectedTestImageBytes = bytes;
        _testImageStatus = 'Selected phone photo (${bytes.length} bytes).';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _pickingPhoto = false;
        _testImageStatus = 'Photo selection failed: $e';
      });
    }
  }

  Future<Uint8List?> _pickGalleryJpeg() async {
    final picked = await ImagePicker().pickImage(
      source: ImageSource.gallery,
      imageQuality: 92,
    );
    if (picked == null) return null;

    final bytes = await picked.readAsBytes();
    if (isLikelyValidJpeg(bytes)) return bytes;

    final decoded = image_codec.decodeImage(bytes);
    if (decoded == null) {
      throw const FormatException('Selected image could not be decoded.');
    }
    return Uint8List.fromList(image_codec.encodeJpg(decoded, quality: 92));
  }

  Future<void> _retryReadiness() async {
    OnDeviceVisionService.clearReadinessFailureCache();
    await _runDiagnostics();
  }

  Future<void> _deleteModel() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete Gemma 4 E2B?'),
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
            'Local Vision Model (Gemma 4 E2B)',
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
          const SizedBox(height: AppSpacing.xs),
          AccessibleButton(
            label: _pickingPhoto ? 'Opening Photos...' : 'Pick Test Photo',
            hint:
                'Selects a phone photo for Gemma diagnostics without using the Eye camera',
            onPressed: _pickingPhoto ? null : _pickTestPhoto,
          ),
          if (_testImageStatus != null) ...[
            const SizedBox(height: 4),
            Text(
              _testImageStatus!,
              style: const TextStyle(color: AppColors.textSecondaryOnLight),
            ),
          ],
          if (!isDownloading && _downloadPhase.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(
              _downloadPhase,
              style: const TextStyle(color: AppColors.textSecondaryOnLight),
            ),
          ],
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
              hint: 'Stops the Gemma 4 E2B download',
              onPressed: _cancelDownload,
            ),
          ] else if (_modelStatus == ModelStatus.notDownloaded) ...[
            const SizedBox(height: AppSpacing.xs),
            Text(
              'About 2.6 GB. Wi-Fi recommended.',
              style: const TextStyle(color: AppColors.textSecondaryOnLight),
            ),
            const SizedBox(height: AppSpacing.xs),
            AccessibleButton(
              label: 'Download Gemma 4 E2B',
              hint:
                  'Downloads the local vision model so Local mode works offline',
              onPressed: _startDownload,
            ),
          ] else if (_modelStatus == ModelStatus.ready) ...[
            const SizedBox(height: AppSpacing.xs),
            AccessibleButton(
              label: _loading
                  ? 'Loading Gemma 4 E2B...'
                  : 'Load Gemma 4 E2B now',
              hint:
                  'Loads the downloaded model into memory so Local mode can use it',
              onPressed: _loading ? null : _loadModelNow,
            ),
            const SizedBox(height: AppSpacing.xs),
            AccessibleButton(
              label: 'Retry readiness probe',
              hint:
                  'Clears the cached readiness failure and re-runs diagnostics',
              onPressed: _retryReadiness,
            ),
            const SizedBox(height: AppSpacing.xs),
            AccessibleButton(
              label: 'Delete Downloaded Model',
              hint: 'Removes the local Gemma 4 E2B files',
              onPressed: _deleteModel,
            ),
          ] else if (_modelStatus == ModelStatus.loaded) ...[
            const SizedBox(height: AppSpacing.xs),
            AccessibleButton(
              label: 'Retry readiness probe',
              hint:
                  'Clears the cached readiness failure and re-runs diagnostics',
              onPressed: _retryReadiness,
            ),
            const SizedBox(height: AppSpacing.xs),
            AccessibleButton(
              label: 'Delete Downloaded Model',
              hint: 'Removes the local Gemma 4 E2B files',
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
}
