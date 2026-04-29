import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'app_log_service.dart';

class LocalVisionException implements Exception {
  const LocalVisionException(this.code, this.message, {this.detail});

  final String code;
  final String message;
  final String? detail;

  String get userMessage {
    final suffix = detail == null || detail!.isEmpty ? '' : ' $detail';
    return '$code: $message$suffix';
  }

  @override
  String toString() => userMessage;
}

// ─────────────────────────────────────────────────────────────────────────────
// Data models
// ─────────────────────────────────────────────────────────────────────────────

/// Results from Apple Vision framework analysis (legacy — still used by VLM path).
class VisionAnalysis {
  const VisionAnalysis({
    required this.ocrTexts,
    required this.sceneClassification,
    required this.sceneConfidence,
    required this.personCount,
    required this.personRects,
  });

  factory VisionAnalysis.fromMap(Map<dynamic, dynamic> map) {
    return VisionAnalysis(
      ocrTexts: _asStringList(map['ocr_texts']),
      sceneClassification: _asNonEmptyString(
        map['scene_classification'],
        fallback: 'unknown',
      ),
      sceneConfidence: _asDouble(map['scene_confidence']),
      personCount: _asInt(map['person_count']),
      personRects: _asRectList(map['person_rects']),
    );
  }

  final List<String> ocrTexts;
  final String sceneClassification;
  final double sceneConfidence;
  final int personCount;
  final List<Map<String, double>> personRects;

  /// Build a human-readable context string for injecting into the VLM prompt.
  String toPromptContext() {
    final parts = <String>[];

    if (sceneClassification != 'unknown' && sceneConfidence > 0.15) {
      final label = sceneClassification.replaceAll('_', ' ');
      final pct = (sceneConfidence * 100).round();
      parts.add('- Scene type: $label ($pct% confidence)');
    }

    if (personCount > 0) {
      parts.add('- People detected: $personCount');
    }

    if (ocrTexts.isNotEmpty) {
      final quoted = ocrTexts.map((t) => '"$t"').join(', ');
      parts.add('- Text visible: $quoted');
    }

    if (parts.isEmpty) return '';
    return 'Context from device sensors:\n${parts.join('\n')}';
  }
}

/// A spatially-located object from Layer 1 (YOLOv3 + Depth Anything V2 fusion).
class SpatialObjectData {
  const SpatialObjectData({
    required this.label,
    required this.confidence,
    required this.clockPosition,
    this.relativeDepth,
    required this.centerX,
    required this.centerY,
    this.bboxX,
    this.bboxY,
    this.bboxW,
    this.bboxH,
  });

  factory SpatialObjectData.fromMap(Map<dynamic, dynamic> map) {
    return SpatialObjectData(
      label: _asNonEmptyString(map['label'], fallback: 'object'),
      confidence: _asDouble(map['confidence']),
      clockPosition: _asInt(map['clock_position'], fallback: 12),
      relativeDepth: _asNullableDouble(map['relative_depth']),
      centerX: _asDouble(map['center_x'], fallback: 0.5),
      centerY: _asDouble(map['center_y'], fallback: 0.5),
      bboxX: _asNullableDouble(map['bbox_x']),
      bboxY: _asNullableDouble(map['bbox_y']),
      bboxW: _asNullableDouble(map['bbox_w']),
      bboxH: _asNullableDouble(map['bbox_h']),
    );
  }

  final String label;
  final double confidence;
  final int clockPosition; // 9=left, 12=center, 3=right
  final double?
  relativeDepth; // 0.0=closest, 1.0=farthest; null if depth unavailable
  final double centerX;
  final double centerY;
  final double?
  bboxX; // image-space bounding box (top-left origin, normalised 0–1)
  final double? bboxY;
  final double? bboxW;
  final double? bboxH;

  String? get distanceTier {
    final d = relativeDepth;
    if (d == null) return null;
    if (d < 0.30) return 'very close';
    if (d < 0.50) return 'close';
    if (d < 0.70) return 'ahead';
    return 'far';
  }

  String get spatialLabel {
    final tier = distanceTier;
    return tier != null
        ? '$label at $clockPosition o\'clock, $tier'
        : '$label at $clockPosition o\'clock';
  }
}

