import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;

import '../protocol/ble_protocol.dart';
import '../models/settings_provider.dart';
import 'ble_service.dart';
import 'livex_stream_service.dart';
import 'on_device_vision_service.dart';
import 'scene_description_service.dart';
import 'tts_service.dart';
import 'udp_frame_service.dart';
import 'vertex_ai_service.dart';

enum LiveDetectionState { idle, starting, running, stopping, error }

/// Progressive-discovery tiers. The controller walks up the ladder while the
/// scene is stable, and resets to [scanning] whenever the scene changes.
enum _DiscoveryTier {
  scanning, // no stable scene yet
  tier1, // spoken: immediate YOLO callout (front-and-center)
  tier2, // spoken: cloud Flash on center crop — details YOLO missed
  tier3, // spoken: cloud Flash on full frame — peripheral/contextual
  exhausted, // nothing left to say; wait for scene change
}

class LiveDetectionController extends ChangeNotifier {
  LiveDetectionController({
    BleService? bleService,
    OnDeviceVisionService? onDeviceService,
    VertexAiService? cloudService,
    SceneDescriptionService? sceneDescriptionService,
    SpeechOutput? ttsService,
    ValueGetter<LiveDetectionVerbosity>? verbosityProvider,
    ValueGetter<LiveCloudPolicy>? cloudPolicyProvider,
    this.intervalMs = 900,
  }) : _ble = bleService ?? BleService.instance,
       _vision = onDeviceService ?? OnDeviceVisionService(),
       _cloud = cloudService,
       _sceneDescription = sceneDescriptionService,
       _tts = ttsService ?? TtsService.instance,
       _verbosityProvider =
           verbosityProvider ?? (() => LiveDetectionVerbosity.full),
       _cloudPolicyProvider =
           cloudPolicyProvider ?? (() => LiveCloudPolicy.hybridOnSceneChange);

  final BleService _ble;
  final OnDeviceVisionService _vision;
  final VertexAiService? _cloud;
  final SceneDescriptionService? _sceneDescription;
  final SpeechOutput _tts;
  final ValueGetter<LiveDetectionVerbosity> _verbosityProvider;
  final ValueGetter<LiveCloudPolicy> _cloudPolicyProvider;
  final int intervalMs;

  // --- Cloud-cost gating --------------------------------------------------
  // Hard ceiling for cloud (Gemini) calls per Live session. Once hit, Tier 2/3
  // are disabled for the rest of the session and only local Tier 1 callouts
  // fire. Users can also pick [LiveCloudPolicy.localOnly] to skip cloud entirely.
  static const int _maxCloudCallsPerSession = 10;
  // Min gap between cloud calls. Kept below _tier3MinHold (5 s) so a single
  // stable scene can still climb Tier 2 → Tier 3 within one scene. The per-
  // session cap + scene-change gating are the real cost ceiling.
  static const Duration _minCloudInterval = Duration(seconds: 4);

  int _cloudCallsThisSession = 0;
  DateTime _lastCloudCallAt = DateTime.fromMillisecondsSinceEpoch(0);

  int get cloudCallsUsed => _cloudCallsThisSession;
  int get cloudCallsMax => _maxCloudCallsPerSession;
  LiveCloudPolicy get cloudPolicy => _cloudPolicyProvider();

  StreamSubscription<Uint8List>? _imageSub;
  StreamSubscription<BleConnectionEvent>? _connectionSub;
  Timer? _cooldownTimer;
  var _state = LiveDetectionState.idle;
  var _busy = false;
  var _skipUntil = DateTime.fromMillisecondsSinceEpoch(0);
  var _consecutiveFailures = 0;
  var _preferFullPerception = true;
  var _basicFallbackFramesRemaining = 0;
  String _lastMessage = '';
  String? _lastError;

