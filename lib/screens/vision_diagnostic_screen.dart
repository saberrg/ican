import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:image_picker/image_picker.dart';

import '../core/theme.dart';
import '../services/app_log_service.dart';
import '../services/ble_service.dart';
import '../services/on_device_vision_service.dart';
import '../services/scene_description_service.dart';
import '../services/vertex_ai_service.dart';

enum _DiagBackend {
  cloud('Cloud Gemini'),
  foundationModels('Apple Foundation Models'),
  smolVLM('SmolVLM2 llama.cpp'),
  visionTemplate('Vision-only template');

  const _DiagBackend(this.label);
  final String label;
}

class VisionDiagnosticScreen extends StatefulWidget {
  const VisionDiagnosticScreen({
    super.key,
    this.onDeviceService,
    this.sceneService,
    this.initialImageBytes,
    this.initialImageSource,
  });

  final OnDeviceVisionService? onDeviceService;
  final SceneDescriptionService? sceneService;
  final Uint8List? initialImageBytes;
  final String? initialImageSource;

  @override
  State<VisionDiagnosticScreen> createState() => _VisionDiagnosticScreenState();
}

class _VisionDiagnosticScreenState extends State<VisionDiagnosticScreen> {
  final ImagePicker _picker = ImagePicker();
  late final SceneDescriptionService _sceneService;
  late final OnDeviceVisionService _onDeviceService;

  Uint8List? _imageBytes;
  String _imageSource = '';
  _DiagBackend _selectedBackend = _DiagBackend.cloud;

  bool _isRunning = false;
  String _outputText = '';
  String _errorText = '';
  String _activeDiagnosticLabel = 'Not run';
  int? _timeToFirstTokenMs;
  int? _totalTimeMs;

  StreamSubscription<Uint8List>? _bleSub;
  StreamSubscription<ModelDownloadEvent>? _downloadSub;
  Uint8List? _lastBleImage;
  SmolVlmModelInfo? _smolVlmInfo;
  ModelStatus? _smolVlmStatus;
  double _smolVlmProgress = 0;
  bool _isDownloadingModel = false;
  bool _isLoadingModel = false;
  String _modelSetupMessage = '';

  @override
  void initState() {
    super.initState();
    _onDeviceService = widget.onDeviceService ?? OnDeviceVisionService();
    final injectedSceneService = widget.sceneService;
    if (injectedSceneService != null) {
      _sceneService = injectedSceneService;
    } else {
      final aiService = VertexAiService()..loadSavedModel();
      _sceneService = SceneDescriptionService(
        cloudService: aiService,
        onDeviceService: _onDeviceService,
      )..loadSavedMode();
    }
    _imageBytes = widget.initialImageBytes;
    _imageSource = widget.initialImageSource ?? '';

    _bleSub = BleService.instance.imageStream.listen((bytes) {
      _lastBleImage = bytes;
    });
    unawaited(_refreshSmolVlmInfo());
  }

  @override
  void dispose() {
    _bleSub?.cancel();
    _downloadSub?.cancel();
    super.dispose();
  }

  Future<void> _refreshSmolVlmInfo() async {
    final status = await _onDeviceService.getModelStatus();
    final info = await _onDeviceService.getSmolVlmModelInfo();
    if (!mounted) return;
    setState(() {
      _smolVlmStatus = status;
      _smolVlmInfo = info;
      _smolVlmProgress = info.progress;
      _isDownloadingModel = status == ModelStatus.downloading;
    });
  }

  Future<void> _downloadSmolVlm() async {
    if (_isDownloadingModel) return;
    await _downloadSub?.cancel();
    setState(() {
      _isDownloadingModel = true;
      _smolVlmProgress = 0;
      _modelSetupMessage = 'Starting model download...';
    });

    _downloadSub = _onDeviceService.startModelDownload().listen(
      (event) {
        if (!mounted) return;
        setState(() {
          _smolVlmProgress = event.progress;
          _modelSetupMessage = _modelDownloadMessage(event);
        });
        if (event.isComplete) {
          unawaited(_refreshSmolVlmInfo());
        }
      },
      onError: (Object error) {
        if (!mounted) return;
        setState(() {
          _isDownloadingModel = false;
          _modelSetupMessage = 'Download failed: $error';
        });
      },
      onDone: () {
        if (!mounted) return;
        setState(() {
          _isDownloadingModel = false;
        });
        unawaited(_refreshSmolVlmInfo());
      },
    );
  }

