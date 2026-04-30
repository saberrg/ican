import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/settings_provider.dart';
import 'app_log_service.dart';
import 'connectivity_service.dart';
import 'on_device_vision_service.dart';
import 'scene_prompt_builder.dart';
import 'vertex_ai_service.dart';

/// User-selectable vision processing mode.
enum VisionMode {
  auto(
    'Auto: cloud reliable',
    'Uses Gemini cloud first; local only when cloud is unavailable',
  ),
  offlineOnly(
    'Offline: device only',
    'Uses on-device Apple Vision and a local model only when healthy',
  ),
  cloudOnly('Cloud', 'Always uses Gemini cloud API');

  const VisionMode(this.label, this.description);
  final String label;
  final String description;
}

/// Which backend was used for the most recent description.
enum VisionBackend {
  cloud,
  foundationModels, // Apple Foundation Models snapshot synthesis.
  vlm, // Local snapshot VLM.
  visionOnly, // Apple Vision template only.
}

class SceneDescriptionResult {
  const SceneDescriptionResult({
    required this.text,
    required this.backend,
    required this.completionMetadata,
  });

  final String text;
  final VisionBackend backend;
  final SceneCompletionMetadata completionMetadata;
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

  /// Serializes local VLM calls so two describe requests can never overlap —
  /// overlapping calls race with the native model lifecycle and have caused
  /// crashes when Live mode stopped mid-inference.
  final _VlmSingleFlight _vlmLock = _VlmSingleFlight();

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
    String userPrompt =
        'What does a blind user need to know right now to move and stay safe? Speak 3 to 5 complete sentences.',
    int maxOutputTokens = 500,
    ScenePromptContext promptContext = const ScenePromptContext(),
    void Function(String status, VisionBackend backend)? onStatusUpdate,
  }) async* {
    final result = switch (_mode) {
      VisionMode.cloudOnly => await describeCloud(
        imageBytes,
        promptContext: promptContext,
      ),
      VisionMode.offlineOnly => await describeOffline(
        imageBytes,
        promptContext: promptContext,
      ),
      VisionMode.auto => await _describeAutoForCompatibility(
        imageBytes,
        promptContext: promptContext,
      ),
    };
    onStatusUpdate?.call(
      'Analyzed with ${result.backend.name}.',
      result.backend,
    );
    yield result.text;
  }

  Future<SceneDescriptionResult> describeCloud(
    Uint8List imageBytes, {
    ScenePromptContext promptContext = const ScenePromptContext(),
  }) async {
    _lastCloudFailure = null;
    _lastBackend = VisionBackend.cloud;
    await cloudService.setModel(AiModel.flash);
    debugPrint('[SceneDescription] Using explicit backend: cloud');
    try {
      final prompt = const ScenePromptBuilder().build(promptContext);
      final chunks = await _describeWithCloud(
        imageBytes,
        systemPrompt: prompt.systemPrompt,
        userPrompt: prompt.userPrompt,
        maxOutputTokens: prompt.maxOutputTokens,
      ).toList();
      return SceneDescriptionResult(
        text: chunks.join().trim(),
        backend: VisionBackend.cloud,
        completionMetadata: _lastCompletionMetadata,
      );
    } on CloudVisionException catch (e) {
      _lastCloudFailure = e;
      rethrow;
    } catch (e) {
      final cloudFailure = _asCloudFailure(e);
      _lastCloudFailure = cloudFailure;
      if (cloudFailure is CloudVisionException) throw cloudFailure;
      throw SceneDescriptionException.cloudVision(cloudFailure);
    }
  }

  Future<SceneDescriptionResult> describeOffline(
    Uint8List imageBytes, {
    ScenePromptContext promptContext = const ScenePromptContext(),
  }) async {
    _lastCompletionMetadata = SceneCompletionMetadata.complete;
    debugPrint('[SceneDescription] Using explicit backend: stable offline');

    VisionAnalysis perception;
    try {
      perception = await _analyzeOfflinePerception(imageBytes);
    } catch (e) {
      throw SceneDescriptionException.localVision(e);
    }

    // Offline always uses the detailed prompt — brief produces output too short
    // for the local model to be worth running.
    final offlineContext = ScenePromptContext(
      detailLevel: DetailLevel.detailed,
      hazardSensitivity: promptContext.hazardSensitivity,
    );
    final prompt = const ScenePromptBuilder().build(offlineContext);

    // Build the rich perception template up front — this is the deterministic
    // spine of the response (hazards + clock positions + objects). We will
    // always speak it; the generative backend adds scene *meaning* on top when
    // it's available, rather than competing with it.
    final templateText = await _templateDescriptionFor(perception, imageBytes);

    String? modelText;
    VisionBackend? modelBackend;

    if (await _isFoundationModelsUsable()) {
      modelText = await _collectLocalGenerativeText(
        label: 'Foundation Models',
        collect: () => _collectFoundationModelsText(
          perception,
          systemPrompt: prompt.systemPrompt,
        ),
      );
      if (modelText != null) modelBackend = VisionBackend.foundationModels;
    }

    if (modelText == null &&
        await _isSmolVlmReadyForDescribe(
          imageBytes,
          systemPrompt: prompt.systemPrompt,
        )) {
      modelText = await _collectLocalGenerativeText(
        label: 'SmolVLM2',
        collect: () => _collectVlmText(
          imageBytes,
          perception,
          systemPrompt: prompt.systemPrompt,
        ),
      );
      if (modelText != null) modelBackend = VisionBackend.vlm;
    }

    final combined = _combineOfflineText(modelText, templateText);
    final backend = modelBackend ?? VisionBackend.visionOnly;
    return _offlineResult(combined, backend);
  }

  /// Collects a local model's output without any "substantiality" gating. The
  /// caller always combines the result with the perception template, so even
  /// a single clean sentence from the model adds real value rather than being
  /// discarded.
  Future<String?> _collectLocalGenerativeText({
    required String label,
    required Future<String> Function() collect,
  }) async {
    try {
      final text = await collect();
      final cleaned = _cleanLocalDescriptionText(text);
      if (cleaned.isEmpty) {
        debugPrint('[SceneDescription] $label produced no usable output');
        return null;
      }
      _lastCompletionMetadata = SceneCompletionMetadata.complete;
      return cleaned;
    } catch (e) {
      debugPrint('[SceneDescription] $label failed; falling back: $e');
      return null;
    }
  }

  /// Merges the generative output with the perception template so the user
  /// always hears the hard facts (hazards, clock positions, objects) even if
  /// the model only managed a single sentence. Generative text leads because
  /// it describes scene *meaning*; template trails with concrete spatial facts.
  static String _combineOfflineText(String? modelText, String templateText) {
    final model = (modelText ?? '').trim();
    final template = templateText.trim();
    if (model.isEmpty) return template;
    if (template.isEmpty || template == 'Scene unclear, try again.') {
      return model;
    }
    final modelLower = model.toLowerCase();
    // If the model's output already covers hazards + clock orientation, don't
    // stack the template on top — stays under the spoken-length budget.
    final modelHasClock =
        modelLower.contains("o'clock") ||
        modelLower.contains('o clock') ||
        modelLower.contains('oclock');
    final templateRedundant =
        template.startsWith('Caution:') &&
        modelLower.contains('caution') &&
        modelHasClock;
    if (templateRedundant) return model;
    // Also skip if the model is already substantial (3+ sentences) AND uses
    // clock positions — the template would just repeat what was said.
    final modelSentences = RegExp(
      r'''[^.!?]+[.!?]+["')\]]*(?=\s|$)''',
    ).allMatches(model).length;
    if (modelSentences >= 3 && modelHasClock) return model;
    final separator =
        model.endsWith('.') || model.endsWith('!') || model.endsWith('?')
        ? ' '
        : '. ';
    return '$model$separator$template';
  }

  Future<SceneDescriptionResult> _describeAutoForCompatibility(
    Uint8List imageBytes, {
    ScenePromptContext promptContext = const ScenePromptContext(),
  }) async {
    final online = await _connectivity.hasInternet();
    if (online) {
      try {
        return await describeCloud(imageBytes, promptContext: promptContext);
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
    return describeOffline(imageBytes, promptContext: promptContext);
  }

  static const Duration _localHealthCheckTimeout = Duration(seconds: 5);

  Future<bool> _basicLocalVisionReady() async {
    Future<bool> check() async {
      try {
        final nativeReady = await onDeviceService.pingNativeChannel();
        if (!nativeReady) return false;
        return await onDeviceService.isAppleVisionAvailable();
      } catch (e) {
        debugPrint('[SceneDescription] Local health check failed: $e');
        return false;
      }
    }

    // Race the check against a hard timeout — a wedged native channel must
    // never block auto-mode from falling through to its next decision.
    return Future.any<bool>([
      check(),
      Future<bool>.delayed(_localHealthCheckTimeout, () {
        debugPrint(
          '[SceneDescription] Local health check exceeded '
          '${_localHealthCheckTimeout.inSeconds}s; treating as unavailable.',
        );
        return false;
      }),
    ]);
  }

  static const Duration _localGenerationTimeout = Duration(seconds: 45);

  Future<bool> _isFoundationModelsUsable() async {
    try {
      return await onDeviceService.isFoundationModelsAvailable();
    } catch (e) {
      debugPrint('[SceneDescription] Foundation Models status failed: $e');
      return false;
    }
  }

  Future<bool> _isSmolVlmReadyForDescribe(
    Uint8List imageBytes, {
    required String systemPrompt,
  }) async {
    try {
      final ready = await onDeviceService.isSmolVlmReadyForDescribe(
        imageBytes,
        systemPrompt: systemPrompt,
      );
      if (!ready) {
        debugPrint('[SceneDescription] SmolVLM2 readiness probe not passed');
      }
      return ready;
    } catch (e) {
      debugPrint('[SceneDescription] SmolVLM2 readiness check failed: $e');
      return false;
    }
  }

  Future<VisionAnalysis> _analyzeOfflinePerception(Uint8List imageBytes) async {
    try {
      return await onDeviceService.analyzeScene(imageBytes);
    } catch (e, st) {
      debugPrint(
        '[SceneDescription] Full offline perception unavailable '
        '(${e.runtimeType}); using Apple Vision basics: $e\n$st',
      );
      return onDeviceService.analyzeWithVision(imageBytes);
    }
  }

  /// Returns the best template description available. If the perception we have
  /// is only the basic Apple Vision path, gives the rich YOLO+depth path one
  /// more chance before committing to the sparse template.
  Future<String> _templateDescriptionFor(
    VisionAnalysis perception,
    Uint8List imageBytes,
  ) async {
    if (perception is ScenePerceptionResult) {
      return perception.toTemplateDescription();
    }
    try {
      final richer = await onDeviceService.analyzeScene(imageBytes);
      return richer.toTemplateDescription();
    } catch (e) {
      debugPrint(
        '[SceneDescription] Rich-template second chance failed '
        '(${e.runtimeType}); falling back to Apple Vision template: $e',
      );
    }
    return perception.toTemplateDescription();
  }

  Future<String> _collectFoundationModelsText(
    VisionAnalysis perception, {
    required String systemPrompt,
  }) async {
    final context = perception.toPromptContext();
    return _collectLocalTokenStream(
      onDeviceService.synthesizeWithFoundationModels(
        context,
        systemPrompt: systemPrompt,
      ),
      label: 'Foundation Models',
    );
  }

  Future<String> _collectVlmText(
    Uint8List imageBytes,
    VisionAnalysis perception, {
    required String systemPrompt,
  }) {
    final context = perception.toPromptContext();
    final enhancedPrompt = context.isNotEmpty
        ? '$systemPrompt\n\nUse the sensor context below for hazards, clock positions, depth, people, and visible text. Do not ignore it. Produce the full requested 3 to 5 sentence answer.\n\n$context'
        : systemPrompt;
    return _vlmLock.run(
      () => _collectLocalTokenStream(
        onDeviceService.describeWithVlm(
          imageBytes,
          systemPrompt: enhancedPrompt,
          visionContext: context.isEmpty ? null : context,
        ),
        label: 'SmolVLM2',
      ),
    );
  }

  /// Cancel any in-flight local VLM generation. Used by Live mode on stop to
  /// avoid the native model being torn down while inference is mid-stream.
  void cancelActiveLocalGeneration() {
    _vlmLock.cancel();
  }

  Future<String> _collectLocalTokenStream(
    Stream<String> stream, {
    required String label,
  }) {
    final completer = Completer<String>();
    final chunks = <String>[];
    StreamSubscription<String>? subscription;
    late final Timer timeout;

    void completeError(Object error, [StackTrace? stackTrace]) {
      if (completer.isCompleted) return;
      completer.completeError(error, stackTrace);
    }

    timeout = Timer(_localGenerationTimeout, () {
      unawaited(subscription?.cancel());
      completeError(
        TimeoutException(
          '$label did not produce a complete local description in time.',
          _localGenerationTimeout,
        ),
      );
    });

    subscription = stream.listen(
      chunks.add,
      onError: completeError,
      onDone: () {
        if (!completer.isCompleted) {
          completer.complete(chunks.join());
        }
      },
      cancelOnError: true,
    );

    return completer.future.whenComplete(() {
      timeout.cancel();
      unawaited(subscription?.cancel());
    });
  }

  SceneDescriptionResult _offlineResult(String text, VisionBackend backend) {
    _lastBackend = backend;
    _lastCompletionMetadata = SceneCompletionMetadata.complete;
    return SceneDescriptionResult(
      text: _cleanLocalDescriptionText(text),
      backend: backend,
      completionMetadata: SceneCompletionMetadata.complete,
    );
  }

  static String _cleanLocalDescriptionText(String text) {
    final stripped = _stripCloudMetaText(text);
    final normalized = stripped
        .replaceAll(RegExp(r'^[\s\-\*]+', multiLine: true), '')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    if (normalized.isEmpty) return '';
    return _ensureSentencePunctuation(normalized);
  }

  // Single-backend entry points for diagnostics.

  Stream<String> describeWithGemini(
    Uint8List imageBytes, {
    required String systemPrompt,
    String userPrompt =
        'What does a blind user need to know right now to move and stay safe? Speak 3 to 5 complete sentences.',
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
    final ready = await onDeviceService.isSmolVlmReadyForDescribe(
      imageBytes,
      systemPrompt: systemPrompt,
    );
    if (!ready) {
      throw StateError('SmolVLM2 has not passed the readiness probe.');
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
    final cleanedFirstText = _stripCloudMetaText(firstText);
    if (firstFinishReason != 'MAX_TOKENS') {
      final rescued = _hasIncompleteFinalSentence(cleanedFirstText)
          ? _rescueTruncatedCloudText(cleanedFirstText)
          : _CloudRescueResult(cleanedFirstText, 'complete');
      if (rescued.text.isEmpty) {
        throw CloudVisionException.malformedResponse(
          'Gemini completed before a useful spoken sentence was available.',
        );
      }
      _recordCloudLog(
        'Gemini final rescue=${rescued.strategy} truncated=false '
        'finishReason=${firstFinishReason ?? "none"}',
      );
      return _CloudDescriptionResult(
        rescued.text,
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

    final needsContinuation = cleanedFirstText.isNotEmpty;
    if (!needsContinuation) {
      _recordCloudLog(
        'Gemini final rescue=empty truncated=true '
        'finishReason=${firstFinishReason ?? "none"}',
      );
      throw CloudVisionException.malformedResponse(
        'Gemini stopped before a useful spoken sentence was available.',
      );
    }

    try {
      _recordCloudLog(
        'Gemini retry requested. firstFinishReason=${firstFinishReason ?? "none"} '
        'firstChars=${cleanedFirstText.length}',
      );
      final continuation = await _collectCloudPass(
        imageBytes,
        systemPrompt: systemPrompt,
        userPrompt: _continuationPrompt(cleanedFirstText, originalUserPrompt),
        maxOutputTokens: 384,
      );
      final cleanedContinuation = _stripCloudMetaText(continuation.text);
      final combined = _joinContinuation(cleanedFirstText, cleanedContinuation);
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
      final rescued = _rescueTruncatedCloudText(cleanedFirstText);
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
      'Continue the visual scene description in 1-2 complete spoken sentences. Use plain speech, add only new visible details, and do not discuss the writing process.',
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

  static String _stripCloudMetaText(String text) {
    final normalized = text.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (normalized.isEmpty) return '';
    final kept = <String>[];
    final matches = RegExp(
      r'''[^.!?]+(?:[.!?]+["')\]]*)?''',
    ).allMatches(normalized);
    for (final match in matches) {
      final sentence = match.group(0)?.trim() ?? '';
      if (sentence.isEmpty) continue;
      if (_isCloudMetaSentence(sentence)) continue;
      kept.add(sentence);
    }
    return kept.join(' ').trim();
  }

  static bool _isCloudMetaSentence(String sentence) {
    final lower = sentence.toLowerCase();
    return RegExp(
          r'\b(previous|prior)\s+(response|answer|description)\b',
        ).hasMatch(lower) ||
        RegExp(
          r'\b(response|answer|description|output)\s+(was|is|may be|might be|seems)?\s*(cut off|truncated|incomplete)\b',
        ).hasMatch(lower) ||
        RegExp(r'\b(token limit|max[_ -]?tokens?)\b').hasMatch(lower) ||
        RegExp(
          r'\b(continue|continuation)\s+(the\s+)?(response|answer)\b',
        ).hasMatch(lower) ||
        RegExp(r'\bwriting process\b').hasMatch(lower) ||
        // Meta openings the new prompt bans outright — drop them if a model
        // slips one in rather than shipping "I see a street." to TTS.
        RegExp(r'\bi\s+(see|can\s+see|notice|observe)\b').hasMatch(lower) ||
        RegExp(
          r'\b(the|this)\s+(image|photo|picture|scene)\s+shows\b',
        ).hasMatch(lower) ||
        RegExp(
          r'\b(it\s+looks\s+like|in\s+this\s+(image|photo|picture))\b',
        ).hasMatch(lower) ||
        RegExp(r'\bas\s+an\s+ai\b').hasMatch(lower) ||
        RegExp(r"\b(cannot|can't)\s+(see|determine|tell)\b").hasMatch(lower);
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

  /// Foundation Models path: Apple Vision facts -> Apple LLM synthesis.
  Stream<String> _describeWithFoundationModels(
    Uint8List imageBytes, {
    required String systemPrompt,
  }) async* {
    final perception = await onDeviceService.analyzeWithVision(imageBytes);
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

  /// VLM path: Apple Vision context fed into the local snapshot VLM.
  ///
  /// When [allowTemplateFallback] is true (the default auto-mode path) the
  /// stream *never* throws once perception has succeeded: VLM crashes or
  /// timeouts downgrade to the Layer 1 template so a blind user always hears
  /// something useful. The diagnostic-direct path on the developer screen
  /// sets the flag to false so raw errors surface.
  Stream<String> _describeWithVlm(
    Uint8List imageBytes, {
    required String systemPrompt,
    bool allowTemplateFallback = true,
  }) async* {
    VisionAnalysis? perception;
    try {
      perception = await onDeviceService.analyzeWithVision(imageBytes);
    } catch (e) {
      debugPrint('[SceneDescription] Perception failed before VLM: $e');
      if (!allowTemplateFallback) rethrow;
      yield 'Scene analysis unavailable on device right now.';
      return;
    }
    final context = perception.toPromptContext();

    debugPrint('[SceneDescription] VLM context: $context');

    final enhancedPrompt = context.isNotEmpty
        ? '$systemPrompt\n\n$context\n\nDescribe this scene incorporating the context above. Produce the full requested 3 to 5 complete spoken sentences.'
        : systemPrompt;

    var gotTokens = false;
    try {
      await for (final token in onDeviceService.describeWithVlm(
        imageBytes,
        systemPrompt: enhancedPrompt,
        visionContext: context.isEmpty ? null : context,
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

String _spokenSpatialLabel(SpatialObjectData o) {
  final clock = 'at ${o.clockPosition} o\'clock';
  final tier = o.distanceTier;
  return tier == null ? '${o.label} $clock' : '${o.label} $clock, $tier';
}

String _joinSpoken(List<String> parts) {
  if (parts.isEmpty) return '';
  if (parts.length == 1) return parts.first;
  if (parts.length == 2) return '${parts[0]} and ${parts[1]}';
  return '${parts.sublist(0, parts.length - 1).join(', ')}, and ${parts.last}';
}

extension VisionAnalysisTemplate on VisionAnalysis {
  /// Speech-natural description built from Apple Vision facts alone.
  /// Hazards first, skip anything we don't have, never apologize.
  String toTemplateDescription() {
    final parts = <String>[];

    if (sceneClassification != 'unknown' && sceneConfidence > 0.15) {
      final label = sceneClassification.replaceAll('_', ' ');
      parts.add('You appear to be in a $label setting.');
    }

    if (personCount > 0) {
      parts.add(
        personCount == 1
            ? '1 person is detected nearby.'
            : '$personCount people are detected nearby.',
      );
    }

    if (ocrTexts.isNotEmpty) {
      if (ocrTexts.length == 1) {
        parts.add('Text reads: ${ocrTexts.first}.');
      } else {
        parts.add('Visible text includes: ${ocrTexts.take(3).join(', ')}.');
      }
    }

    if (parts.isEmpty) return 'Scene unclear, try again.';
    return parts.join(' ');
  }
}

extension ScenePerceptionResultTemplate on ScenePerceptionResult {
  /// Speech-natural description built from the full perception layer
  /// (Apple Vision + YOLO + Depth). Hazards first, clock positions, no filler.
  String toTemplateDescription() {
    final parts = <String>[];

    // 1. Hazards first — anything close with a depth reading.
    final close = detectedObjects
        .where((o) => (o.relativeDepth ?? 1.0) < 0.50)
        .take(3)
        .map(_spokenSpatialLabel)
        .toList();
    if (close.isNotEmpty) {
      parts.add('Caution: ${_joinSpoken(close)}.');
    }

    // 2. Where you are.
    if (sceneClassification != 'unknown' && sceneConfidence > 0.15) {
      final label = sceneClassification.replaceAll('_', ' ');
      parts.add('You appear to be in a $label setting.');
    }

    // 3. People — only mention if not already called out as a close object.
    final alreadyCalled = close.any((s) => s.startsWith('person'));
    if (personCount > 0 && !alreadyCalled) {
      if (personCount == 1 && personRects.isNotEmpty) {
        final r = personRects.first;
        final cx = (r['x'] ?? 0.5) + ((r['w'] ?? 0) / 2);
        final clock = _clockFromCx(cx);
        parts.add("1 person is detected nearby at $clock o'clock.");
      } else if (personCount == 1) {
        parts.add('1 person is detected nearby.');
      } else {
        parts.add('$personCount people are detected nearby.');
      }
    }

    // 4. Readable text.
    if (ocrTexts.isNotEmpty) {
      if (ocrTexts.length == 1) {
        parts.add('Text reads: ${ocrTexts.first}.');
      } else {
        parts.add('Visible text includes: ${ocrTexts.take(3).join(', ')}.');
      }
    }

    // 5. Other objects within reasonable range, compact list.
    final others = detectedObjects
        .where((o) => (o.relativeDepth ?? 0.0) >= 0.50)
        .take(4)
        .map(_spokenSpatialLabel)
        .toList();
    if (others.isNotEmpty) {
      parts.add('Also nearby: ${_joinSpoken(others)}.');
    }

    if (parts.isEmpty) return 'Scene unclear, try again.';
    return parts.take(5).join(' ');
  }

  static int _clockFromCx(double cx) {
    if (cx < 0.17) return 10;
    if (cx < 0.34) return 11;
    if (cx < 0.66) return 12;
    if (cx < 0.83) return 1;
    return 2;
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

/// Queues local VLM calls so only one runs at a time. When [cancel] is called
/// while a job is active, the in-flight future completes with an empty string
/// and the next queued caller proceeds. This guards the native model lifecycle
/// — overlapping native calls have been observed to crash the app.
class _VlmSingleFlight {
  Future<String>? _active;
  Completer<String>? _activeCompleter;

  Future<String> run(Future<String> Function() job) async {
    // Wait for any prior call to finish before starting a new one.
    final prior = _active;
    if (prior != null) {
      try {
        await prior;
      } catch (_) {
        // Previous caller's error is not ours to surface.
      }
    }

    final completer = Completer<String>();
    _activeCompleter = completer;
    _active = completer.future;

    try {
      final result = await job();
      if (!completer.isCompleted) completer.complete(result);
    } catch (e, st) {
      if (!completer.isCompleted) completer.completeError(e, st);
    } finally {
      if (identical(_activeCompleter, completer)) {
        _activeCompleter = null;
        _active = null;
      }
    }
    return completer.future;
  }

  /// Force the currently in-flight job to resolve with an empty string.
  void cancel() {
    final completer = _activeCompleter;
    if (completer != null && !completer.isCompleted) {
      completer.complete('');
    }
    _activeCompleter = null;
    _active = null;
  }
}
