import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'app_log_service.dart';
import 'connectivity_service.dart';
import 'on_device_vision_service.dart';
import 'vertex_ai_service.dart';

/// User-selectable vision processing mode.
enum VisionMode {
  auto(
    'Auto: cloud reliable',
    'Uses Gemini cloud first; local only when cloud is unavailable',
  ),
  offlineOnly('Local basic vision', 'Uses on-device Apple Vision cues'),
  cloudOnly('Cloud', 'Always uses Gemini cloud API');

  const VisionMode(this.label, this.description);
  final String label;
  final String description;
}

/// Which backend was used for the most recent description.
enum VisionBackend {
  cloud,
  foundationModels, // Apple Foundation Models (iOS 26+)
  vlm, // SmolVLM2-500M via llama.cpp mtmd
  visionOnly, // Layer 1 template only
}

enum SceneDescriptionFailureStage { cloudVision, localVision }

class SceneCompletionMetadata {
  const SceneCompletionMetadata({
    this.finishReason,
    required this.wasTruncated,
    required this.didRetryContinuation,
    required this.diagnostic,
  });

  final String? finishReason;
  final bool wasTruncated;
  final bool didRetryContinuation;
  final String diagnostic;

  static const complete = SceneCompletionMetadata(
    wasTruncated: false,
    didRetryContinuation: false,
    diagnostic: 'complete',
  );
}

class SceneDescriptionException implements Exception {
  const SceneDescriptionException._(
    this.stage,
    this.message,
    this.cause, {
    this.cloudFailure,
  });

  factory SceneDescriptionException.localVision(
    Object cause, {
    Object? cloudFailure,
  }) {
    return SceneDescriptionException._(
      SceneDescriptionFailureStage.localVision,
      'Local vision failed',
      cause,
      cloudFailure: cloudFailure,
    );
  }

  factory SceneDescriptionException.cloudVision(Object cause) {
    return SceneDescriptionException._(
      SceneDescriptionFailureStage.cloudVision,
      'Cloud vision failed',
      cause,
    );
  }

  final SceneDescriptionFailureStage stage;
  final String message;
  final Object cause;
  final Object? cloudFailure;

  String get userMessage {
    switch (stage) {
      case SceneDescriptionFailureStage.cloudVision:
        final failure = cause;
        if (failure is CloudVisionException) return failure.userMessage;
        return 'Cloud vision failed';
      case SceneDescriptionFailureStage.localVision:
        final failure = cause;
        if (failure is LocalVisionException) return failure.userMessage;
        return 'Local vision failed';
    }
  }

  @override
  String toString() => '$message: $cause';
}

/// Unified scene description service.
/// Selects the best available backend and streams text chunks to the caller.
class SceneDescriptionService extends ChangeNotifier {
  SceneDescriptionService({
    required this.cloudService,
    required this.onDeviceService,
    ConnectivityService? connectivityService,
  }) : _connectivity = connectivityService ?? ConnectivityService();

  final VertexAiService cloudService;
  final OnDeviceVisionService onDeviceService;
  final ConnectivityService _connectivity;

  static const String _prefsKey = 'vision_mode';

  VisionMode _mode = VisionMode.auto;
  VisionMode get mode => _mode;

  VisionBackend? _lastBackend;
  VisionBackend? get lastBackend => _lastBackend;

  Object? _lastCloudFailure;
  Object? get lastCloudFailure => _lastCloudFailure;

  SceneCompletionMetadata _lastCompletionMetadata =
      SceneCompletionMetadata.complete;
  SceneCompletionMetadata get lastCompletionMetadata => _lastCompletionMetadata;