  Future<void> _loadSmolVlm() async {
    if (_isLoadingModel) return;
    setState(() {
      _isLoadingModel = true;
      _modelSetupMessage = 'Loading SmolVLM2 into memory...';
    });

    final loaded = await _onDeviceService.loadVlmModel();
    final status = await _onDeviceService.getModelStatus();
    if (!mounted) return;
    setState(() {
      _isLoadingModel = false;
      _smolVlmStatus = status;
      _modelSetupMessage = loaded
          ? 'SmolVLM2 loaded. Pick an image and run the SmolVLM2 backend.'
          : 'SmolVLM2 failed to load. Check free memory and model integrity.';
    });
    unawaited(_refreshSmolVlmInfo());
  }

  String _modelDownloadMessage(ModelDownloadEvent event) {
    if (event.isComplete) return 'Download verified.';
    final percent = (event.progress * 100).clamp(0, 100).round();
    final file = event.fileName == null ? '' : ' ${event.fileName}';
    return 'Downloading$file: $percent%';
  }

  Future<void> _pickFromGallery() async {
    final file = await _picker.pickImage(source: ImageSource.gallery);
    if (file == null) return;
    final bytes = await file.readAsBytes();
    setState(() {
      _imageBytes = Uint8List.fromList(bytes);
      _imageSource = 'Gallery: ${file.name}';
      _clearResults();
    });
  }

  void _useLastBleImage() {
    if (_lastBleImage == null) return;
    setState(() {
      _imageBytes = _lastBleImage;
      _imageSource = 'Last BLE image (${_lastBleImage!.length} bytes)';
      _clearResults();
    });
  }

  void _clearResults() {
    _outputText = '';
    _errorText = '';
    _timeToFirstTokenMs = null;
    _totalTimeMs = null;
  }

  Future<void> _runTextDiagnostic(
    String label,
    Future<String> Function() action, {
    bool requiresImage = false,
  }) async {
    if (_isRunning || (requiresImage && _imageBytes == null)) return;

    setState(() {
      _isRunning = true;
      _activeDiagnosticLabel = label;
      _clearResults();
    });

    final stopwatch = Stopwatch()..start();
    try {
      final text = await action();
      stopwatch.stop();
      setState(() {
        _outputText = text;
        _totalTimeMs = stopwatch.elapsedMilliseconds;
        _isRunning = false;
      });
    } catch (e) {
      stopwatch.stop();
      setState(() {
        _errorText = e.toString();
        _totalTimeMs = stopwatch.elapsedMilliseconds;
        _isRunning = false;
      });
    }
  }

  Future<void> _runStreamingDiagnostic(
    String label,
    Future<Stream<String>> Function() streamBuilder, {
    bool requiresImage = true,
  }) async {
    if (_isRunning || (requiresImage && _imageBytes == null)) return;

    setState(() {
      _isRunning = true;
      _activeDiagnosticLabel = label;
      _clearResults();
    });

    final stopwatch = Stopwatch()..start();
    bool gotFirstToken = false;
    final buffer = StringBuffer();

    try {
      final stream = await streamBuilder();
      await for (final chunk in stream) {
        if (!gotFirstToken) {
          gotFirstToken = true;
          setState(() {
            _timeToFirstTokenMs = stopwatch.elapsedMilliseconds;
          });
        }
        buffer.write(chunk);
        setState(() {
          _outputText = buffer.toString();
        });
      }
    } catch (e) {
      setState(() {
        _errorText = e.toString();
      });
    }

    stopwatch.stop();
    setState(() {
      _totalTimeMs = stopwatch.elapsedMilliseconds;
      _outputText = buffer.toString();
      if (_outputText.isEmpty && _errorText.isEmpty) {
        _errorText = '$label produced no output.';
      }
      _isRunning = false;
    });
  }

