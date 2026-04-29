import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

enum DescribePipelineStage {
  captureRequested('Capture requested'),
  captureStarted('Capture started'),
  jpegValidation('JPEG validation'),
  imageEnhancement('Image enhancement'),
  cloudRequest('Cloud describe request'),
  offlineRequest('Offline describe request'),
  speech('Speech playback'),
  completed('Completed'),
  failed('Failed');

  const DescribePipelineStage(this.label);

  final String label;

  bool get isTerminal =>
      this == DescribePipelineStage.completed ||
      this == DescribePipelineStage.failed;
}

class DescribeAttemptTrace {
  const DescribeAttemptTrace({
    required this.attemptId,
    required this.stage,
    required this.startedAt,
    required this.updatedAt,
    required this.imageBytes,
    required this.visionMode,
    required this.detailLevel,
    required this.hazardSensitivity,
    this.requestedEyeProfile,
    this.lastError,
  });

  final String attemptId;
  final DescribePipelineStage stage;
  final DateTime startedAt;
  final DateTime updatedAt;
  final int imageBytes;
  final String visionMode;
  final String detailLevel;
  final String hazardSensitivity;
  final String? requestedEyeProfile;
  final String? lastError;

  bool get unfinished => !stage.isTerminal;

  DescribeAttemptTrace copyWith({
    DescribePipelineStage? stage,
    DateTime? updatedAt,
    int? imageBytes,
    String? visionMode,
    String? detailLevel,
    String? hazardSensitivity,
    String? requestedEyeProfile,
    String? lastError,
  }) {
    return DescribeAttemptTrace(
      attemptId: attemptId,
      stage: stage ?? this.stage,
      startedAt: startedAt,
      updatedAt: updatedAt ?? DateTime.now(),
      imageBytes: imageBytes ?? this.imageBytes,
      visionMode: visionMode ?? this.visionMode,
      detailLevel: detailLevel ?? this.detailLevel,
      hazardSensitivity: hazardSensitivity ?? this.hazardSensitivity,
      requestedEyeProfile: requestedEyeProfile ?? this.requestedEyeProfile,
      lastError: lastError ?? this.lastError,
    );
  }

  Map<String, Object?> toJson() {
    return {
      'attemptId': attemptId,
      'stage': stage.name,
      'startedAt': startedAt.toIso8601String(),
      'updatedAt': updatedAt.toIso8601String(),
      'imageBytes': imageBytes,
      'visionMode': visionMode,
      'detailLevel': detailLevel,
      'hazardSensitivity': hazardSensitivity,
      'requestedEyeProfile': requestedEyeProfile,
      'lastError': lastError,
    };
  }

  static DescribeAttemptTrace? fromJson(Map<String, Object?> json) {
    final attemptId = json['attemptId'] as String?;
    final stageName = json['stage'] as String?;
    final startedRaw = json['startedAt'] as String?;
    final updatedRaw = json['updatedAt'] as String?;
    if (attemptId == null ||
        stageName == null ||
        startedRaw == null ||
        updatedRaw == null) {
      return null;
    }
    final stage = DescribePipelineStage.values.firstWhere(
      (value) => value.name == stageName,
      orElse: () => DescribePipelineStage.failed,
    );
    return DescribeAttemptTrace(
      attemptId: attemptId,
      stage: stage,
      startedAt: DateTime.tryParse(startedRaw) ?? DateTime.now(),
      updatedAt: DateTime.tryParse(updatedRaw) ?? DateTime.now(),
      imageBytes: json['imageBytes'] as int? ?? 0,
      visionMode: json['visionMode'] as String? ?? 'unknown',
      detailLevel: json['detailLevel'] as String? ?? 'unknown',
      hazardSensitivity: json['hazardSensitivity'] as String? ?? 'unknown',
      requestedEyeProfile: json['requestedEyeProfile'] as String?,
      lastError: json['lastError'] as String?,
    );
  }
}

class DescribeAttemptTraceStore {
  DescribeAttemptTraceStore({SharedPreferences? prefs}) : _prefs = prefs;

  static const String _prefix = 'describe_trace.';

  SharedPreferences? _prefs;

  Future<SharedPreferences> get _preferences async {
    return _prefs ??= await SharedPreferences.getInstance();
  }

  Future<void> save(DescribeAttemptTrace trace) async {
    final prefs = await _preferences;
    final json = trace.toJson();
    await prefs.setString('${_prefix}attemptId', json['attemptId'] as String);
    await prefs.setString('${_prefix}stage', json['stage'] as String);
    await prefs.setString('${_prefix}startedAt', json['startedAt'] as String);
    await prefs.setString('${_prefix}updatedAt', json['updatedAt'] as String);
    await prefs.setInt('${_prefix}imageBytes', json['imageBytes'] as int);
    await prefs.setString('${_prefix}visionMode', json['visionMode'] as String);
    await prefs.setString(
      '${_prefix}detailLevel',
      json['detailLevel'] as String,
    );
    await prefs.setString(
      '${_prefix}hazardSensitivity',
      json['hazardSensitivity'] as String,
    );
    final requestedEyeProfile = json['requestedEyeProfile'] as String?;
    if (requestedEyeProfile == null || requestedEyeProfile.isEmpty) {
      await prefs.remove('${_prefix}requestedEyeProfile');
    } else {
      await prefs.setString(
        '${_prefix}requestedEyeProfile',
        requestedEyeProfile,
      );
    }
    final lastError = json['lastError'] as String?;
    if (lastError == null || lastError.isEmpty) {
      await prefs.remove('${_prefix}lastError');
    } else {
      await prefs.setString('${_prefix}lastError', lastError);
    }
  }

  Future<DescribeAttemptTrace?> loadLast() async {
    try {
      final prefs = await _preferences;
      final raw = <String, Object?>{
        'attemptId': prefs.getString('${_prefix}attemptId'),
        'stage': prefs.getString('${_prefix}stage'),
        'startedAt': prefs.getString('${_prefix}startedAt'),
        'updatedAt': prefs.getString('${_prefix}updatedAt'),
        'imageBytes': prefs.getInt('${_prefix}imageBytes'),
        'visionMode': prefs.getString('${_prefix}visionMode'),
        'detailLevel': prefs.getString('${_prefix}detailLevel'),
        'hazardSensitivity': prefs.getString('${_prefix}hazardSensitivity'),
        'requestedEyeProfile': prefs.getString('${_prefix}requestedEyeProfile'),
        'lastError': prefs.getString('${_prefix}lastError'),
      };
      return DescribeAttemptTrace.fromJson(raw);
    } catch (e) {
      debugPrint('[DescribeTrace] Failed to load trace: $e');
      return null;
    }
  }

  Future<DescribeAttemptTrace?> loadLastUnfinished() async {
    final trace = await loadLast();
    if (trace == null || !trace.unfinished) return null;
    return trace;
  }
}
