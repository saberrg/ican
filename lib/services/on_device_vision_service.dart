import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

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

/// Lightweight JPEG sanity check that never crosses the native boundary.
///
/// Rejects anything that isn't plausibly a full JPEG: too small to contain a
/// scene, missing the 0xFFD8 SOI marker, or missing the 0xFFD9 EOI marker.
/// We intentionally keep the check cheap — heavy decoding is the native
/// layer's job — but everything that reaches a CoreML / llama.cpp entry
/// point must pass this gate first, since malformed bytes have segfaulted
/// the native layer in the past.
bool isLikelyValidJpeg(Uint8List bytes) {
  if (bytes.length < 1024) return false;
  if (bytes[0] != 0xFF || bytes[1] != 0xD8) return false;
  final last = bytes.length - 1;
  if (bytes[last - 1] != 0xFF || bytes[last] != 0xD9) return false;
  return true;
}

LocalVisionException _malformedJpegException(int byteCount) {
  return LocalVisionException(
    'Local L00',
    'Image is corrupt or incomplete.',
    detail: 'received $byteCount bytes without a valid JPEG envelope.',
  );
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

  bool get hasLivePerception =>
      objectDetectionAvailable || depthEstimationAvailable;

  String get bestLocalBackendLabel {
    if (modelStatus == ModelStatus.loaded) return 'SmolVLM2';
    if (foundationModelsAvailable) return 'Foundation Models';
    if (modelStatus == ModelStatus.ready) return 'SmolVLM2 ready';
    if (hasLivePerception) return 'Local live perception';
    return 'Apple Vision basic';
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

Map<String, dynamic> _stringKeyedMap(Map<dynamic, dynamic> source) {
  return source.map((key, value) {
    final dynamic mappedValue = switch (value) {
      final Map<dynamic, dynamic> map => _stringKeyedMap(map),
      final List list =>
        list
            .map(
              (item) =>
                  item is Map<dynamic, dynamic> ? _stringKeyedMap(item) : item,
            )
            .toList(),
      _ => value,
    };
    return MapEntry(key.toString(), mappedValue);
  });
}

class SmolVlmReadinessReport {
  const SmolVlmReadinessReport({
    required this.runtimeLinked,
    required this.filesPresent,
    required this.shaVerified,
    required this.loadSuccess,
    required this.memoryBeforeBytes,
    required this.memoryAfterLoadBytes,
    required this.memoryAfterInferenceBytes,
    required this.loadLatencyMs,
    required this.imageEvalLatencyMs,
    required this.firstTokenLatencyMs,
    required this.totalLatencyMs,
    required this.tokenCount,
    required this.sanitizedOutput,
    required this.passed,
    required this.failureReason,
    required this.raw,
  });

  factory SmolVlmReadinessReport.fromMap(Map<dynamic, dynamic> map) {
    final raw = _stringKeyedMap(map);
    final sanitizedOutput =
        raw['sanitizedOutput']?.toString() ??
        raw['outputPreview']?.toString() ??
        '';
    final base = SmolVlmReadinessReport(
      runtimeLinked: _asBool(raw['runtimeLinked'] ?? raw['llamaLinked']),
      filesPresent: _asBool(raw['filesPresent']),
      shaVerified: _asBool(raw['shaVerified']),
      loadSuccess: _asBool(raw['loadSuccess']),
      memoryBeforeBytes: _asInt(raw['memoryBeforeBytes']),
      memoryAfterLoadBytes: _asInt(raw['memoryAfterLoadBytes']),
      memoryAfterInferenceBytes: _asInt(raw['memoryAfterInferenceBytes']),
      loadLatencyMs: _asInt(raw['loadLatencyMs']),
      imageEvalLatencyMs: _asInt(raw['imageEvalLatencyMs']),
      firstTokenLatencyMs: _asInt(raw['firstTokenLatencyMs']),
      totalLatencyMs: _asInt(raw['totalLatencyMs']),
      tokenCount: _asInt(raw['tokenCount']),
      sanitizedOutput: sanitizedOutput,
      passed: _asBool(raw['passed']),
      failureReason:
          raw['failureReason']?.toString() ?? raw['error']?.toString() ?? '',
      raw: raw,
    );
    return base._enforceDartGates();
  }

  factory SmolVlmReadinessReport.failed(
    String failureReason, {
    Map<String, Object?> raw = const {},
  }) {
    return SmolVlmReadinessReport.fromMap({
      ...raw,
      'runtimeLinked': raw['runtimeLinked'] ?? false,
      'filesPresent': raw['filesPresent'] ?? false,
      'shaVerified': raw['shaVerified'] ?? false,
      'loadSuccess': raw['loadSuccess'] ?? false,
      'memoryBeforeBytes': raw['memoryBeforeBytes'] ?? 0,
      'memoryAfterLoadBytes': raw['memoryAfterLoadBytes'] ?? 0,
      'memoryAfterInferenceBytes': raw['memoryAfterInferenceBytes'] ?? 0,
      'loadLatencyMs': raw['loadLatencyMs'] ?? 0,
      'imageEvalLatencyMs': raw['imageEvalLatencyMs'] ?? 0,
      'firstTokenLatencyMs': raw['firstTokenLatencyMs'] ?? -1,
      'totalLatencyMs': raw['totalLatencyMs'] ?? 0,
      'tokenCount': raw['tokenCount'] ?? 0,
      'sanitizedOutput': raw['sanitizedOutput'] ?? '',
      'passed': false,
      'failureReason': failureReason,
    });
  }

  static const int minimumMemoryBeforeBytes = 1100 * 1000 * 1000;
  static const int minimumMemoryAfterBytes = 300 * 1000 * 1000;
  static const int maximumLoadLatencyMs = 20000;
  static const int maximumFirstTokenLatencyMs = 25000;
  static const int maximumTotalLatencyMs = 45000;

  final bool runtimeLinked;
  final bool filesPresent;
  final bool shaVerified;
  final bool loadSuccess;
  final int memoryBeforeBytes;
  final int memoryAfterLoadBytes;
  final int memoryAfterInferenceBytes;
  final int loadLatencyMs;
  final int imageEvalLatencyMs;
  final int firstTokenLatencyMs;
  final int totalLatencyMs;
  final int tokenCount;
  final String sanitizedOutput;
  final bool passed;
  final String failureReason;
  final Map<String, dynamic> raw;

  Map<String, dynamic> toJson() {
    return {
      ...raw,
      'runtimeLinked': runtimeLinked,
      'filesPresent': filesPresent,
      'shaVerified': shaVerified,
      'loadSuccess': loadSuccess,
      'memoryBeforeBytes': memoryBeforeBytes,
      'memoryAfterLoadBytes': memoryAfterLoadBytes,
      'memoryAfterInferenceBytes': memoryAfterInferenceBytes,
      'loadLatencyMs': loadLatencyMs,
      'imageEvalLatencyMs': imageEvalLatencyMs,
      'firstTokenLatencyMs': firstTokenLatencyMs,
      'totalLatencyMs': totalLatencyMs,
      'tokenCount': tokenCount,
      'sanitizedOutput': sanitizedOutput,
      'passed': passed,
      'failureReason': failureReason,
    };
  }

  SmolVlmReadinessReport _enforceDartGates() {
    final reason = _firstGateFailure();
    if (reason == null && passed) return this;
    return SmolVlmReadinessReport(
      runtimeLinked: runtimeLinked,
      filesPresent: filesPresent,
      shaVerified: shaVerified,
      loadSuccess: loadSuccess,
      memoryBeforeBytes: memoryBeforeBytes,
      memoryAfterLoadBytes: memoryAfterLoadBytes,
      memoryAfterInferenceBytes: memoryAfterInferenceBytes,
      loadLatencyMs: loadLatencyMs,
      imageEvalLatencyMs: imageEvalLatencyMs,
      firstTokenLatencyMs: firstTokenLatencyMs,
      totalLatencyMs: totalLatencyMs,
      tokenCount: tokenCount,
      sanitizedOutput: sanitizedOutput,
      passed: false,
      failureReason: failureReason.isNotEmpty
          ? failureReason
          : (reason ?? 'SmolVLM2 readiness probe did not pass.'),
      raw: raw,
    );
  }

  String? _firstGateFailure() {
    if (!runtimeLinked) return 'llama runtime is not linked.';
    if (!filesPresent) return 'SmolVLM2 model files are missing.';
    if (!shaVerified) {
      return 'SmolVLM2 model files did not match expected SHA-256.';
    }
    if (memoryBeforeBytes < minimumMemoryBeforeBytes) {
      return 'Available memory before load is below 1.1 GB.';
    }
    if (!loadSuccess) return 'SmolVLM2 failed to load.';
    if (loadLatencyMs <= 0 || loadLatencyMs > maximumLoadLatencyMs) {
      return 'SmolVLM2 load exceeded the 20 second limit.';
    }
    if (memoryAfterLoadBytes < minimumMemoryAfterBytes ||
        memoryAfterInferenceBytes < minimumMemoryAfterBytes) {
      return 'Available memory after probe is below 300 MB.';
    }
    if (firstTokenLatencyMs <= 0 ||
        firstTokenLatencyMs > maximumFirstTokenLatencyMs) {
      return 'SmolVLM2 first token exceeded the 25 second limit.';
    }
    if (totalLatencyMs <= 0 || totalLatencyMs > maximumTotalLatencyMs) {
      return 'SmolVLM2 self-test exceeded the 45 second limit.';
    }
    if (tokenCount <= 0 || !_hasUsefulSpokenOutput(sanitizedOutput)) {
      return 'SmolVLM2 output did not pass spoken quality checks.';
    }
    if (_asBool(raw['memoryWarningDuringProbe'])) {
      return 'iOS reported memory pressure during the SmolVLM2 probe.';
    }
    return null;
  }

  static bool _hasUsefulSpokenOutput(String text) {
    final normalized = text.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (normalized.isEmpty) return false;
    final words = RegExp(r"[A-Za-z0-9']+").allMatches(normalized).length;
    if (words < 8) return false;
    if (!RegExp(r'''[.!?]["')\]]*$''').hasMatch(normalized)) return false;
    final lower = normalized.toLowerCase();
    if (RegExp(
      r'\b(smolvlm|llama|model|prompt|token|assistant|system|user|image\s+shows|as\s+an\s+ai)\b',
    ).hasMatch(lower)) {
      return false;
    }
    final tokens = lower.split(RegExp(r'\s+'));
    for (var i = 0; i + 7 < tokens.length; i++) {
      final phrase = tokens.sublist(i, i + 4).join(' ');
      final next = tokens.sublist(i + 4, i + 8).join(' ');
      if (phrase == next) return false;
    }
    return true;
  }
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
  static const _readinessPrefsKey = 'smol_vlm_readiness_capability_v1';
  static const _lastReadinessPrefsKey = 'smol_vlm_readiness_last_report_v1';
  static final Set<String> _failedReadinessKeys = <String>{};

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
    if (!isLikelyValidJpeg(jpegBytes)) {
      _recordVisionLog(
        'analyzeWithVision rejected malformed JPEG bytes=${jpegBytes.length}',
      );
      throw _malformedJpegException(jpegBytes.length);
    }
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

  /// Run the stable live lane: Apple Vision OCR, scene classification, and
  /// person detection only. This intentionally avoids generative VLM and heavy
  /// optional Core ML models so live mode can skip bad frames without taking
  /// down the app.
  Future<VisionAnalysis> analyzeLiveFrame(Uint8List jpegBytes) async {
    if (!isLikelyValidJpeg(jpegBytes)) {
      _recordVisionLog(
        'analyzeLiveFrame rejected malformed JPEG bytes=${jpegBytes.length}',
      );
      throw _malformedJpegException(jpegBytes.length);
    }
    try {
      final result = await _method
          .invokeMethod<Map<dynamic, dynamic>>('analyzeLiveFrame', {
            'imageBytes': jpegBytes,
          })
          .timeout(const Duration(seconds: 5));
      if (result == null || result.containsKey('error')) {
        throw LocalVisionException(
          'Local L02',
          'Apple Vision could not analyze this live frame.',
          detail: result?['error']?.toString(),
        );
      }
      return VisionAnalysis.fromMap(result);
    } on TimeoutException {
      throw const LocalVisionException(
        'Local L05',
        'Local live vision timed out.',
      );
    } on LocalVisionException {
      rethrow;
    } on MissingPluginException catch (e) {
      debugPrint('[OnDeviceVision] Missing plugin: $e');
      throw const LocalVisionException(
        'Local L01',
        'native vision channel is not registered.',
      );
    } on PlatformException catch (e) {
      debugPrint('[OnDeviceVision] Live platform error: ${e.message}');
      throw LocalVisionException(
        'Local L03',
        'Apple Vision failed on this live frame.',
        detail: _platformDetail(e),
      );
    }
  }

  // ── Layer 1 (full) ───────────────────────────────────────────────────────

  /// Run the full Layer 1 pipeline: Apple Vision + Depth Anything V2 + YOLOv3.
  /// Returns a [ScenePerceptionResult] with spatial objects and depth tiers.
  Future<ScenePerceptionResult> analyzeScene(Uint8List jpegBytes) async {
    if (!isLikelyValidJpeg(jpegBytes)) {
      throw _malformedJpegException(jpegBytes.length);
    }
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

  Future<bool> isSmolVlmReadyForDescribe(
    Uint8List jpegBytes, {
    String systemPrompt =
        'Describe this image in one concise sentence for a blind user.',
  }) async {
    final context = await _getSmolVlmReadinessContext();
    final cacheKey = _smolVlmReadinessCacheKey(context);
    if (_failedReadinessKeys.contains(cacheKey)) return false;

    final cached = await _loadCachedSmolVlmReadiness(cacheKey);
    if (cached != null && cached.passed) return true;

    final report = await runSmolVlmReadinessProbe(
      jpegBytes,
      systemPrompt: systemPrompt,
      context: context,
      cacheKey: cacheKey,
    );
    return report.passed;
  }

  Future<SmolVlmReadinessReport> runSmolVlmReadinessProbe(
    Uint8List jpegBytes, {
    String systemPrompt =
        'Describe this image in one concise sentence for a blind user.',
    Map<String, dynamic>? context,
    String? cacheKey,
  }) async {
    final readinessContext = context ?? await _getSmolVlmReadinessContext();
    final key = cacheKey ?? _smolVlmReadinessCacheKey(readinessContext);

    if (!isLikelyValidJpeg(jpegBytes)) {
      final report = SmolVlmReadinessReport.failed(
        'Readiness probe image is corrupt or incomplete.',
        raw: {
          ...readinessContext,
          'jpegBytes': jpegBytes.length,
          'runtimeLinked': readinessContext['runtimeLinked'] ?? false,
        },
      );
      await _storeSmolVlmReadinessReport(key, report);
      return report;
    }

    try {
      final result = await _method.invokeMethod<Map<dynamic, dynamic>>(
        'runSmolVlmReadinessProbe',
        {'imageBytes': jpegBytes, 'systemPrompt': systemPrompt},
      );
      final report = SmolVlmReadinessReport.fromMap({
        ...readinessContext,
        ...?result,
      });
      await _storeSmolVlmReadinessReport(key, report);
      return report;
    } on MissingPluginException {
      final report = SmolVlmReadinessReport.failed(
        'Native vision channel is not registered.',
        raw: {...readinessContext, 'runtimeLinked': false},
      );
      await _storeSmolVlmReadinessReport(key, report);
      return report;
    } on PlatformException catch (e) {
      final report = SmolVlmReadinessReport.failed(
        _platformDetail(e),
        raw: {...readinessContext, 'runtimeLinked': false},
      );
      await _storeSmolVlmReadinessReport(key, report);
      return report;
    } catch (e) {
      final report = SmolVlmReadinessReport.failed(
        e.toString(),
        raw: readinessContext,
      );
      await _storeSmolVlmReadinessReport(key, report);
      return report;
    }
  }

  Future<String> getSmolVlmReadinessSupportSnapshot() async {
    final context = await _getSmolVlmReadinessContext();
    final cacheKey = _smolVlmReadinessCacheKey(context);
    final cached = await _loadCachedSmolVlmReadiness(cacheKey);
    final payload = <String, dynamic>{
      'cacheKey': cacheKey,
      'context': context,
      'readiness':
          cached?.toJson() ??
          {
            'passed': false,
            'failureReason': 'No cached SmolVLM2 readiness probe report.',
          },
    };
    return const JsonEncoder.withIndent(
      '  ',
    ).convert(_redactLocalPaths(payload));
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
    if (!isLikelyValidJpeg(jpegBytes)) {
      return Stream<String>.error(_malformedJpegException(jpegBytes.length));
    }
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

  Future<Map<String, dynamic>> _getSmolVlmReadinessContext() async {
    try {
      final result = await _method.invokeMethod<Map<dynamic, dynamic>>(
        'getSmolVlmReadinessContext',
      );
      return _stringKeyedMap(result ?? const {});
    } on MissingPluginException {
      return {
        'runtimeLinked': false,
        'failureReason': 'Native vision channel is not registered.',
      };
    } catch (e) {
      return {'runtimeLinked': false, 'failureReason': e.toString()};
    }
  }

  String _smolVlmReadinessCacheKey(Map<String, dynamic> context) {
    final files = context['files'] is List
        ? context['files'] as List
        : const [];
    final fileKey = files
        .map((file) {
          if (file is! Map) return file.toString();
          return [
            file['fileName'] ?? file['name'] ?? '',
            file['expectedSizeBytes'] ?? '',
            file['sha256'] ?? '',
          ].join(':');
        })
        .join('|');
    return [
      context['appVersion'] ?? '',
      context['buildNumber'] ?? '',
      context['osVersion'] ?? '',
      context['deviceModel'] ?? '',
      fileKey,
    ].join('::');
  }

  Future<SmolVlmReadinessReport?> _loadCachedSmolVlmReadiness(
    String cacheKey,
  ) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_readinessPrefsKey);
      if (raw == null || raw.isEmpty) return null;
      final decoded = jsonDecode(raw);
      if (decoded is! Map || decoded['cacheKey'] != cacheKey) return null;
      final reportMap = decoded['report'];
      if (reportMap is! Map) return null;
      return SmolVlmReadinessReport.fromMap(reportMap);
    } catch (_) {
      return null;
    }
  }

  Future<void> _storeSmolVlmReadinessReport(
    String cacheKey,
    SmolVlmReadinessReport report,
  ) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final redactedReport = _redactLocalPaths(report.toJson());
      await prefs.setString(
        _lastReadinessPrefsKey,
        jsonEncode({'cacheKey': cacheKey, 'report': redactedReport}),
      );
      if (report.passed) {
        _failedReadinessKeys.remove(cacheKey);
        await prefs.setString(
          _readinessPrefsKey,
          jsonEncode({'cacheKey': cacheKey, 'report': redactedReport}),
        );
      } else {
        _failedReadinessKeys.add(cacheKey);
        await prefs.remove(_readinessPrefsKey);
      }
    } catch (e) {
      debugPrint('[OnDeviceVision] Failed to store SmolVLM readiness: $e');
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

Object? _redactLocalPaths(Object? value) {
  if (value is Map) {
    return value.map((key, entryValue) {
      final keyText = key.toString().toLowerCase();
      if (keyText == 'path' || keyText.endsWith('path')) {
        return MapEntry(key.toString(), '<redacted>');
      }
      return MapEntry(key.toString(), _redactLocalPaths(entryValue));
    });
  }
  if (value is List) return value.map(_redactLocalPaths).toList();
  if (value is String) {
    return value.replaceAll(
      RegExp(r'(/var|/private|/users|[a-z]:\\)[^\s",]+', caseSensitive: false),
      '<redacted>',
    );
  }
  return value;
}