  Future<String> _buildLocalStackDiagnostic() async {
    final status = await _onDeviceService.getOfflineVisionStatus();
    final diagnostics = await _onDeviceService.getOfflineVisionDiagnostics();
    final info = await _onDeviceService.getSmolVlmModelInfo();

    final buffer = StringBuffer()
      ..writeln('Local Stack')
      ..writeln('Foundation Models: ${status.foundationModelsAvailable}')
      ..writeln('SmolVLM2 status: ${_modelStatusLabel(status.modelStatus)}')
      ..writeln('Object detection: ${status.objectDetectionAvailable}')
      ..writeln('Depth estimation: ${status.depthEstimationAvailable}')
      ..writeln('Best local backend: ${status.bestLocalBackendLabel}')
      ..writeln(
        'Missing requirements: ${status.missingRequirements.isEmpty ? "none" : status.missingRequirements.join(", ")}',
      )
      ..writeln()
      ..writeln('Core ML Models')
      ..writeln(_nativeModelLine(diagnostics.objectDetector))
      ..writeln(_nativeModelLine(diagnostics.depthEstimator))
      ..writeln()
      ..writeln('SmolVLM2 Files')
      ..writeln('Directory: ${info.path.isEmpty ? "(unknown)" : info.path}')
      ..writeln('Downloaded: ${info.downloaded}')
      ..writeln('Valid: ${info.valid}')
      ..writeln('Bytes: ${info.sizeBytes} / ${info.requiredBytes}');

    for (final file in info.files) {
      buffer
        ..writeln()
        ..writeln(file.name)
        ..writeln('  present: ${file.downloaded}')
        ..writeln('  sizeBytes: ${file.sizeBytes}')
        ..writeln('  expectedSizeBytes: ${file.expectedSizeBytes}')
        ..writeln('  sha256: ${file.sha256}');
    }

    return buffer.toString().trim();
  }

  String _nativeModelLine(NativeModelDiagnostic diagnostic) {
    return '${diagnostic.name}: loaded=${diagnostic.loaded}, bundle=${diagnostic.bundleFound}, compiled=${diagnostic.compiledModelFound}. ${diagnostic.message}';
  }

  Future<String> _runLayer1OnlyText() async {
    final perception = await _onDeviceService.analyzeScene(_imageBytes!);
    return [
      'Layer 1 Perception',
      'OCR: ${perception.ocrTexts.isEmpty ? "(none)" : perception.ocrTexts.join(" | ")}',
      'Scene: ${perception.sceneClassification} (${(perception.sceneConfidence * 100).round()}%)',
      'People: ${perception.personCount}',
      'Depth map: ${perception.hasDepthMap}',
      'Objects: ${perception.detectedObjects.map((o) => o.spatialLabel).join("; ")}',
      '',
      'Template',
      perception.toTemplateDescription(),
      '',
      'Prompt Context',
      perception.toPromptContext().isEmpty
          ? '(empty)'
          : perception.toPromptContext(),
    ].join('\n');
  }

  Future<Stream<String>> _buildSmolVlmDirectStream() async {
    await _ensureSmolVlmLoadedForDiagnostic();
    return _onDeviceService.describeWithVlm(
      _imageBytes!,
      systemPrompt:
          'Describe this image in 4-6 concise spoken sentences. Include hazards, text, and spatial positions.',
    );
  }

  Future<Stream<String>> _buildFullLocalPipelineStream() async {
    await _ensureSmolVlmLoadedForDiagnostic();
    return _sceneService.describeWithSmolVLM(
      _imageBytes!,
      systemPrompt:
          'Describe this image in 4-6 concise spoken sentences. Include hazards, text, and spatial positions.',
    );
  }

  Future<void> _ensureSmolVlmLoadedForDiagnostic() async {
    final status = await _onDeviceService.getModelStatus();
    switch (status) {
      case ModelStatus.loaded:
        return;
      case ModelStatus.ready:
        final loaded = await _onDeviceService.loadVlmModel();
        if (loaded) return;
        throw StateError('SmolVLM2 files are present but loadModel failed.');
      case ModelStatus.downloading:
        throw StateError('SmolVLM2 model download is still in progress.');
      case ModelStatus.notAvailable:
        throw StateError('SmolVLM2 runtime is not linked into this build.');
      case ModelStatus.notDownloaded:
        throw StateError('SmolVLM2 model files are not downloaded.');
    }
  }