  // --- Progressive-discovery state ---------------------------------------
  _DiscoveryTier _tier = _DiscoveryTier.scanning;
  Set<String> _sceneSig = const <String>{}; // current stable scene signature
  Set<String> _pendingSig = const <String>{}; // candidate awaiting stability
  DateTime _sigFirstSeen = DateTime.fromMillisecondsSinceEpoch(0);
  DateTime _lastTierAdvance = DateTime.fromMillisecondsSinceEpoch(0);
  final Set<String> _spokenObjects = <String>{};

  static const int _maxConsecutiveFailures = 3;
  static const int _fullPerceptionRetryFrames = 8;
  static const Duration _analysisTimeout = Duration(milliseconds: 4500);
  static const Duration _failureCooldown = Duration(seconds: 10);

  // Stability: a scene is "stable" once the same signature has held for
  // [_stabilityWindow] and overlaps the prior signature by at least
  // [_sigJaccardThreshold]. Any break resets the ladder.
  static const Duration _stabilityWindow = Duration(milliseconds: 1500);
  static const double _sigJaccardThreshold = 0.70;

  // Minimum gap between tier advances so the user can actually hear each.
  static const Duration _tier2MinHold = Duration(seconds: 3);
  static const Duration _tier3MinHold = Duration(seconds: 5);

  LiveDetectionState get state => _state;
  bool get active =>
      _state == LiveDetectionState.starting ||
      _state == LiveDetectionState.running;
  String get lastMessage => _lastMessage;
  String? get lastError => _lastError;

  /// Yields JPEG frames from whichever live source is currently active:
  /// UDP when [UdpFrameService] is running (WiFi ready), otherwise the BLE
  /// image stream. Re-selects source on every WiFi status transition.
  Stream<Uint8List> get activeFrameStream {
    final ble = BleService.instance;
    final udp = UdpFrameService.instance;

    late StreamController<Uint8List> controller;
    StreamSubscription<Uint8List>? sub;
    StreamSubscription<EyeWifiStatus>? wifiSub;

    void switchSource() {
      sub?.cancel();
      final source = udp.isActive ? udp.frameStream : ble.imageStream;
      sub = source.listen(controller.add, onError: controller.addError);
    }

    controller = StreamController<Uint8List>.broadcast(
      onListen: () {
        switchSource();
        wifiSub = ble.wifiStatusStream.listen((_) => switchSource());
      },
      onCancel: () {
        sub?.cancel();
        wifiSub?.cancel();
        sub = null;
        wifiSub = null;
      },
    );
    return controller.stream;
  }

  Future<void> start() async {
    if (active || _state == LiveDetectionState.stopping) return;
    if (_ble.state != BleConnectionState.connected ||
        !_ble.eyeReadinessStatus.ready) {
      _setError('iCan Eye is not ready for Live Detection.');
      return;
    }

    _setState(LiveDetectionState.starting);
    _lastError = null;
    _busy = false;
    _consecutiveFailures = 0;
    _preferFullPerception = true;
    _basicFallbackFramesRemaining = 0;
    _skipUntil = DateTime.fromMillisecondsSinceEpoch(0);
    _cloudCallsThisSession = 0;
    _lastCloudCallAt = DateTime.fromMillisecondsSinceEpoch(0);
    _resetLadder();

    // Subscribe to activeFrameStream — not _ble.imageStream — so analysis sees
    // UDP frames when WiFi is up. The selector auto-switches BLE↔UDP when the
    // WiFi status flips, so the subscription stays valid across transitions.
    _imageSub = activeFrameStream.listen(
      _handleFrame,
      onError: (Object e) => _setError('Live image stream failed: $e'),
    );
    _connectionSub = _ble.connectionEventStream.listen((event) {
      if (event.deviceKind == BleDeviceKind.eye && !event.ready) {
        unawaited(stop(speak: true, reason: 'iCan Eye disconnected.'));
      }
    });

    try {
      await _ble.setEyeProfile(EyeProfileIndex.fast);
      await _ble.startLiveCapture(intervalMs: intervalMs);
      _setState(LiveDetectionState.running);
      await _safeSpeak('LiveX started.');
    } catch (e) {
      _setError('Live Detection could not start: $e');
      await stop(speak: false);
    }
  }