  /// Load saved mode preference. Call once at app startup.
  Future<void> loadSavedMode() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final saved = prefs.getString(_prefsKey);
      if (saved != null) {
        _mode = VisionMode.values.firstWhere(
          (m) => m.name == saved,
          orElse: () => VisionMode.auto,
        );
      }
    } catch (_) {}
  }

  /// Switch vision mode and persist.
  Future<void> setMode(VisionMode newMode) async {
    if (_mode == newMode) return;
    _mode = newMode;
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_prefsKey, newMode.name);
    } catch (_) {}
    debugPrint('[SceneDescription] Mode changed to: ${newMode.name}');
  }

  /// Describe a scene from a JPEG image.
  /// Yields text chunks for the sentence-splitting TTS loop in HomeViewModel.
  Stream<String> describeScene(
    Uint8List imageBytes, {
    required String systemPrompt,
    String userPrompt = 'Describe what you see.',
    int maxOutputTokens = 500,
    void Function(String status, VisionBackend backend)? onStatusUpdate,
  }) async* {
    _lastCloudFailure = null;

    switch (_mode) {
      case VisionMode.cloudOnly:
        _lastBackend = VisionBackend.cloud;
        debugPrint('[SceneDescription] Using backend: cloud');
        onStatusUpdate?.call(
          'Analyzing with ${cloudService.model.label}...',
          VisionBackend.cloud,
        );
        yield* _describeWithCloud(
          imageBytes,
          systemPrompt: systemPrompt,
          userPrompt: userPrompt,
          maxOutputTokens: maxOutputTokens,
        );

      case VisionMode.offlineOnly:
        yield* _describeWithBestLocal(
          imageBytes,
          systemPrompt: systemPrompt,
          onStatusUpdate: onStatusUpdate,
        );

      case VisionMode.auto:
        final online = await _connectivity.hasInternet();
        if (online) {
          _lastBackend = VisionBackend.cloud;
          debugPrint('[SceneDescription] Using backend: cloud');
          onStatusUpdate?.call(
            'Analyzing with ${cloudService.model.label}...',
            VisionBackend.cloud,
          );
          try {
            await for (final chunk in _describeWithCloud(
              imageBytes,
              systemPrompt: systemPrompt,
              userPrompt: userPrompt,
              maxOutputTokens: maxOutputTokens,
            )) {
              yield chunk;
            }
            return;
          } catch (e) {
            _lastCloudFailure = _asCloudFailure(e);
            debugPrint('[SceneDescription] Cloud failed: $_lastCloudFailure');
          }
        }

        final localReady = await _basicLocalVisionReady();
        if (!localReady) {
          throw SceneDescriptionException.localVision(
            const LocalVisionException(
              'Local L02',
              'Local vision is unavailable until Apple Vision passes health checks.',
            ),
            cloudFailure: _lastCloudFailure,
          );
        }

        yield* _describeWithBestLocal(
          imageBytes,
          systemPrompt: systemPrompt,
          onStatusUpdate: onStatusUpdate,
          cloudFailure: _lastCloudFailure,
        );
    }
  }

  Future<bool> _basicLocalVisionReady() async {
    try {
      final nativeReady = await onDeviceService.pingNativeChannel();
      if (!nativeReady) return false;
      return onDeviceService.isAppleVisionAvailable();
    } catch (e) {
      debugPrint('[SceneDescription] Local health check failed: $e');
      return false;
    }
  }

  // Single-backend entry points for diagnostics.

  Stream<String> describeWithGemini(
    Uint8List imageBytes, {
    required String systemPrompt,
    String userPrompt = 'Describe what you see.',
    int maxOutputTokens = 500,
  }) {
    return _describeWithCloud(
      imageBytes,
      systemPrompt: systemPrompt,
      userPrompt: userPrompt,
      maxOutputTokens: maxOutputTokens,
    );
  }

  Stream<String> describeWithFoundationModels(
    Uint8List imageBytes, {
    required String systemPrompt,
  }) {
    return _describeWithFoundationModels(
      imageBytes,
      systemPrompt: systemPrompt,
    );
  }

  Stream<String> describeWithSmolVLM(
    Uint8List imageBytes, {
    required String systemPrompt,
  }) async* {
    final status = await onDeviceService.getModelStatus();
    if (status == ModelStatus.notAvailable) {
      throw StateError('SmolVLM2 runtime is not linked into this build.');
    }
    if (status == ModelStatus.notDownloaded) {
      throw StateError('SmolVLM2 model files are not downloaded.');
    }
    if (status == ModelStatus.downloading) {
      throw StateError('SmolVLM2 model download is still in progress.');
    }
    if (status == ModelStatus.ready) {
      final loaded = await onDeviceService.loadVlmModel();
      if (!loaded) {
        throw StateError(
          'SmolVLM2 model files are present but failed to load.',
        );
      }
    }
    yield* _describeWithVlm(
      imageBytes,
      systemPrompt: systemPrompt,
      allowTemplateFallback: false,
    );
  }

  Stream<String> describeWithVisionTemplate(Uint8List imageBytes) {
    return _describeWithVisionOnly(imageBytes);
  }

  Future<VisionBackend> _bestOfflineBackend() async {
    final fmAvailable = await onDeviceService.isFoundationModelsAvailable();
    if (fmAvailable) return VisionBackend.foundationModels;

    final status = await onDeviceService.getModelStatus();
    if (status == ModelStatus.loaded) return VisionBackend.vlm;
    if (status == ModelStatus.ready) {
      final loaded = await onDeviceService.loadVlmModel();
      if (loaded) return VisionBackend.vlm;
    }

    return VisionBackend.visionOnly;
  }

  Stream<String> _describeWithBestLocal(
    Uint8List imageBytes, {
    required String systemPrompt,
    required void Function(String status, VisionBackend backend)?
    onStatusUpdate,
    Object? cloudFailure,
  }) async* {
    try {
      final backend = await _bestOfflineBackend();
      _lastBackend = backend;
      debugPrint('[SceneDescription] Using backend: ${backend.name}');
      _sendStatusUpdate(backend, onStatusUpdate);
      yield* _describeWithBackend(
        backend,
        imageBytes,
        systemPrompt: systemPrompt,
      );
    } catch (e) {
      debugPrint('[SceneDescription] Local vision failed: $e');
      throw SceneDescriptionException.localVision(
        e,
        cloudFailure: cloudFailure,
      );
    }
  }

  void _sendStatusUpdate(
    VisionBackend backend,
    void Function(String status, VisionBackend backend)? onStatusUpdate,
  ) {
    switch (backend) {
      case VisionBackend.cloud:
        onStatusUpdate?.call(
          'Analyzing with ${cloudService.model.label}...',
          backend,
        );
      case VisionBackend.foundationModels:
        onStatusUpdate?.call('Analyzing on-device...', backend);
      case VisionBackend.vlm:
        onStatusUpdate?.call('Analyzing offline with AI model...', backend);
      case VisionBackend.visionOnly:
        onStatusUpdate?.call('Reading scene...', backend);
    }
  }

  Stream<String> _describeWithBackend(
    VisionBackend backend,
    Uint8List imageBytes, {
    required String systemPrompt,
  }) {
    switch (backend) {
      case VisionBackend.cloud:
        return _describeWithCloud(
          imageBytes,
          systemPrompt: systemPrompt,
          userPrompt: 'Describe what you see.',
          maxOutputTokens: 500,
        );
      case VisionBackend.foundationModels:
        return _describeWithFoundationModels(
          imageBytes,
          systemPrompt: systemPrompt,
        );
      case VisionBackend.vlm:
        return _describeWithVlm(imageBytes, systemPrompt: systemPrompt);
      case VisionBackend.visionOnly:
        return _describeWithVisionOnly(imageBytes);
    }
  }

  Object _asCloudFailure(Object error) {
    if (error is CloudVisionException) return error;
    if (error is SceneDescriptionException) return error;
    return CloudVisionException.network(error);
  }

  /// Cloud path: collect Gemini output to completion before yielding text.
  Stream<String> _describeWithCloud(
    Uint8List imageBytes, {
    required String systemPrompt,
    required String userPrompt,
    required int maxOutputTokens,
  }) async* {
    final result = await _completeCloudDescription(
      imageBytes,
      systemPrompt: systemPrompt,
      userPrompt: userPrompt,
      maxOutputTokens: maxOutputTokens,
    );
    _lastCompletionMetadata = result.metadata;
    yield result.text;
  }

  Future<_CloudDescriptionResult> _completeCloudDescription(
    Uint8List imageBytes, {
    required String systemPrompt,
    required String userPrompt,
    required int maxOutputTokens,
  }) async {
    try {
      final first = await _collectCloudPass(
        imageBytes,
        systemPrompt: systemPrompt,
        userPrompt: userPrompt,
        maxOutputTokens: maxOutputTokens,
      );
      return _finishCloudText(
        first.text,
        first.finishReason,
        imageBytes: imageBytes,
        systemPrompt: systemPrompt,
        originalUserPrompt: userPrompt,
      );
    } on CloudVisionException catch (e) {
      if (e.kind != CloudVisionFailureKind.timeout) rethrow;
      final retry = await _collectCloudPass(
        imageBytes,
        systemPrompt: systemPrompt,
        userPrompt: userPrompt,
        maxOutputTokens: maxOutputTokens,
      );
      final finished = await _finishCloudText(
        retry.text,
        retry.finishReason,
        imageBytes: imageBytes,
        systemPrompt: systemPrompt,
        originalUserPrompt: userPrompt,
        didRetryAfterTimeout: true,
      );
      return finished;
    }
  }

  Future<_CloudPass> _collectCloudPass(
    Uint8List imageBytes, {
    required String systemPrompt,
    required String userPrompt,
    required int maxOutputTokens,
  }) async {
    final chunks = await cloudService
        .streamContentFromImage(
          imageBytes,
          systemPrompt: systemPrompt,
          userPrompt: userPrompt,
          maxOutputTokens: maxOutputTokens,
        )
        .toList();
    final pass = _CloudPass(
      chunks.join().trim(),
      cloudService.lastFinishReason,
    );
    _recordCloudLog(
      'Gemini pass finishReason=${pass.finishReason ?? "none"} '
      'tokens=$maxOutputTokens textChars=${pass.text.length}',
    );
    return pass;
  }

  Future<_CloudDescriptionResult> _finishCloudText(
    String firstText,
    String? firstFinishReason, {
    required Uint8List imageBytes,
    required String systemPrompt,
    required String originalUserPrompt,
    bool didRetryAfterTimeout = false,
  }) async {
    final needsContinuation =
        firstFinishReason == 'MAX_TOKENS' ||
        _hasIncompleteFinalSentence(firstText);
    if (!needsContinuation) {
      _recordCloudLog(
        'Gemini final rescue=not-needed truncated=false '
        'finishReason=${firstFinishReason ?? "none"}',
      );
      return _CloudDescriptionResult(
        firstText,
        SceneCompletionMetadata(
          finishReason: firstFinishReason,
          wasTruncated: false,
          didRetryContinuation: didRetryAfterTimeout,
          diagnostic: didRetryAfterTimeout
              ? 'Retried Gemini after timeout.'
              : 'Gemini completed normally.',
        ),
      );
    }

    try {
      _recordCloudLog(
        'Gemini retry requested. firstFinishReason=${firstFinishReason ?? "none"} '
        'firstChars=${firstText.length}',
      );
      final continuation = await _collectCloudPass(
        imageBytes,
        systemPrompt: systemPrompt,
        userPrompt: _continuationPrompt(firstText, originalUserPrompt),
        maxOutputTokens: 384,
      );
      final combined = _joinContinuation(firstText, continuation.text);
      final stillTruncated =
          continuation.finishReason == 'MAX_TOKENS' ||
          _hasIncompleteFinalSentence(combined);
      final rescued = stillTruncated
          ? _rescueTruncatedCloudText(combined)
          : _CloudRescueResult(combined, 'complete');
      _recordCloudLog(
        'Gemini rescue=${rescued.strategy} truncated=$stillTruncated '
        'finishReason=${continuation.finishReason ?? firstFinishReason ?? "none"} '
        'textChars=${rescued.text.length}',
      );
      if (rescued.text.isEmpty) {
        throw CloudVisionException.malformedResponse(
          'Gemini stopped before a useful spoken sentence was available.',
        );
      }
      return _CloudDescriptionResult(
        rescued.text,
        SceneCompletionMetadata(
          finishReason: continuation.finishReason ?? firstFinishReason,
          wasTruncated: stillTruncated,
          didRetryContinuation: true,
          diagnostic: stillTruncated
              ? 'Gemini output was cut off after continuation retry.'
              : 'Gemini continuation completed.',
        ),
      );
    } on CloudVisionException {
      final rescued = _rescueTruncatedCloudText(firstText);
      _recordCloudLog(
        'Gemini continuation failed. rescue=${rescued.strategy} '
        'textChars=${rescued.text.length}',
      );
      if (rescued.text.isEmpty) {
        throw CloudVisionException.malformedResponse(
          'Gemini continuation failed before useful spoken text was available.',
        );
      }
      return _CloudDescriptionResult(
        rescued.text,
        SceneCompletionMetadata(
          finishReason: firstFinishReason,
          wasTruncated: true,
          didRetryContinuation: true,
          diagnostic: 'Gemini continuation retry failed.',
        ),
      );
    }
  }

  static String _continuationPrompt(String partialText, String originalPrompt) {
    return [
      originalPrompt,
      'The previous response may be cut off. Finish as 1-2 complete spoken sentences in plain speech. Do not repeat completed sentences, and do not mention that anything was cut off.',
      'Partial description: "$partialText"',
    ].join('\n\n');
  }

  static bool _hasIncompleteFinalSentence(String text) {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return true;
    return !RegExp(r'''[.!?]["')\]]*$''').hasMatch(trimmed);
  }

  static String _joinContinuation(String first, String continuation) {
    final a = first.trim();
    final b = continuation.trim();
    if (a.isEmpty) return b;
    if (b.isEmpty) return a;
    return '$a $b'.replaceAll(RegExp(r'\s+'), ' ').trim();
  }

  static _CloudRescueResult _rescueTruncatedCloudText(String text) {
    final complete = _completeSentencePrefix(text);
    if (complete.isEmpty) {
      final partial = _cleanUsefulPartial(text);
      if (partial.isEmpty) return const _CloudRescueResult('', 'empty');
      return _CloudRescueResult(
        _ensureSentencePunctuation(partial),
        'punctuated-partial',
      );
    }
    return _CloudRescueResult(complete, 'complete-prefix');
  }

  static String _completeSentencePrefix(String text) {
    final trimmed = text.trim();
    final matches = RegExp(r'''[.!?]["')\]]*(?=\s|$)''').allMatches(trimmed);
    if (matches.isEmpty) return '';
    return trimmed.substring(0, matches.last.end).trim();
  }

  static String _cleanUsefulPartial(String text) {
    final trimmed = text
        .replaceAll(RegExp(r'\s+'), ' ')
        .replaceAll(RegExp(r'["“”]+$'), '')
        .trim();
    if (trimmed.isEmpty) return '';
    if (!RegExp(r'[A-Za-z0-9]').hasMatch(trimmed)) return '';
    final words = RegExp(r"[A-Za-z0-9']+").allMatches(trimmed).length;
    if (words < 3) return '';
    return trimmed;
  }

  static String _ensureSentencePunctuation(String text) {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return '';
    if (RegExp(r'''[.!?]["')\]]*$''').hasMatch(trimmed)) return trimmed;
    return '$trimmed.';
  }

  static void _recordCloudLog(String message) {
    unawaited(AppLogService.instance.record(message, source: 'describe'));
  }

  /// Foundation Models path: Layer 1 perception -> Apple LLM synthesis.
  Stream<String> _describeWithFoundationModels(
    Uint8List imageBytes, {
    required String systemPrompt,
  }) async* {
    final perception = await onDeviceService.analyzeScene(imageBytes);
    final context = perception.toPromptContext();

    debugPrint('[SceneDescription] FM context: $context');

    var gotTokens = false;
    try {
      await for (final token in onDeviceService.synthesizeWithFoundationModels(
        context,
        systemPrompt: systemPrompt,
      )) {
        gotTokens = true;
        yield token;
      }
    } catch (e) {
      debugPrint('[SceneDescription] Foundation Models failed: $e');
    }

    if (!gotTokens) {
      debugPrint('[SceneDescription] FM produced no output; using template');
      yield perception.toTemplateDescription();
    }
  }

  /// VLM path: Layer 1 perception context fed into SmolVLM2.
  Stream<String> _describeWithVlm(
    Uint8List imageBytes, {
    required String systemPrompt,
    bool allowTemplateFallback = true,
  }) async* {
    final perception = await onDeviceService.analyzeScene(imageBytes);
    final context = perception.toPromptContext();

    debugPrint('[SceneDescription] VLM context: $context');

    final enhancedPrompt = context.isNotEmpty
        ? '$systemPrompt\n\n$context\n\nDescribe this scene incorporating the context above.'
        : systemPrompt;

    var gotTokens = false;
    try {
      await for (final token in onDeviceService.describeWithVlm(
        imageBytes,
        systemPrompt: enhancedPrompt,
      )) {
        gotTokens = true;
        yield token;
      }
    } catch (e) {
      debugPrint('[SceneDescription] VLM inference failed: $e');
      if (!allowTemplateFallback) rethrow;
    }

    if (!gotTokens) {
      if (!allowTemplateFallback) {
        throw const LocalVisionException(
          'Local L20',
          'SmolVLM2 produced no output.',
        );
      }
      debugPrint('[SceneDescription] VLM produced no output; using template');
      yield perception.toTemplateDescription();
    }
  }

  /// Vision-only path: Layer 1 template, no VLM needed.
  Stream<String> _describeWithVisionOnly(Uint8List imageBytes) async* {
    final analysis = await onDeviceService.analyzeWithVision(imageBytes);
    yield analysis.toTemplateDescription();
  }
}