  Future<String> _runSmolVlmSelfTestText() async {
    final result = await _onDeviceService.runSmolVlmSelfTest(_imageBytes!);
    return _formatDiagnosticMap(result);
  }

  String _formatDiagnosticMap(Map<String, dynamic> map) {
    final buffer = StringBuffer()..writeln('SmolVLM2 Self-Test');
    _writeDiagnosticMap(buffer, map);
    return buffer.toString().trim();
  }

  void _writeDiagnosticMap(
    StringBuffer buffer,
    Map<String, dynamic> map, {
    int indent = 0,
  }) {
    final prefix = ' ' * indent;
    for (final entry in map.entries) {
      final value = entry.value;
      if (value is Map<String, dynamic>) {
        buffer.writeln('$prefix${entry.key}:');
        _writeDiagnosticMap(buffer, value, indent: indent + 2);
      } else if (value is List) {
        buffer.writeln('$prefix${entry.key}:');
        for (final item in value) {
          if (item is Map<String, dynamic>) {
            _writeDiagnosticMap(buffer, item, indent: indent + 2);
          } else {
            buffer.writeln('$prefix  $item');
          }
        }
      } else {
        buffer.writeln('$prefix${entry.key}: $value');
      }
    }
  }

  Future<void> _runDiagnostic() async {
    if (_imageBytes == null || _isRunning) return;

    setState(() {
      _isRunning = true;
      _activeDiagnosticLabel = _selectedBackend.label;
      _clearResults();
    });

    const systemPrompt =
        'You are the vision system for a blind person wearing a chest camera. '
        'Describe the scene in 4–6 sentences. Be specific and spatial.';

    final stopwatch = Stopwatch()..start();
    bool gotFirstToken = false;
    final buffer = StringBuffer();

    try {
      final Stream<String> stream;
      switch (_selectedBackend) {
        case _DiagBackend.cloud:
          stream = _sceneService.describeWithGemini(
            _imageBytes!,
            systemPrompt: systemPrompt,
          );
        case _DiagBackend.foundationModels:
          stream = _sceneService.describeWithFoundationModels(
            _imageBytes!,
            systemPrompt: systemPrompt,
          );
        case _DiagBackend.smolVLM:
          stream = _sceneService.describeWithSmolVLM(
            _imageBytes!,
            systemPrompt: systemPrompt,
          );
        case _DiagBackend.visionTemplate:
          stream = _sceneService.describeWithVisionTemplate(_imageBytes!);
      }

      await for (final chunk in stream) {
        if (!gotFirstToken) {
          gotFirstToken = true;
          setState(() {
            _timeToFirstTokenMs = stopwatch.elapsedMilliseconds;
          });
        }
        buffer.write(chunk);
        setState(() {
          _outputText = buffer.toString();
        });
      }
    } catch (e) {
      setState(() {
        _errorText = e.toString();
      });
    }

    stopwatch.stop();
    setState(() {
      _totalTimeMs = stopwatch.elapsedMilliseconds;
      _outputText = buffer.toString();
      if (_outputText.isEmpty && _errorText.isEmpty) {
        _errorText = 'Backend produced no output.';
      }
      _isRunning = false;
    });
  }