  Future<void> stop({bool speak = true, String? reason}) async {
    if (_state == LiveDetectionState.idle) return;
    _setState(LiveDetectionState.stopping);
    _busy = false;
    _cooldownTimer?.cancel();
    _cooldownTimer = null;
    await _imageSub?.cancel();
    await _connectionSub?.cancel();
    _imageSub = null;
    _connectionSub = null;
    // Kill any in-flight VLM call so the native model can be torn down safely.
    _sceneDescription?.cancelActiveLocalGeneration();
    try {
      await LiveXStreamService.instance.stopStream();
      await _ble.stopLiveCapture();
    } catch (e) {
      debugPrint('[LiveDetectionController] stop failed: $e');
    }
    _setState(LiveDetectionState.idle);
    _resetLadder();
    if (speak) {
      await _safeSpeak(reason ?? 'Live Detection stopped.');
    }
  }

  void _resetLadder() {
    _tier = _DiscoveryTier.scanning;
    _sceneSig = const <String>{};
    _pendingSig = const <String>{};
    _sigFirstSeen = DateTime.fromMillisecondsSinceEpoch(0);
    _lastTierAdvance = DateTime.fromMillisecondsSinceEpoch(0);
    _spokenObjects.clear();
  }

  Future<void> _handleFrame(Uint8List jpeg) async {
    if (!active || _busy) return;
    if (DateTime.now().isBefore(_skipUntil)) return;
    if (!isLikelyValidJpeg(jpeg)) return;
    _busy = true;
    try {
      final perception = await _analyzeFrame(jpeg);
      if (!active) return;
      _lastError = null;
      _consecutiveFailures = 0;

      final sig = _signatureOf(perception);
      _updateStability(sig);

      // Walk the ladder if we've been stable long enough at the prior tier.
      final now = DateTime.now();
      switch (_tier) {
        case _DiscoveryTier.scanning:
          if (_isStable(now)) {
            await _emitTier1(perception);
          }
          break;
        case _DiscoveryTier.tier1:
          if (_isStable(now) &&
              now.difference(_lastTierAdvance) >= _tier2MinHold) {
            await _emitTier2(perception, jpeg);
          }
          break;
        case _DiscoveryTier.tier2:
          if (_isStable(now) &&
              now.difference(_lastTierAdvance) >= _tier3MinHold) {
            await _emitTier3(perception, jpeg);
          }
          break;
        case _DiscoveryTier.tier3:
        case _DiscoveryTier.exhausted:
          // Nothing left; wait for a scene change.
          break;
      }
    } catch (e) {
      debugPrint('[LiveDetectionController] frame failed: $e');
      _lastError = 'Live frame skipped: ${e.runtimeType}.';
      _consecutiveFailures += 1;
      if (_consecutiveFailures >= _maxConsecutiveFailures) {
        _skipUntil = DateTime.now().add(_failureCooldown);
        _lastError = 'Live vision cooling down after repeated local failures.';
        _cooldownTimer?.cancel();
        _cooldownTimer = Timer(_failureCooldown, () {
          _consecutiveFailures = 0;
          if (active) {
            _lastError = null;
            notifyListeners();
          }
        });
      }
      notifyListeners();
    } finally {
      _busy = false;
    }
  }

  // --- Stability machinery ------------------------------------------------

  /// Scene signature: sorted `label@clock` tokens for objects above 0.20
  /// confidence plus a person marker. Coarse enough to survive small YOLO
  /// noise; specific enough to notice when the user turns or moves.
  Set<String> _signatureOf(VisionAnalysis perception) {
    final tokens = <String>{};
    if (perception is ScenePerceptionResult) {
      for (final o in perception.detectedObjects) {
        if (o.confidence < 0.20) continue;
        tokens.add('${o.label}@${o.clockPosition}');
      }
    }
    if (perception.personCount > 0) {
      tokens.add('person#${perception.personCount.clamp(1, 4)}');
    }
    return tokens;
  }