extension VisionAnalysisTemplate on VisionAnalysis {
  /// Assemble a spoken description from Apple Vision data alone.
  String toTemplateDescription() {
    final sentences = <String>[];

    if (sceneClassification != 'unknown' && sceneConfidence > 0.15) {
      final label = sceneClassification.replaceAll('_', ' ');
      sentences.add('You appear to be in a $label setting.');
    } else {
      sentences.add('The scene could not be clearly identified.');
    }

    if (personCount > 0) {
      final noun = personCount == 1 ? '1 person is' : '$personCount people are';
      sentences.add(
        '${noun[0].toUpperCase()}${noun.substring(1)} detected nearby.',
      );
    }

    if (ocrTexts.isNotEmpty) {
      if (ocrTexts.length == 1) {
        sentences.add('Text reads: ${ocrTexts.first}.');
      } else {
        sentences.add('Visible text includes: ${ocrTexts.take(3).join(', ')}.');
      }
    }

    return sentences.join(' ');
  }
}

extension ScenePerceptionResultTemplate on ScenePerceptionResult {
  /// Assemble a spoken description from Layer 1 data alone.
  String toTemplateDescription() {
    final sentences = <String>[];

    if (sceneClassification != 'unknown' && sceneConfidence > 0.15) {
      final label = sceneClassification.replaceAll('_', ' ');
      sentences.add('You appear to be in a $label setting.');
    } else {
      sentences.add('The scene could not be clearly identified.');
    }

    final close = detectedObjects
        .where((o) => (o.relativeDepth ?? 1.0) < 0.50)
        .toList();
    if (close.isNotEmpty) {
      final descs = close.take(3).map((o) => o.spatialLabel).join(', ');
      sentences.add('Caution: $descs.');
    }

    if (personCount > 0) {
      final noun = personCount == 1 ? '1 person is' : '$personCount people are';
      sentences.add(
        '${noun[0].toUpperCase()}${noun.substring(1)} detected nearby.',
      );
    }

    if (ocrTexts.isNotEmpty) {
      if (ocrTexts.length == 1) {
        sentences.add('Text reads: ${ocrTexts.first}.');
      } else {
        sentences.add('Visible text includes: ${ocrTexts.take(3).join(', ')}.');
      }
    }

    final others = detectedObjects
        .where((o) => (o.relativeDepth ?? 0.0) >= 0.50)
        .take(4);
    if (others.isNotEmpty) {
      sentences.add(
        'Also nearby: ${others.map((o) => o.spatialLabel).join(', ')}.',
      );
    }

    return sentences.join(' ');
  }
}

class _CloudPass {
  const _CloudPass(this.text, this.finishReason);

  final String text;
  final String? finishReason;
}

class _CloudDescriptionResult {
  const _CloudDescriptionResult(this.text, this.metadata);

  final String text;
  final SceneCompletionMetadata metadata;
}

class _CloudRescueResult {
  const _CloudRescueResult(this.text, this.strategy);

  final String text;
  final String strategy;
}