  void _copyResult() {
    final text = StringBuffer()
      ..writeln('Diagnostic: $_activeDiagnosticLabel')
      ..writeln('Image: $_imageSource')
      ..writeln('Time to first token: ${_timeToFirstTokenMs ?? "--"} ms')
      ..writeln('Total time: ${_totalTimeMs ?? "--"} ms')
      ..writeln()
      ..writeln(_outputText.isNotEmpty ? _outputText : '(no output)')
      ..writeln()
      ..writeln(_errorText.isNotEmpty ? 'Error: $_errorText' : '');

    Clipboard.setData(ClipboardData(text: text.toString().trim()));
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Copied to clipboard'),
        duration: Duration(seconds: 2),
      ),
    );
  }

  Future<void> _copyAppLogs() async {
    final logs = await AppLogService.instance.exportText();
    if (!mounted) return;
    final text = logs.trim().isEmpty ? 'No app logs recorded.' : logs;
    await Clipboard.setData(ClipboardData(text: text));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Copied app logs'),
        duration: Duration(seconds: 2),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.backgroundLight,
      appBar: AppBar(
        title: Text(
          'Vision Diagnostic',
          style: TextStyle(fontSize: 22.sp, fontWeight: FontWeight.bold),
        ),
        centerTitle: true,
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(AppSpacing.sm),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _buildImageSection(),
              const SizedBox(height: AppSpacing.md),
              _buildBackendSelector(),
              const SizedBox(height: AppSpacing.md),
              _buildSmolVlmSetupSection(),
              const SizedBox(height: AppSpacing.md),
              _buildLayerTestSection(),
              const SizedBox(height: AppSpacing.md),
              _buildRunButton(),
              const SizedBox(height: AppSpacing.md),
              _buildResultsSection(),
              const SizedBox(height: AppSpacing.lg),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildImageSection() {
    return Container(
      padding: const EdgeInsets.all(AppSpacing.sm),
      decoration: BoxDecoration(
        color: AppColors.surfaceCardLight,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.borderLight),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Test Image',
            style: TextStyle(
              fontSize: 18.sp,
              fontWeight: FontWeight.w600,
              color: AppColors.textOnLight,
            ),
          ),
          const SizedBox(height: AppSpacing.xs),
          if (_imageBytes != null) ...[
            ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: Image.memory(
                _imageBytes!,
                height: 180,
                width: double.infinity,
                fit: BoxFit.cover,
                errorBuilder: (_, __, ___) => Container(
                  height: 180,
                  color: AppColors.borderLight,
                  child: const Center(child: Text('Cannot preview image')),
                ),
              ),
            ),
            const SizedBox(height: 4),
            Text(
              _imageSource,
              style: TextStyle(
                fontSize: 13.sp,
                color: AppColors.textSecondaryOnLight,
              ),
            ),
            const SizedBox(height: AppSpacing.xs),
          ],
          Row(
            children: [
              Expanded(
                child: _DiagButton(
                  label: 'Pick from Gallery',
                  onPressed: _isRunning ? null : _pickFromGallery,
                ),
              ),
              const SizedBox(width: AppSpacing.xs),
              Expanded(
                child: _DiagButton(
                  label: 'Use Last BLE Image',
                  onPressed: (_lastBleImage == null || _isRunning)
                      ? null
                      : _useLastBleImage,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildBackendSelector() {
    return Container(
      padding: const EdgeInsets.all(AppSpacing.sm),
      decoration: BoxDecoration(
        color: AppColors.surfaceCardLight,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.borderLight),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Backend',
            style: TextStyle(
              fontSize: 18.sp,
              fontWeight: FontWeight.w600,
              color: AppColors.textOnLight,
            ),
          ),
          const SizedBox(height: AppSpacing.xs),
          DropdownButtonFormField<_DiagBackend>(
            value: _selectedBackend,
            isExpanded: true,
            decoration: InputDecoration(
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 12,
                vertical: 10,
              ),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(8),
                borderSide: const BorderSide(color: AppColors.borderLight),
              ),
            ),
            items: _DiagBackend.values
                .map(
                  (b) => DropdownMenuItem(
                    value: b,
                    child: Text(b.label, style: TextStyle(fontSize: 16.sp)),
                  ),
                )
                .toList(),
            onChanged: _isRunning
                ? null
                : (value) {
                    if (value != null) setState(() => _selectedBackend = value);
                  },
          ),
        ],
      ),
    );
  }

  Widget _buildSmolVlmSetupSection() {
    final info = _smolVlmInfo;
    final status = _smolVlmStatus;
    final downloaded = info?.downloaded ?? false;
    final loaded = status == ModelStatus.loaded;
    final canDownload = !_isDownloadingModel && !downloaded && !_isRunning;
    final canLoad = !_isLoadingModel && downloaded && !loaded && !_isRunning;
    final requiredBytes = info?.requiredBytes ?? 545592752;

    return Container(
      padding: const EdgeInsets.all(AppSpacing.sm),
      decoration: BoxDecoration(
        color: AppColors.surfaceCardLight,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.borderLight),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  'SmolVLM2 Setup',
                  style: TextStyle(
                    fontSize: 18.sp,
                    fontWeight: FontWeight.w600,
                    color: AppColors.textOnLight,
                  ),
                ),
              ),
              _DiagButton(
                label: 'Refresh',
                onPressed: _isRunning ? null : _refreshSmolVlmInfo,
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.xs),
          _ResultRow(label: 'Status', value: _modelStatusLabel(status)),
          _ResultRow(
            label: 'Files',
            value: downloaded
                ? 'Verified'
                : '${_formatBytes(info?.sizeBytes ?? 0)} of ${_formatBytes(requiredBytes)}',
          ),
          if (info?.path.isNotEmpty ?? false)
            _ResultRow(label: 'Path', value: info!.path),
          if (info != null)
            for (final file in info.files)
              _ResultRow(
                label: file.name.contains('mmproj') ? 'Projector' : 'Model',
                value:
                    '${file.name} at ${info.path}/${file.name} (${_formatBytes(file.sizeBytes)} of ${_formatBytes(file.expectedSizeBytes)})',
              ),
          const SizedBox(height: AppSpacing.xs),
          LinearProgressIndicator(
            value: downloaded || loaded ? 1 : _smolVlmProgress,
            minHeight: 8,
            backgroundColor: AppColors.borderLight,
          ),
          const SizedBox(height: AppSpacing.xs),
          Wrap(
            spacing: AppSpacing.xs,
            runSpacing: AppSpacing.xs,
            children: [
              _DiagButton(
                label: _isDownloadingModel ? 'Downloading...' : 'Download',
                onPressed: canDownload ? _downloadSmolVlm : null,
              ),
              _DiagButton(
                label: _isLoadingModel ? 'Loading...' : 'Load',
                onPressed: canLoad ? _loadSmolVlm : null,
              ),
            ],
          ),
          if (_modelSetupMessage.isNotEmpty) ...[
            const SizedBox(height: AppSpacing.xs),
            Text(
              _modelSetupMessage,
              style: TextStyle(
                fontSize: 14.sp,
                color: AppColors.textSecondaryOnLight,
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildLayerTestSection() {
    final hasImage = _imageBytes != null;
    return Container(
      padding: const EdgeInsets.all(AppSpacing.sm),
      decoration: BoxDecoration(
        color: AppColors.surfaceCardLight,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.borderLight),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Layer Tests',
            style: TextStyle(
              fontSize: 18.sp,
              fontWeight: FontWeight.w600,
              color: AppColors.textOnLight,
            ),
          ),
          const SizedBox(height: AppSpacing.xs),
          Wrap(
            spacing: AppSpacing.xs,
            runSpacing: AppSpacing.xs,
            children: [
              _DiagButton(
                label: 'Check Local Stack',
                onPressed: _isRunning
                    ? null
                    : () => _runTextDiagnostic(
                        'Check Local Stack',
                        _buildLocalStackDiagnostic,
                      ),
              ),
              _DiagButton(
                label: 'Copy App Logs',
                onPressed: _isRunning ? null : _copyAppLogs,
              ),
              _DiagButton(
                label: 'Run SmolVLM2 Self-Test',
                onPressed: (_isRunning || !hasImage)
                    ? null
                    : () => _runTextDiagnostic(
                        'Run SmolVLM2 Self-Test',
                        _runSmolVlmSelfTestText,
                        requiresImage: true,
                      ),
              ),
              _DiagButton(
                label: 'Run Layer 1 Only',
                onPressed: (_isRunning || !hasImage)
                    ? null
                    : () => _runTextDiagnostic(
                        'Run Layer 1 Only',
                        _runLayer1OnlyText,
                        requiresImage: true,
                      ),
              ),
              _DiagButton(
                label: 'Run SmolVLM2 Direct',
                onPressed: (_isRunning || !hasImage)
                    ? null
                    : () => _runStreamingDiagnostic(
                        'Run SmolVLM2 Direct',
                        _buildSmolVlmDirectStream,
                      ),
              ),
              _DiagButton(
                label: 'Run Full Local Pipeline',
                onPressed: (_isRunning || !hasImage)
                    ? null
                    : () => _runStreamingDiagnostic(
                        'Run Full Local Pipeline',
                        _buildFullLocalPipelineStream,
                      ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  String _modelStatusLabel(ModelStatus? status) {
    return switch (status) {
      ModelStatus.loaded => 'Loaded',
      ModelStatus.ready => 'Downloaded',
      ModelStatus.downloading => 'Downloading',
      ModelStatus.notAvailable => 'Runtime unavailable',
      ModelStatus.notDownloaded => 'Not downloaded',
      null => 'Checking',
    };
  }

  String _formatBytes(int bytes) {
    if (bytes <= 0) return '0 MB';
    final mb = bytes / (1024 * 1024);
    if (mb >= 1024) return '${(mb / 1024).toStringAsFixed(1)} GB';
    return '${mb.round()} MB';
  }

  Widget _buildRunButton() {
    final canRun = _imageBytes != null && !_isRunning;
    return SizedBox(
      height: 56,
      child: ElevatedButton(
        onPressed: canRun ? _runDiagnostic : null,
        child: _isRunning
            ? Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: AppColors.textOnDark,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Text('Running ${_selectedBackend.label}…'),
                ],
              )
            : const Text('Run Description'),
      ),
    );
  }

  Widget _buildResultsSection() {
    return Container(
      padding: const EdgeInsets.all(AppSpacing.sm),
      decoration: BoxDecoration(
        color: AppColors.surfaceCardLight,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.borderLight),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  'Results',
                  style: TextStyle(
                    fontSize: 18.sp,
                    fontWeight: FontWeight.w600,
                    color: AppColors.textOnLight,
                  ),
                ),
              ),
              if (_outputText.isNotEmpty || _errorText.isNotEmpty)
                _DiagButton(label: 'Copy Result', onPressed: _copyResult),
            ],
          ),
          const SizedBox(height: AppSpacing.xs),

          _ResultRow(label: 'Diagnostic', value: _activeDiagnosticLabel),
          _ResultRow(
            label: 'First token',
            value: _timeToFirstTokenMs != null
                ? '$_timeToFirstTokenMs ms'
                : '--',
          ),
          _ResultRow(
            label: 'Total time',
            value: _totalTimeMs != null ? '$_totalTimeMs ms' : '--',
          ),

          const Divider(height: 24, color: AppColors.borderLight),

          if (_errorText.isNotEmpty)
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: const Color(0xFFFFF0F0),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: AppColors.error),
              ),
              child: Text(
                _errorText,
                style: TextStyle(
                  fontSize: 14.sp,
                  color: AppColors.error,
                  height: 1.4,
                ),
              ),
            ),

          if (_outputText.isNotEmpty) ...[
            if (_errorText.isNotEmpty) const SizedBox(height: AppSpacing.xs),
            SelectableText(
              _outputText,
              style: TextStyle(
                fontSize: 16.sp,
                color: AppColors.textOnLight,
                height: 1.5,
              ),
            ),
          ],

          if (_outputText.isEmpty && _errorText.isEmpty)
            Text(
              'Run a backend to see results.',
              style: TextStyle(
                fontSize: 16.sp,
                color: AppColors.disabledOnLight,
                fontStyle: FontStyle.italic,
              ),
            ),
        ],
      ),
    );
  }
}

class _ResultRow extends StatelessWidget {
  final String label;
  final String value;

  const _ResultRow({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        children: [
          SizedBox(
            width: 100,
            child: Text(
              label,
              style: TextStyle(
                fontSize: 14.sp,
                color: AppColors.textSecondaryOnLight,
              ),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: TextStyle(
                fontSize: 14.sp,
                fontWeight: FontWeight.w600,
                color: AppColors.textOnLight,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _DiagButton extends StatelessWidget {
  final String label;
  final VoidCallback? onPressed;

  const _DiagButton({required this.label, this.onPressed});

  @override
  Widget build(BuildContext context) {
    final enabled = onPressed != null;
    return GestureDetector(
      onTap: onPressed,
      child: Container(
        constraints: const BoxConstraints(minHeight: 44),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: enabled ? AppColors.interactive : AppColors.borderLight,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Center(
          child: Text(
            label,
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 14.sp,
              fontWeight: FontWeight.w600,
              color: enabled ? AppColors.textOnDark : AppColors.disabledOnLight,
            ),
          ),
        ),
      ),
    );
  }
}