  void _updateStability(Set<String> sig) {
    if (sig.isEmpty) {
      // Empty scene resets — nothing confident enough to describe yet.
      if (_sceneSig.isNotEmpty || _pendingSig.isNotEmpty) {
        _resetLadderForSceneChange();
      }
      return;
    }

    if (_sceneSig.isEmpty && _pendingSig.isEmpty) {
      _sceneSig = sig;
      _sigFirstSeen = DateTime.now().subtract(_stabilityWindow);
      return;
    }

    final jaccardToCurrent = _jaccard(sig, _sceneSig);
    if (_sceneSig.isNotEmpty && jaccardToCurrent >= _sigJaccardThreshold) {
      // Scene continues — refresh the signature with the latest view.
      _sceneSig = sig;
      return;
    }

    // Different enough from the current stable scene. Check vs pending.
    final jaccardToPending = _jaccard(sig, _pendingSig);
    if (_pendingSig.isNotEmpty && jaccardToPending >= _sigJaccardThreshold) {
      // Pending scene is holding. Promote after _stabilityWindow.
      if (DateTime.now().difference(_sigFirstSeen) >= _stabilityWindow) {
        _resetLadderForSceneChange();
        _sceneSig = sig;
      }
    } else {
      // New candidate. Start the clock.
      _pendingSig = sig;
      _sigFirstSeen = DateTime.now();
      if (_sceneSig.isNotEmpty) {
        // User has clearly moved — drop current scene immediately so the next
        // stable frame starts fresh at tier 1.
        _resetLadderForSceneChange();
      }
    }
  }

  bool _isStable(DateTime now) {
    if (_sceneSig.isEmpty) return false;
    return now.difference(_sigFirstSeen) >= _stabilityWindow;
  }

  void _resetLadderForSceneChange() {
    _tier = _DiscoveryTier.scanning;
    _sceneSig = const <String>{};
    _spokenObjects.clear();
    _lastTierAdvance = DateTime.fromMillisecondsSinceEpoch(0);
  }

  static double _jaccard(Set<String> a, Set<String> b) {
    if (a.isEmpty && b.isEmpty) return 1.0;
    if (a.isEmpty || b.isEmpty) return 0.0;
    final intersection = a.intersection(b).length;
    final union = a.union(b).length;
    return intersection / union;
  }

  // --- Tier emissions -----------------------------------------------------

  Future<void> _emitTier1(VisionAnalysis perception) async {
    final message = _buildTier1Message(perception);
    if (message.isEmpty) return;
    await _speakTier(message, _DiscoveryTier.tier1);
    _rememberSpoken(perception);
  }

  Future<void> _emitTier2(VisionAnalysis perception, Uint8List jpeg) async {
    // Cloud required for tier 2. Fall through to tier 3 skip if unavailable.
    final cloud = _cloud;
    if (cloud == null || !cloud.isConfigured) {
      _tier = _DiscoveryTier.exhausted;
      return;
    }
    // Cap + policy gate. Policy=localOnly or hard cap → skip cloud entirely;
    // min-interval → silently defer (tier stays, next frame re-evaluates).
    if (_cloudPolicyProvider() == LiveCloudPolicy.localOnly ||
        _cloudCallsThisSession >= _maxCloudCallsPerSession) {
      _tier = _DiscoveryTier.exhausted;
      return;
    }
    if (DateTime.now().difference(_lastCloudCallAt) < _minCloudInterval) {
      return;
    }

    final crop = _centerCropJpeg(jpeg, cropFraction: 0.60, maxDim: 512);
    if (crop == null) return;

    final knowns = _spokenObjects.join(', ');
    final userPrompt =
        'Describe what a blind user needs to know about THIS close-up center view. '
        'You are their eyes; be specific and confident. '
        'Already told them: ${knowns.isEmpty ? "(nothing yet)" : knowns}. '
        'Use 2 short spoken sentences. Add concrete details — colors, materials, state — '
        'and clock positions for new objects. Skip anything already told.';

    final text = await _runCloudOnce(
      cloud,
      crop,
      userPrompt: userPrompt,
      maxTokens: 180,
    );
    if (text == null || text.isEmpty) {
      // Keep the ladder moving to tier 3 on next stable frame.
      _lastTierAdvance = DateTime.now();
      _tier = _DiscoveryTier.tier2;
      return;
    }
    await _speakTier(text, _DiscoveryTier.tier2);
    _extractAndRememberNouns(text);
  }