/// Full output from Layer 1 — Vision + Depth Anything V2 + YOLOv3 fused.
class ScenePerceptionResult extends VisionAnalysis {
  const ScenePerceptionResult({
    required super.ocrTexts,
    required super.sceneClassification,
    required super.sceneConfidence,
    required super.personCount,
    required super.personRects,
    required this.detectedObjects,
    required this.hasDepthMap,
  });

  factory ScenePerceptionResult.fromMap(Map<dynamic, dynamic> map) {
    return ScenePerceptionResult(
      ocrTexts: _asStringList(map['ocr_texts']),
      sceneClassification: _asNonEmptyString(
        map['scene_classification'],
        fallback: 'unknown',
      ),
      sceneConfidence: _asDouble(map['scene_confidence']),
      personCount: _asInt(map['person_count']),
      personRects: _asRectList(map['person_rects']),
      detectedObjects:
          (map['detected_objects'] as List<dynamic>?)
              ?.whereType<Map<dynamic, dynamic>>()
              .map(SpatialObjectData.fromMap)
              .toList() ??
          [],
      hasDepthMap: _asBool(map['has_depth_map']),
    );
  }

  final List<SpatialObjectData> detectedObjects;
  final bool hasDepthMap;

  /// Rich context string — includes spatial objects and depth tiers.
  @override
  String toPromptContext() {
    final lines = <String>[];

    if (sceneClassification != 'unknown' && sceneConfidence > 0.15) {
      final label = sceneClassification.replaceAll('_', ' ');
      lines.add(
        '- Scene type: $label (${(sceneConfidence * 100).round()}% confidence)',
      );
    }

    if (personCount > 0) {
      lines.add('- People detected: $personCount');
    }

    final close = detectedObjects
        .where((o) => (o.relativeDepth ?? 1.0) < 0.50)
        .toList();
    if (close.isNotEmpty) {
      lines.add(
        '- Close obstacles: ${close.map((o) => o.spatialLabel).join('; ')}',
      );
    }

    final others = detectedObjects
        .where((o) => (o.relativeDepth ?? 0.0) >= 0.50)
        .take(6);
    if (others.isNotEmpty) {
      lines.add(
        '- Nearby objects: ${others.map((o) => o.spatialLabel).join('; ')}',
      );
    }

    if (ocrTexts.isNotEmpty) {
      final quoted = ocrTexts.take(4).map((t) => '"$t"').join(', ');
      lines.add('- Text visible: $quoted');
    }

    if (lines.isEmpty) return '';
    return 'Context from on-device sensors:\n${lines.join('\n')}';
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Model status
// ─────────────────────────────────────────────────────────────────────────────

/// Status of the on-device VLM (SmolVLM2) model.
enum ModelStatus {
  notAvailable,
  notDownloaded,
  downloading,
  ready, // downloaded but not loaded into memory
  loaded, // in memory, ready for inference
}

ModelStatus _parseModelStatus(String raw) {
  switch (raw) {
    case 'not_available':
      return ModelStatus.notAvailable;
    case 'loaded':
      return ModelStatus.loaded;
    case 'ready':
      return ModelStatus.ready;
    case 'downloading':
      return ModelStatus.downloading;
    default:
      return ModelStatus.notDownloaded;
  }
}

class OfflineVisionStatus {
  const OfflineVisionStatus({
    required this.foundationModelsAvailable,
    required this.modelStatus,
    required this.objectDetectionAvailable,
    required this.depthEstimationAvailable,
  });

  final bool foundationModelsAvailable;
  final ModelStatus modelStatus;
  final bool objectDetectionAvailable;
  final bool depthEstimationAvailable;

  bool get smolVlmAvailable =>
      modelStatus == ModelStatus.loaded || modelStatus == ModelStatus.ready;

  bool get hasSpatialPerception =>
      objectDetectionAvailable && depthEstimationAvailable;

  String get bestLocalBackendLabel {
    if (foundationModelsAvailable) return 'Foundation Models';
    if (modelStatus == ModelStatus.loaded) return 'SmolVLM2';
    if (hasSpatialPerception) return 'Core ML spatial perception';
    return 'Local basic vision';
  }

  List<String> get missingRequirements {
    final missing = <String>[];
    if (!foundationModelsAvailable) {
      missing.add('Foundation Models unavailable');
    }
    switch (modelStatus) {
      case ModelStatus.notAvailable:
        missing.add('SmolVLM2 unavailable');
      case ModelStatus.notDownloaded:
        missing.add('SmolVLM2 model not downloaded');
      case ModelStatus.downloading:
        missing.add('SmolVLM2 model still downloading');
      case ModelStatus.ready:
      case ModelStatus.loaded:
        break;
    }
    if (!objectDetectionAvailable) {
      missing.add('YOLOv3Tiny model missing');
    }
    if (!depthEstimationAvailable) {
      missing.add('Depth Anything model missing');
    }
    return missing;
  }
}

class NativeModelDiagnostic {
  const NativeModelDiagnostic({
    required this.name,
    required this.bundleFound,
    required this.compiledModelFound,
    required this.loaded,
    required this.message,
  });

  factory NativeModelDiagnostic.fromMap(Map<dynamic, dynamic> map) {
    return NativeModelDiagnostic(
      name: map['name']?.toString() ?? 'Unknown model',
      bundleFound: map['bundle_found'] as bool? ?? false,
      compiledModelFound: map['compiled_model_found'] as bool? ?? false,
      loaded: map['loaded'] as bool? ?? false,
      message: map['message']?.toString() ?? 'No diagnostic message.',
    );
  }

  final String name;
  final bool bundleFound;
  final bool compiledModelFound;
  final bool loaded;
  final String message;
}

class OfflineVisionDiagnostics {
  const OfflineVisionDiagnostics({
    required this.objectDetector,
    required this.depthEstimator,
  });

  factory OfflineVisionDiagnostics.fromMap(Map<dynamic, dynamic> map) {
    return OfflineVisionDiagnostics(
      objectDetector: NativeModelDiagnostic.fromMap(
        map['object_detector'] as Map<dynamic, dynamic>? ?? const {},
      ),
      depthEstimator: NativeModelDiagnostic.fromMap(
        map['depth_estimator'] as Map<dynamic, dynamic>? ?? const {},
      ),
    );
  }

  final NativeModelDiagnostic objectDetector;
  final NativeModelDiagnostic depthEstimator;
}

// ─────────────────────────────────────────────────────────────────────────────
// Service
// ─────────────────────────────────────────────────────────────────────────────

class ModelFileDownloadInfo {
  const ModelFileDownloadInfo({
    required this.name,
    required this.downloaded,
    required this.sizeBytes,
    required this.expectedSizeBytes,
    required this.sha256,
  });

  factory ModelFileDownloadInfo.fromMap(Map<dynamic, dynamic> map) {
    return ModelFileDownloadInfo(
      name: map['name']?.toString() ?? 'Unknown file',
      downloaded: map['downloaded'] as bool? ?? false,
      sizeBytes: _asInt(map['sizeBytes']),
      expectedSizeBytes: _asInt(map['expectedSizeBytes']),
      sha256: map['sha256']?.toString() ?? '',
    );
  }

  final String name;
  final bool downloaded;
  final int sizeBytes;
  final int expectedSizeBytes;
  final String sha256;
}

class SmolVlmModelInfo {
  const SmolVlmModelInfo({
    required this.downloaded,
    required this.valid,
    required this.downloading,
    required this.sizeBytes,
    required this.requiredBytes,
    required this.path,
    required this.modelName,
    required this.files,
  });

  factory SmolVlmModelInfo.fromMap(Map<dynamic, dynamic> map) {
    final rawFiles = map['files'];
    final files = rawFiles is List
        ? rawFiles
              .whereType<Map<dynamic, dynamic>>()
              .map(ModelFileDownloadInfo.fromMap)
              .toList()
        : const <ModelFileDownloadInfo>[];
    return SmolVlmModelInfo(
      downloaded: map['downloaded'] as bool? ?? false,
      valid: map['valid'] as bool? ?? map['downloaded'] as bool? ?? false,
      downloading: map['downloading'] as bool? ?? false,
      sizeBytes: _asInt(map['sizeBytes']),
      requiredBytes: _asInt(map['requiredBytes']),
      path: map['path']?.toString() ?? '',
      modelName: map['modelName']?.toString() ?? 'SmolVLM2',
      files: files,
    );
  }

  final bool downloaded;
  final bool valid;
  final bool downloading;
  final int sizeBytes;
  final int requiredBytes;
  final String path;
  final String modelName;
  final List<ModelFileDownloadInfo> files;

  double get progress {
    if (requiredBytes <= 0) return downloaded ? 1 : 0;
    return (sizeBytes / requiredBytes).clamp(0, 1).toDouble();
  }
}

class ModelDownloadEvent {
  const ModelDownloadEvent({
    required this.status,
    required this.phase,
    required this.progress,
    required this.filesDownloaded,
    required this.totalFiles,
    required this.requiredBytes,
    this.fileName,
  });

  factory ModelDownloadEvent.fromNative(Object? event) {
    if (event is double) {
      return ModelDownloadEvent(
        status: event >= 1 ? 'complete' : 'downloading',
        phase: 'downloading',
        progress: event.clamp(0, 1).toDouble(),
        filesDownloaded: 0,
        totalFiles: 0,
        requiredBytes: 0,
      );
    }
    if (event is int) {
      final progress = event.toDouble().clamp(0, 1).toDouble();
      return ModelDownloadEvent(
        status: progress >= 1 ? 'complete' : 'downloading',
        phase: 'downloading',
        progress: progress,
        filesDownloaded: 0,
        totalFiles: 0,
        requiredBytes: 0,
      );
    }
    final map = event is Map ? event : const <Object?, Object?>{};
    return ModelDownloadEvent(
      status: map['status']?.toString() ?? 'downloading',
      phase: map['phase']?.toString() ?? '',
      progress: _asDouble(map['progress']).clamp(0, 1).toDouble(),
      filesDownloaded: _asInt(map['filesDownloaded']),
      totalFiles: _asInt(map['totalFiles']),
      requiredBytes: _asInt(map['requiredBytes']),
      fileName: map['fileName']?.toString(),
    );
  }

  final String status;
  final String phase;
  final double progress;
  final int filesDownloaded;
  final int totalFiles;
  final int requiredBytes;
  final String? fileName;

  bool get isComplete => status == 'complete';
}

int _asInt(Object? value, {int fallback = 0}) {
  if (value is int) return value;
  if (value is num) return value.round();
  return int.tryParse(value?.toString() ?? '') ?? fallback;
}

double _asDouble(Object? value, {double fallback = 0}) {
  if (value is double) return value;
  if (value is num) return value.toDouble();
  return double.tryParse(value?.toString() ?? '') ?? fallback;
}

double? _asNullableDouble(Object? value) {
  if (value == null) return null;
  if (value is double) return value;
  if (value is num) return value.toDouble();
  return double.tryParse(value.toString());
}

bool _asBool(Object? value, {bool fallback = false}) {
  if (value is bool) return value;
  final raw = value?.toString().toLowerCase().trim();
  if (raw == 'true' || raw == '1' || raw == 'yes') return true;
  if (raw == 'false' || raw == '0' || raw == 'no') return false;
  return fallback;
}

String _asNonEmptyString(Object? value, {required String fallback}) {
  final text = value?.toString().trim() ?? '';
  return text.isEmpty ? fallback : text;
}

List<String> _asStringList(Object? value) {
  if (value == null) return const [];
  if (value is List) {
    return value
        .map((item) => item?.toString().trim() ?? '')
        .where((item) => item.isNotEmpty)
        .toList();
  }
  final text = value.toString().trim();
  return text.isEmpty ? const [] : [text];
}

List<Map<String, double>> _asRectList(Object? value) {
  if (value is! List) return const [];
  final rects = <Map<String, double>>[];
  for (final item in value) {
    if (item is! Map) continue;
    final rect = <String, double>{};
    for (final entry in item.entries) {
      final parsed = _asNullableDouble(entry.value);
      if (parsed != null) {
        rect[entry.key.toString()] = parsed;
      }
    }
    if (rect.isNotEmpty) rects.add(rect);
  }
  return rects;
}

/// Dart-side client for the native on-device vision MethodChannel.
/// Handles all three pipeline layers exposed by OnDeviceVisionChannel.swift.
class OnDeviceVisionService {
  static const _method = MethodChannel('com.ican/on_device_vision');
  static const _vlmStream = EventChannel('com.ican/vlm_stream');
  static const _fmStream = EventChannel('com.ican/fm_stream');
  static const _downloadStream = EventChannel(
    'com.ican/model_download_progress',
  );
  static const _firstNativeTokenTimeout = Duration(seconds: 120);

  Future<bool> pingNativeChannel() async {
    try {
      final result = await _method.invokeMethod<bool>('ping');
      return result ?? false;
    } on MissingPluginException {
      return false;
    } catch (_) {
      return false;
    }
  }

  Future<bool> isAppleVisionAvailable() async {
    try {
      final result = await _method.invokeMethod<bool>('isAppleVisionAvailable');
      return result ?? false;
    } on MissingPluginException {
      return false;
    } catch (_) {
      return false;
    }
  }

  // ── Layer 1 (legacy) ────────────────────────────────────────────────────

  /// Run Apple Vision framework only (OCR + scene + people).
  /// Kept for backward-compat; prefer [analyzeScene] for new code.
  Future<VisionAnalysis> analyzeWithVision(Uint8List jpegBytes) async {
    try {
      _recordVisionLog(
        'analyzeWithVision start imageBytes=${jpegBytes.length}',
      );
      final result = await _method.invokeMethod<Map<dynamic, dynamic>>(
        'analyzeWithVision',
        {'imageBytes': jpegBytes},
      );
      if (result == null || result.containsKey('error')) {
        final stage = result?['diagnostic_stage']?.toString() ?? 'native';
        debugPrint(
          '[OnDeviceVision] analyzeWithVision error at $stage: ${result?['error']}',
        );
        _recordVisionLog(
          'analyzeWithVision error stage=$stage error=${result?['error']}',
        );
        throw LocalVisionException(
          'Local L02',
          'Apple Vision could not analyze this image.',
          detail: 'stage=$stage ${result?['error'] ?? ''}'.trim(),
        );
      }
      final analysis = VisionAnalysis.fromMap(result);
      final warnings = _asStringList(result['vision_warnings']);
      _recordVisionLog(
        'analyzeWithVision parsed stage=${result['diagnostic_stage'] ?? "complete"} '
        'ocr=${analysis.ocrTexts.length} people=${analysis.personCount} '
        'scene=${analysis.sceneClassification} warnings=${warnings.join("|")}',
      );
      return analysis;
    } on LocalVisionException {
      rethrow;
    } on MissingPluginException catch (e) {
      debugPrint('[OnDeviceVision] Missing plugin: $e');
      _recordVisionLog('analyzeWithVision missing_plugin $e');
      throw const LocalVisionException(
        'Local L01',
        'native vision channel is not registered.',
      );
    } on PlatformException catch (e) {
      debugPrint('[OnDeviceVision] Platform error: ${e.message}');
      _recordVisionLog(
        'analyzeWithVision platform_error ${_platformDetail(e)}',
      );
      throw LocalVisionException(
        'Local L03',
        'Apple Vision or Core ML failed.',
        detail: _platformDetail(e),
      );
    } catch (e) {
      debugPrint('[OnDeviceVision] Dart parse error: $e');
      _recordVisionLog('analyzeWithVision dart_parse_error $e');
      throw LocalVisionException(
        'Local L04',
        'Apple Vision returned data that Dart could not parse.',
        detail: e.toString(),
      );
    }
  }

  // ── Layer 1 (full) ───────────────────────────────────────────────────────

  /// Run the full Layer 1 pipeline: Apple Vision + Depth Anything V2 + YOLOv3.
  /// Returns a [ScenePerceptionResult] with spatial objects and depth tiers.
  Future<ScenePerceptionResult> analyzeScene(Uint8List jpegBytes) async {
    try {
      final result = await _method.invokeMethod<Map<dynamic, dynamic>>(
        'analyzeScene',
        {'imageBytes': jpegBytes},
      );
      if (result == null || result.containsKey('error')) {
        debugPrint('[OnDeviceVision] analyzeScene error: ${result?['error']}');
        throw LocalVisionException(
          'Local L02',
          'Apple Vision could not analyze this image.',
          detail: result?['error']?.toString(),
        );
      }
      return ScenePerceptionResult.fromMap(result);
    } on LocalVisionException {
      rethrow;
    } on MissingPluginException catch (e) {
      debugPrint('[OnDeviceVision] Missing plugin: $e');
      throw const LocalVisionException(
        'Local L01',
        'native vision channel is not registered.',
      );
    } on PlatformException catch (e) {
      debugPrint('[OnDeviceVision] Platform error: ${e.message}');
      throw LocalVisionException(
        'Local L03',
        'Apple Vision or Core ML failed.',
        detail: _platformDetail(e),
      );
    }
  }

  // ── Object detection availability ─────────────────────────────────────────

  Future<bool> isObjectDetectionAvailable() async {
    try {
      final result = await _method.invokeMethod<bool>(
        'isObjectDetectionAvailable',
      );
      return result ?? false;
    } catch (_) {
      return false;
    }
  }

  Future<bool> isDepthEstimationAvailable() async {
    try {
      final result = await _method.invokeMethod<bool>(
        'isDepthEstimationAvailable',
      );
      return result ?? false;
    } catch (_) {
      return false;
    }
  }

  Future<OfflineVisionStatus> getOfflineVisionStatus() async {
    final results = await Future.wait<Object>([
      isFoundationModelsAvailable(),
      getModelStatus(),
      isObjectDetectionAvailable(),
      isDepthEstimationAvailable(),
    ]);

    return OfflineVisionStatus(
      foundationModelsAvailable: results[0] as bool,
      modelStatus: results[1] as ModelStatus,
      objectDetectionAvailable: results[2] as bool,
      depthEstimationAvailable: results[3] as bool,
    );
  }

  Future<OfflineVisionDiagnostics> getOfflineVisionDiagnostics() async {
    try {
      final result = await _method.invokeMethod<Map<dynamic, dynamic>>(
        'getNativeModelDiagnostics',
      );
      return OfflineVisionDiagnostics.fromMap(result ?? const {});
    } on MissingPluginException catch (e) {
      debugPrint('[OnDeviceVision] Diagnostics unavailable: $e');
      return const OfflineVisionDiagnostics(
        objectDetector: NativeModelDiagnostic(
          name: 'YOLOv3Tiny',
          bundleFound: false,
          compiledModelFound: false,
          loaded: false,
          message: 'Native vision channel is not registered.',
        ),
        depthEstimator: NativeModelDiagnostic(
          name: 'DepthAnythingV2SmallF16P6',
          bundleFound: false,
          compiledModelFound: false,
          loaded: false,
          message: 'Native vision channel is not registered.',
        ),
      );
    } on PlatformException catch (e) {
      debugPrint('[OnDeviceVision] Diagnostics unavailable: $e');
      final detail = _platformDetail(e);
      return OfflineVisionDiagnostics(
        objectDetector: NativeModelDiagnostic(
          name: 'YOLOv3Tiny',
          bundleFound: false,
          compiledModelFound: false,
          loaded: false,
          message: 'Native model diagnostics failed. $detail',
        ),
        depthEstimator: NativeModelDiagnostic(
          name: 'DepthAnythingV2SmallF16P6',
          bundleFound: false,
          compiledModelFound: false,
          loaded: false,
          message: 'Native model diagnostics failed. $detail',
        ),
      );
    } catch (e) {
      debugPrint('[OnDeviceVision] Diagnostics unavailable: $e');
      return OfflineVisionDiagnostics(
        objectDetector: NativeModelDiagnostic(
          name: 'YOLOv3Tiny',
          bundleFound: false,
          compiledModelFound: false,
          loaded: false,
          message: 'Native model diagnostics failed. $e',
        ),
        depthEstimator: NativeModelDiagnostic(
          name: 'DepthAnythingV2SmallF16P6',
          bundleFound: false,
          compiledModelFound: false,
          loaded: false,
          message: 'Native model diagnostics failed. $e',
        ),
      );
    }
  }

  // ── Layer 3: Foundation Models ───────────────────────────────────────────

  /// Returns true if Apple Foundation Models is available on this device (iOS 26+).
  Future<bool> isFoundationModelsAvailable() async {
    try {
      final result = await _method.invokeMethod<bool>(
        'isFoundationModelsAvailable',
      );
      return result ?? false;
    } catch (_) {
      return false;
    }
  }

  /// Synthesize a scene description using Apple Foundation Models.
  /// Streams text chunks (sentences) via EventChannel.
  Stream<String> synthesizeWithFoundationModels(
    String context, {
    required String systemPrompt,
  }) {
    return _invokeTokenStream(
      channel: _fmStream,
      method: 'synthesizeDescription',
      arguments: {'context': context, 'systemPrompt': systemPrompt},
      localCode: 'Local L30',
      stageLabel: 'Foundation Models',
    );
  }

  // ── Layer 2: SmolVLM2 ───────────────────────────────────────────────────

  Future<ModelStatus> getModelStatus() async {
    try {
      final raw = await _method.invokeMethod<String>('getModelStatus');
      return _parseModelStatus(raw ?? 'not_downloaded');
    } catch (_) {
      return ModelStatus.notDownloaded;
    }
  }

  Future<bool> loadVlmModel() async {
    try {
      final result = await _method.invokeMethod<bool>('loadModel');
      return result ?? false;
    } catch (e) {
      debugPrint('[OnDeviceVision] Failed to load VLM: $e');
      return false;
    }
  }

  Future<void> unloadVlmModel() async {
    try {
      await _method.invokeMethod<bool>('unloadModel');
    } catch (e) {
      debugPrint('[OnDeviceVision] Failed to unload VLM: $e');
    }
  }

  /// Run VLM inference and stream tokens back.
  Stream<String> describeWithVlm(
    Uint8List jpegBytes, {
    required String systemPrompt,
    String? visionContext,
  }) {
    return _invokeTokenStream(
      channel: _vlmStream,
      method: 'describeImage',
      arguments: {
        'imageBytes': jpegBytes,
        'systemPrompt': systemPrompt,
        'visionContext': visionContext,
      },
      localCode: 'Local L20',
      stageLabel: 'SmolVLM2',
    );
  }

  // ── Download management ──────────────────────────────────────────────────

  Stream<ModelDownloadEvent> startModelDownload() {
    late final StreamController<ModelDownloadEvent> controller;
    StreamSubscription<dynamic>? progressSub;

    controller = StreamController<ModelDownloadEvent>(
      onListen: () async {
        progressSub = _downloadStream.receiveBroadcastStream().listen(
          (event) => controller.add(ModelDownloadEvent.fromNative(event)),
          onError: controller.addError,
          onDone: controller.close,
        );

        try {
          await _method.invokeMethod<bool>('downloadModel');
        } on PlatformException catch (e, stackTrace) {
          debugPrint('[OnDeviceVision] Download error: ${e.message}');
          await progressSub?.cancel();
          controller.addError(e, stackTrace);
          await controller.close();
        }
      },
      onCancel: () async {
        await progressSub?.cancel();
      },
    );

    return controller.stream;
  }

  Future<void> cancelModelDownload() async {
    try {
      await _method.invokeMethod<bool>('cancelDownload');
    } catch (_) {}
  }

  Future<bool> deleteModel() async {
    try {
      final result = await _method.invokeMethod<bool>('deleteModel');
      return result ?? false;
    } catch (_) {
      return false;
    }
  }

  Future<Map<String, dynamic>> getModelInfo() async {
    try {
      final result = await _method.invokeMethod<Map<dynamic, dynamic>>(
        'getModelInfo',
      );
      return result?.map((k, v) => MapEntry(k.toString(), v)) ?? {};
    } catch (_) {
      return {};
    }
  }

  Future<SmolVlmModelInfo> getSmolVlmModelInfo() async {
    try {
      final result = await _method.invokeMethod<Map<dynamic, dynamic>>(
        'getModelInfo',
      );
      return SmolVlmModelInfo.fromMap(result ?? const {});
    } catch (_) {
      return const SmolVlmModelInfo(
        downloaded: false,
        valid: false,
        downloading: false,
        sizeBytes: 0,
        requiredBytes: 0,
        path: '',
        modelName: 'SmolVLM2',
        files: [],
      );
    }
  }

  Future<Map<String, dynamic>> runSmolVlmSelfTest(
    Uint8List jpegBytes, {
    String systemPrompt =
        'Describe this image in one concise sentence for a blind user.',
  }) async {
    try {
      final result = await _method.invokeMethod<Map<dynamic, dynamic>>(
        'runSmolVlmSelfTest',
        {'imageBytes': jpegBytes, 'systemPrompt': systemPrompt},
      );
      return _stringKeyedMap(result ?? const {});
    } on MissingPluginException {
      return {
        'llamaLinked': false,
        'loadSuccess': false,
        'error': 'Native vision channel is not registered.',
      };
    } on PlatformException catch (e) {
      return {
        'llamaLinked': false,
        'loadSuccess': false,
        'error': _platformDetail(e),
      };
    } catch (e) {
      return {'llamaLinked': false, 'loadSuccess': false, 'error': '$e'};
    }
  }

  // ── Private helpers ──────────────────────────────────────────────────────

  Stream<String> _invokeTokenStream({
    required EventChannel channel,
    required String method,
    required Map<String, Object?> arguments,
    required String localCode,
    required String stageLabel,
  }) {
    late final StreamController<String> controller;
    StreamSubscription<dynamic>? subscription;
    Timer? firstTokenTimer;
    var gotToken = false;
    var finished = false;

    void finish() {
      if (finished) return;
      finished = true;
      firstTokenTimer?.cancel();
      unawaited(subscription?.cancel());
      unawaited(controller.close());
    }

    void fail(Object error, [StackTrace? stackTrace]) {
      if (finished) return;
      finished = true;
      firstTokenTimer?.cancel();
      final exception = _asLocalVisionException(
        error,
        localCode: localCode,
        stageLabel: stageLabel,
      );
      debugPrint('[OnDeviceVision] $stageLabel stream failed: $exception');
      controller.addError(exception, stackTrace);
      unawaited(subscription?.cancel());
      unawaited(controller.close());
    }

    controller = StreamController<String>(
      onListen: () async {
        firstTokenTimer = Timer(_firstNativeTokenTimeout, () {
          fail(
            LocalVisionException(
              localCode,
              '$stageLabel produced no text before the timeout.',
              detail:
                  'Waited ${_firstNativeTokenTimeout.inSeconds} seconds for the first token.',
            ),
          );
        });

        subscription = channel.receiveBroadcastStream().listen(
          (event) {
            if (finished) return;
            if (event is! String || event.isEmpty) return;
            gotToken = true;
            firstTokenTimer?.cancel();
            controller.add(event);
          },
          onError: fail,
          onDone: () {
            if (gotToken) {
              finish();
            } else {
              fail(
                LocalVisionException(
                  localCode,
                  '$stageLabel produced no output.',
                  detail: 'Native stream ended without any text tokens.',
                ),
              );
            }
          },
        );

        try {
          await _method.invokeMethod<bool>(method, arguments);
        } catch (e, stackTrace) {
          fail(e, stackTrace);
        }
      },
      onCancel: () async {
        firstTokenTimer?.cancel();
        await subscription?.cancel();
      },
    );

    return controller.stream;
  }

  LocalVisionException _asLocalVisionException(
    Object error, {
    required String localCode,
    required String stageLabel,
  }) {
    if (error is LocalVisionException) return error;
    if (error is MissingPluginException) {
      return const LocalVisionException(
        'Local L01',
        'native vision channel is not registered.',
      );
    }
    if (error is PlatformException) {
      return LocalVisionException(
        localCode,
        '$stageLabel native inference failed.',
        detail: _platformDetail(error),
      );
    }
    return LocalVisionException(
      localCode,
      '$stageLabel native inference failed.',
      detail: error.toString(),
    );
  }

  static Map<String, dynamic> _stringKeyedMap(Map<dynamic, dynamic> source) {
    return source.map((key, value) {
      final dynamic mappedValue = switch (value) {
        final Map<dynamic, dynamic> map => _stringKeyedMap(map),
        final List list =>
          list
              .map(
                (item) => item is Map<dynamic, dynamic>
                    ? _stringKeyedMap(item)
                    : item,
              )
              .toList(),
        _ => value,
      };
      return MapEntry(key.toString(), mappedValue);
    });
  }

  static String _platformDetail(PlatformException e) {
    final parts = <String>[e.code];
    final message = e.message;
    if (message != null && message.isNotEmpty) parts.add(message);
    final details = e.details;
    if (details != null) parts.add(details.toString());
    return parts.join(': ');
  }

  static void _recordVisionLog(String message) {
    unawaited(AppLogService.instance.record(message, source: 'vision'));
  }
}