  Future<void> _emitTier3(VisionAnalysis perception, Uint8List jpeg) async {
    final cloud = _cloud;
    if (cloud == null || !cloud.isConfigured) {
      _tier = _DiscoveryTier.exhausted;
      return;
    }
    if (_cloudPolicyProvider() == LiveCloudPolicy.localOnly ||
        _cloudCallsThisSession >= _maxCloudCallsPerSession) {
      _tier = _DiscoveryTier.exhausted;
      return;
    }
    if (DateTime.now().difference(_lastCloudCallAt) < _minCloudInterval) {
      return;
    }

    final knowns = _spokenObjects.join(', ');
    final userPrompt =
        'Full-frame scan for the blind user now. Cover the peripheries and background. '
        'Already described: ${knowns.isEmpty ? "(nothing yet)" : knowns}. '
        'Call out only NEW objects, signs, doors, paths, or hazards with clock positions. '
        '2 short spoken sentences. If nothing new, say exactly: "Nothing else notable."';

    final text = await _runCloudOnce(
      cloud,
      jpeg,
      userPrompt: userPrompt,
      maxTokens: 180,
    );
    if (text == null || text.isEmpty) {
      _tier = _DiscoveryTier.exhausted;
      _lastTierAdvance = DateTime.now();
      return;
    }
    // Don't re-speak the "nothing else" canned string.
    final normalized = text.toLowerCase();
    if (normalized.contains('nothing else notable')) {
      _tier = _DiscoveryTier.exhausted;
      _lastTierAdvance = DateTime.now();
      return;
    }
    await _speakTier(text, _DiscoveryTier.tier3);
    _extractAndRememberNouns(text);
    _tier = _DiscoveryTier.exhausted;
  }

  Future<String?> _runCloudOnce(
    VertexAiService cloud,
    Uint8List jpeg, {
    required String userPrompt,
    required int maxTokens,
  }) async {
    // Stamp attempt time immediately so the min-interval gate covers failures
    // too (otherwise a flapping network could fire cloud calls every second).
    _lastCloudCallAt = DateTime.now();
    _cloudCallsThisSession++;
    notifyListeners();
    try {
      await cloud.setModel(AiModel.flash);
      const systemPrompt =
          'You are the eyes for a blind user wearing a chest camera. '
          'Speak plain English for TTS. No meta language, no "I see", no markdown.';
      final chunks = await cloud
          .streamContentFromImage(
            jpeg,
            systemPrompt: systemPrompt,
            userPrompt: userPrompt,
            maxOutputTokens: maxTokens,
          )
          .toList()
          .timeout(const Duration(seconds: 6));
      final text = chunks.join().trim();
      return text.isEmpty ? null : text;
    } on TimeoutException {
      debugPrint('[LiveDetectionController] cloud tier timed out');
      return null;
    } catch (e) {
      debugPrint('[LiveDetectionController] cloud tier failed: $e');
      return null;
    }
  }

  Future<void> _speakTier(String message, _DiscoveryTier next) async {
    _lastMessage = message;
    _tier = next;
    _lastTierAdvance = DateTime.now();
    notifyListeners();
    await _safeSpeak(message);
  }

  void _rememberSpoken(VisionAnalysis perception) {
    if (perception is ScenePerceptionResult) {
      for (final o in perception.detectedObjects) {
        if (o.confidence >= 0.20) _spokenObjects.add(o.label);
      }
    }
    if (perception.personCount > 0) _spokenObjects.add('person');
  }

  static final RegExp _nounLike = RegExp(r"[a-zA-Z][a-zA-Z-]{2,}");
  void _extractAndRememberNouns(String text) {
    for (final m in _nounLike.allMatches(text.toLowerCase())) {
      final w = m.group(0)!;
      if (w.length <= 3) continue;
      if (_stopwords.contains(w)) continue;
      _spokenObjects.add(w);
    }
  }

  static const Set<String> _stopwords = {
    'the',
    'and',
    'with',
    'your',
    'you',
    'there',
    'that',
    'this',
    'from',
    'clock',
    'near',
    'next',
    'past',
    'over',
    'under',
    'into',
    'onto',
    'about',
    'some',
    'very',
    'also',
    'just',
    'been',
    'were',
    'have',
    'has',
    'had',
    'appears',
    'looks',
    'looking',
    'seems',
    'seem',
    'them',
    'they',
    'their',
    'it is',
    'oclock',
    'right',
    'left',
    'front',
    'back',
    'behind',
    'ahead',
    'close',
    'far',
    'reach',
    'away',
    'steps',
    'step',
  };

  // --- Tier 1 message builder (YOLO + Apple Vision only) ------------------

  String _buildTier1Message(VisionAnalysis result) {
    final verbosity = _verbosityProvider();

    if (result is ScenePerceptionResult && result.detectedObjects.isNotEmpty) {
      final objects =
          result.detectedObjects
              .where((object) => object.confidence >= 0.25)
              .toList()
            ..sort(_compareSpatialObjects);
      if (objects.isNotEmpty) {
        return _spatialMessage(objects, result, verbosity: verbosity);
      }
    }
    if (result.personCount > 0) {
      return _peopleMessage(result, verbosity);
    }
    if (result.ocrTexts.isNotEmpty) {
      return 'Text reads ${result.ocrTexts.take(2).join(', ')}.';
    }
    if (verbosity == LiveDetectionVerbosity.full &&
        result.sceneClassification != 'unknown' &&
        result.sceneConfidence > 0.35) {
      return '${result.sceneClassification.replaceAll('_', ' ')} setting ahead.';
    }
    return '';
  }

  static int _compareSpatialObjects(SpatialObjectData a, SpatialObjectData b) {
    final depthCompare = (a.relativeDepth ?? 1.0).compareTo(
      b.relativeDepth ?? 1.0,
    );
    if (depthCompare != 0) return depthCompare;
    return b.confidence.compareTo(a.confidence);
  }

  String _spatialMessage(
    List<SpatialObjectData> objects,
    ScenePerceptionResult result, {
    required LiveDetectionVerbosity verbosity,
  }) {
    final count = switch (verbosity) {
      LiveDetectionVerbosity.minimal => 1,
      LiveDetectionVerbosity.positional => 2,
      LiveDetectionVerbosity.full => 3,
    };
    final spokenObjects = objects.take(count).map((object) {
      final clock = _clockLabel(object.clockPosition);
      final distance = _distancePhrase(object.relativeDepth);
      return switch (verbosity) {
        LiveDetectionVerbosity.minimal => object.label,
        LiveDetectionVerbosity.positional =>
          '${object.label} at your $clock o\'clock',
        LiveDetectionVerbosity.full =>
          '${object.label} at your $clock o\'clock$distance',
      };
    }).toList();

    final parts = <String>[spokenObjects.join('. ')];
    if (verbosity == LiveDetectionVerbosity.full) {
      if (result.personCount > 0 &&
          !objects.any((object) => object.label.toLowerCase() == 'person')) {
        parts.add(_peopleMessage(result, verbosity));
      }
      if (result.ocrTexts.isNotEmpty) {
        parts.add('Text reads ${result.ocrTexts.take(2).join(', ')}');
      }
    }
    return '${parts.where((part) => part.trim().isNotEmpty).join('. ')}.';
  }

  String _peopleMessage(
    VisionAnalysis result,
    LiveDetectionVerbosity verbosity,
  ) {
    if (verbosity == LiveDetectionVerbosity.minimal ||
        result.personRects.isEmpty) {
      return result.personCount == 1
          ? '1 person detected.'
          : '${result.personCount} people detected.';
    }
    final first = result.personRects.first;
    final centerX = (first['x'] ?? 0.5) + ((first['w'] ?? 0) / 2);
    final clock = _clockFromCenterX(centerX);
    return result.personCount == 1
        ? 'Person at your $clock o\'clock.'
        : '${result.personCount} people detected; nearest at your $clock o\'clock.';
  }

  static int _clockFromCenterX(double centerX) {
    if (centerX < 0.17) return 10;
    if (centerX < 0.34) return 11;
    if (centerX < 0.66) return 12;
    if (centerX < 0.83) return 1;
    return 2;
  }

  static int _clockLabel(int clock) {
    if (clock >= 1 && clock <= 12) return clock;
    return 12;
  }

  static String _distancePhrase(double? relativeDepth) {
    if (relativeDepth == null) return '';
    if (relativeDepth < 0.30) return ', within reach';
    if (relativeDepth < 0.50) return ', a step or two away';
    if (relativeDepth < 0.70) return ', several steps ahead';
    return ', farther out';
  }

  // --- Local analysis with fallback --------------------------------------

  Future<VisionAnalysis> _analyzeFrame(Uint8List jpeg) async {
    if (_preferFullPerception) {
      try {
        return await _vision.analyzeScene(jpeg).timeout(_analysisTimeout);
      } catch (e) {
        debugPrint('[LiveDetectionController] full perception unavailable: $e');
        _preferFullPerception = false;
        _basicFallbackFramesRemaining = _fullPerceptionRetryFrames;
      }
    } else if (_basicFallbackFramesRemaining > 0) {
      _basicFallbackFramesRemaining -= 1;
    } else {
      _preferFullPerception = true;
    }

    return _vision.analyzeLiveFrame(jpeg).timeout(_analysisTimeout);
  }

  // --- Center-crop helper -------------------------------------------------

  /// Decode, crop to the center [cropFraction] of each axis, downscale so the
  /// longer edge is at most [maxDim], and re-encode as JPEG. Returns null if
  /// the image fails to decode.
  Uint8List? _centerCropJpeg(
    Uint8List jpeg, {
    required double cropFraction,
    required int maxDim,
  }) {
    final decoded = img.decodeJpg(jpeg);
    if (decoded == null) return null;

    final cropW = (decoded.width * cropFraction).round().clamp(
      32,
      decoded.width,
    );
    final cropH = (decoded.height * cropFraction).round().clamp(
      32,
      decoded.height,
    );
    final x = ((decoded.width - cropW) / 2).round();
    final y = ((decoded.height - cropH) / 2).round();

    var cropped = img.copyCrop(
      decoded,
      x: x,
      y: y,
      width: cropW,
      height: cropH,
    );

    final longer = math.max(cropped.width, cropped.height);
    if (longer > maxDim) {
      final scale = maxDim / longer;
      cropped = img.copyResize(
        cropped,
        width: (cropped.width * scale).round(),
        height: (cropped.height * scale).round(),
        interpolation: img.Interpolation.average,
      );
    }
    return Uint8List.fromList(img.encodeJpg(cropped, quality: 80));
  }

  void _setError(String message) {
    _lastError = message;
    _setState(LiveDetectionState.error);
  }

  void _setState(LiveDetectionState state) {
    if (_state == state) return;
    _state = state;
    notifyListeners();
  }

  Future<void> _safeSpeak(String text) async {
    try {
      await _tts.speak(text);
    } catch (e) {
      debugPrint('[LiveDetectionController] TTS failed: $e');
    }
  }

  @override
  void dispose() {
    _cooldownTimer?.cancel();
    unawaited(stop(speak: false));
    super.dispose();
  }
}
