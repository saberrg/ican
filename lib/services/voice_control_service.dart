import 'dart:convert';

import '../models/home_view_model.dart';
import '../models/settings_provider.dart';
import 'ble_service.dart';
import 'notification_service.dart';
import 'scene_description_service.dart';
import 'vertex_ai_service.dart';

enum VoiceActionType {
  describeNow,
  repeatLast,
  pauseDescriptions,
  resumeDescriptions,
  startLiveDetection,
  stopLiveDetection,
  setSpeechRate,
  setVolume,
  resetSpeechDefaults,
  setDetailLevel,
  setVisionMode,
  setLiveVerbosity,
  contactCaretaker,
  scanDevices,
  announceStatus,
  announceVisionStatus,
  repeatLastDiagnostic,
  announceTime,
  help,
  unknown,
}

class VoiceIntent {
  final VoiceActionType action;
  final Map<String, Object?> slots;
  final double confidence;
  final String source;
  final String rawTranscript;

  const VoiceIntent({
    required this.action,
    this.slots = const {},
    required this.confidence,
    required this.source,
    required this.rawTranscript,
  });
}

class VoiceActionResult {
  final bool success;
  final String spokenConfirmation;
  final Map<String, Object?> changedState;

  const VoiceActionResult({
    required this.success,
    required this.spokenConfirmation,
    this.changedState = const {},
  });
}

class VoiceIntentParser {
  const VoiceIntentParser();

  VoiceIntent parse(String transcript) {
    final normalized = _normalize(transcript);
    if (normalized.isEmpty) {
      return _intent(transcript, VoiceActionType.unknown, confidence: 0);
    }

    if (_containsAny(normalized, [
      'describe',
      'what around',
      'scan scene',
      'what is in front',
      'whats in front',
      'what s in front',
      'what is ahead',
      'what am i facing',
      'look around',
    ])) {
      return _intent(transcript, VoiceActionType.describeNow);
    }
    if (_containsAny(normalized, [
      'what failed',
      'last failure',
      'last diagnostic',
    ])) {
      return _intent(transcript, VoiceActionType.repeatLastDiagnostic);
    }
    if (_containsAny(normalized, ['vision status', 'vision mode status'])) {
      return _intent(transcript, VoiceActionType.announceVisionStatus);
    }
    if (_containsAny(normalized, [
      'repeat',
      'say again',
      'last image',
      'what did you say',
    ])) {
      return _intent(transcript, VoiceActionType.repeatLast);
    }
    if (_containsAny(normalized, ['pause', 'stop talking', 'be quiet'])) {
      return _intent(transcript, VoiceActionType.pauseDescriptions);
    }
    if (_containsAny(normalized, ['resume', 'continue', 'keep going'])) {
      return _intent(transcript, VoiceActionType.resumeDescriptions);
    }
    if (_containsAny(normalized, ['stop live', 'end live', 'exit live'])) {
      return _intent(transcript, VoiceActionType.stopLiveDetection);
    }
    if (_containsAny(normalized, [
      'start live',
      'go live',
      'turn on live',
      'live detection',
    ])) {
      return _intent(transcript, VoiceActionType.startLiveDetection);
    }
    if (_containsAny(normalized, ['status', 'battery', 'device status'])) {
      return _intent(transcript, VoiceActionType.announceStatus);
    }
    if (_containsAny(normalized, ['what time', 'time is it', 'current time'])) {
      return _intent(transcript, VoiceActionType.announceTime);
    }
    if (_containsAny(normalized, [
      'connect',
      'reconnect',
      'find device',
      'scan devices',
      'find camera',
    ])) {
      return _intent(transcript, VoiceActionType.scanDevices);
    }
    if (_containsAny(normalized, ['help', 'what can i say', 'commands'])) {
      return _intent(transcript, VoiceActionType.help);
    }
    if (_containsAny(normalized, [
      'contact caretaker',
      'call caretaker',
      'message caretaker',
      'alert caretaker',
    ])) {
      return _intent(transcript, VoiceActionType.contactCaretaker);
    }

    final exactWpm = RegExp(
      r'(\d{2,3})\s*(?:words per minute|wpm)',
    ).firstMatch(normalized);
    if (exactWpm != null) {
      return _intent(
        transcript,
        VoiceActionType.setSpeechRate,
        slots: {'wpm': int.parse(exactWpm.group(1)!)},
      );
    }
    if (_containsAny(normalized, ['faster', 'speed up', 'talk faster'])) {
      return _intent(
        transcript,
        VoiceActionType.setSpeechRate,
        slots: {'delta': 0.1},
      );
    }
    if (_containsAny(normalized, ['slower', 'slow down', 'talk slower'])) {
      return _intent(
        transcript,
        VoiceActionType.setSpeechRate,
        slots: {'delta': -0.1},
      );
    }

    final exactVolume = RegExp(
      r'(?:volume|loudness)\s*(?:to)?\s*(\d{1,3})',
    ).firstMatch(normalized);
    if (exactVolume != null) {
      return _intent(
        transcript,
        VoiceActionType.setVolume,
        slots: {'percent': int.parse(exactVolume.group(1)!)},
      );
    }
    if (_containsAny(normalized, ['louder', 'volume up'])) {
      return _intent(
        transcript,
        VoiceActionType.setVolume,
        slots: {'delta': 0.1},
      );
    }
    if (_containsAny(normalized, ['quieter', 'volume down', 'softer'])) {
      return _intent(
        transcript,
        VoiceActionType.setVolume,
        slots: {'delta': -0.1},
      );
    }
    if (_containsAny(normalized, [
      'reset speech',
      'restore speech',
      'safe speech defaults',
      'fix voice',
      'reset voice',
    ])) {
      return _intent(transcript, VoiceActionType.resetSpeechDefaults);
    }

    if (_containsAny(normalized, ['live less chatty', 'less live detail'])) {
      return _intent(
        transcript,
        VoiceActionType.setLiveVerbosity,
        slots: {'liveVerbosity': LiveDetectionVerbosity.minimal.name},
      );
    }
    if (_containsAny(normalized, ['live full detail', 'more live detail'])) {
      return _intent(
        transcript,
        VoiceActionType.setLiveVerbosity,
        slots: {'liveVerbosity': LiveDetectionVerbosity.full.name},
      );
    }

    if (_containsAny(normalized, [
      'less chatty',
      'be brief',
      'shorter',
      'less detail',
      'brief mode',
      'keep it short',
    ])) {
      return _intent(
        transcript,
        VoiceActionType.setDetailLevel,
        slots: {'detailLevel': DetailLevel.brief.name},
      );
    }
    if (_containsAny(normalized, [
      'more detail',
      'detailed',
      'rich detail',
      'rich mode',
      'explain more',
    ])) {
      return _intent(
        transcript,
        VoiceActionType.setDetailLevel,
        slots: {'detailLevel': DetailLevel.detailed.name},
      );
    }
    if (_containsAny(normalized, [
      'only hazards',
      'only tell me hazards',
      'only warn me about hazards',
      'safety mode',
      'focus on hazards',
      'am i clear to walk',
      'clear to walk',
    ])) {
      return _intent(
        transcript,
        VoiceActionType.setDetailLevel,
        slots: {'detailLevel': DetailLevel.brief.name},
      );
    }

    if (_containsAny(normalized, [
      'use local',
      'use local vision',
      'go local',
      'local mode',
      'switch to local',
      'offline mode',
      'local model',
      'local vision',
    ])) {
      return _intent(
        transcript,
        VoiceActionType.setVisionMode,
        slots: {'visionMode': VisionMode.offlineOnly.name},
      );
    }
    if (_containsAny(normalized, [
      'use cloud',
      'go cloud',
      'cloud mode',
      'switch to cloud',
      'gemini',
    ])) {
      return _intent(
        transcript,
        VoiceActionType.setVisionMode,
        slots: {'visionMode': VisionMode.cloudOnly.name},
      );
    }
    if (_containsAny(normalized, [
      'auto mode',
      'automatic mode',
      'best available',
    ])) {
      return _intent(
        transcript,
        VoiceActionType.setVisionMode,
        slots: {'visionMode': VisionMode.auto.name},
      );
    }

    if (_containsAny(normalized, ['change detail', 'detail level'])) {
      return _clarification(
        transcript,
        'Do you want brief descriptions or rich descriptions?',
      );
    }
    if (_containsAny(normalized, ['change vision', 'vision source'])) {
      return _clarification(
        transcript,
        'Do you want local basic vision, cloud vision, or auto vision?',
      );
    }

    return _intent(transcript, VoiceActionType.unknown, confidence: 0.2);
  }

  static VoiceIntent _intent(
    String rawTranscript,
    VoiceActionType action, {
    Map<String, Object?> slots = const {},
    double confidence = 1.0,
  }) {
    return VoiceIntent(
      action: action,
      slots: slots,
      confidence: confidence,
      source: 'rule',
      rawTranscript: rawTranscript,
    );
  }

  static VoiceIntent _clarification(String rawTranscript, String message) {
    return _intent(
      rawTranscript,
      VoiceActionType.unknown,
      slots: {'clarification': message},
      confidence: 0.45,
    );
  }

  static bool _containsAny(String text, List<String> phrases) =>
      phrases.any(text.contains);

  static String _normalize(String text) =>
      text.toLowerCase().replaceAll(RegExp(r'[^a-z0-9\s]'), ' ').trim();
}

abstract interface class VoiceIntentFallbackParser {
  Future<VoiceIntent?> resolve(String transcript);
}

class VoiceIntentResolver {
  const VoiceIntentResolver({
    this.ruleParser = const VoiceIntentParser(),
    this.localParser,
    this.cloudParser,
    this.minimumFallbackConfidence = 0.72,
  });

  final VoiceIntentParser ruleParser;
  final VoiceIntentFallbackParser? localParser;
  final VoiceIntentFallbackParser? cloudParser;
  final double minimumFallbackConfidence;

  Future<VoiceIntent> resolve(String transcript) async {
    final ruleIntent = ruleParser.parse(transcript);
    if (ruleIntent.action != VoiceActionType.unknown) return ruleIntent;

    for (final parser in [localParser, cloudParser]) {
      if (parser == null) continue;
      final fallbackIntent = await parser.resolve(transcript);
      if (_isSafeFallback(transcript, fallbackIntent)) {
        return fallbackIntent!;
      }
    }

    final clarification = ruleIntent.slots['clarification'];
    return VoiceIntent(
      action: VoiceActionType.unknown,
      confidence: ruleIntent.confidence,
      source: ruleIntent.source,
      rawTranscript: transcript,
      slots: {
        'clarification': clarification is String
            ? clarification
            : "I didn't understand. Say help for available commands.",
      },
    );
  }

  bool _isSafeFallback(String transcript, VoiceIntent? intent) {
    if (intent == null || intent.action == VoiceActionType.unknown) {
      return false;
    }
    if (intent.confidence < minimumFallbackConfidence) return false;
    if (intent.action == VoiceActionType.contactCaretaker &&
        !_explicitCaretakerContact(transcript)) {
      return false;
    }
    return _slotsAreAllowlisted(intent);
  }

  static bool _explicitCaretakerContact(String transcript) {
    final normalized = VoiceIntentParser._normalize(transcript);
    return normalized.contains('caretaker') &&
        VoiceIntentParser._containsAny(normalized, [
          'call',
          'contact',
          'message',
          'alert',
        ]);
  }

  static bool _slotsAreAllowlisted(VoiceIntent intent) {
    for (final entry in intent.slots.entries) {
      switch (entry.key) {
        case 'delta':
          if (entry.value is! double) return false;
        case 'wpm':
        case 'percent':
          if (entry.value is! int) return false;
        case 'detailLevel':
          if (!DetailLevel.values.any((v) => v.name == entry.value)) {
            return false;
          }
        case 'visionMode':
          if (!VisionMode.values.any((v) => v.name == entry.value)) {
            return false;
          }
        case 'liveVerbosity':
          if (!LiveDetectionVerbosity.values.any(
            (v) => v.name == entry.value,
          )) {
            return false;
          }
        case 'selfTune':
          if (entry.value is! bool) return false;
        default:
          return false;
      }
    }
    return true;
  }
}

class GeminiVoiceIntentFallbackParser implements VoiceIntentFallbackParser {
  GeminiVoiceIntentFallbackParser({required this.service});

  final VertexAiService service;

  @override
  Future<VoiceIntent?> resolve(String transcript) async {
    try {
      final jsonText = await service.generateContent(_prompt(transcript));
      final decoded = jsonDecode(jsonText);
      if (decoded is! Map<String, dynamic>) return null;
      return _intentFromJson(transcript, decoded);
    } catch (e) {
      return null;
    }
  }

  String _prompt(String transcript) {
    return '''
Return strict JSON only. Convert this iCan voice command into one allowlisted action.
Allowed actions: ${VoiceActionType.values.map((v) => v.name).join(', ')}.
Allowed slots: delta(double), wpm(int), percent(int), detailLevel(${DetailLevel.values.map((v) => v.name).join('|')}), visionMode(${VisionMode.values.map((v) => v.name).join('|')}), liveVerbosity(${LiveDetectionVerbosity.values.map((v) => v.name).join('|')}), selfTune(bool).
If uncertain, use action "unknown" with confidence below 0.72.
Transcript: "$transcript"
JSON shape: {"action":"describeNow","confidence":0.0,"slots":{}}
''';
  }

  VoiceIntent? _intentFromJson(
    String transcript,
    Map<String, dynamic> decoded,
  ) {
    final actionName = decoded['action'];
    final confidence = decoded['confidence'];
    if (actionName is! String || confidence is! num) return null;
    final action = VoiceActionType.values.firstWhere(
      (value) => value.name == actionName,
      orElse: () => VoiceActionType.unknown,
    );
    final rawSlots = decoded['slots'];
    final slots = <String, Object?>{};
    if (rawSlots is Map<String, dynamic>) {
      for (final entry in rawSlots.entries) {
        final value = entry.value;
        if (value is String ||
            value is int ||
            value is double ||
            value is bool) {
          slots[entry.key] = value;
        }
      }
    }
    return VoiceIntent(
      action: action,
      slots: slots,
      confidence: confidence.toDouble().clamp(0.0, 1.0),
      source: 'gemini',
      rawTranscript: transcript,
    );
  }
}

abstract class VoiceControlTarget {
  double get speechRate;
  double get volume;
  int get wordsPerMinute;
  DetailLevel get detailLevel;
  LiveDetectionVerbosity get liveDetectionVerbosity;
  VisionMode get visionMode;
  String get deviceStatusSummary;
  String get visionStatusSummary;
  String get latestFailureSummary;
  String get latestSceneSummary;
  bool get canDescribeNow;
  bool get canRepeatLast;
  bool get canControlDescriptions;
  bool get canStartLiveDetection;
  bool get canStopLiveDetection;
  bool get canScanDevices;
  bool get canContactCaretaker;

  Future<void> setSpeechRate(double rate);
  Future<void> setVolume(double volume);
  Future<void> resetSpeechDefaults();
  Future<void> setDetailLevel(DetailLevel level);
  Future<void> setLiveDetectionVerbosity(LiveDetectionVerbosity verbosity);
  Future<void> setVisionMode(VisionMode mode);
  Future<String> describeNow();
  Future<void> repeatLast();
  Future<void> pauseDescriptions();
  Future<void> resumeDescriptions();
  Future<void> startLiveDetection();
  Future<void> stopLiveDetection();
  Future<void> scanDevices();
  Future<bool> sendCaretakerAlert();
}

class AppVoiceControlTarget implements VoiceControlTarget {
  SettingsProvider? settings;
  SceneDescriptionService? sceneService;
  HomeViewModel? homeViewModel;
  final BleService ble;

  AppVoiceControlTarget({required this.ble});

  @override
  double get speechRate => settings?.speechRate ?? 0.5;

  @override
  double get volume => settings?.volume ?? 1.0;

  @override
  int get wordsPerMinute => settings?.wordsPerMinute ?? 200;

  @override
  DetailLevel get detailLevel => settings?.detailLevel ?? DetailLevel.detailed;

  @override
  LiveDetectionVerbosity get liveDetectionVerbosity =>
      settings?.liveDetectionVerbosity ?? LiveDetectionVerbosity.positional;

  @override
  VisionMode get visionMode => sceneService?.mode ?? VisionMode.auto;

  @override
  String get latestSceneSummary {
    final description = homeViewModel?.lastDescription ?? '';
    return description.isEmpty ? 'No scene description yet.' : description;
  }

  @override
  String get latestFailureSummary =>
      homeViewModel?.latestFailureSummary ?? 'No failure recorded.';

  @override
  String get visionStatusSummary =>
      homeViewModel?.visionStatusSummary ??
      'Vision mode ${visionMode.label}. No scene pipeline has run yet.';

  @override
  String get deviceStatusSummary {
    final eye = ble.state == BleConnectionState.connected
        ? 'Camera connected.'
        : 'Camera disconnected.';
    final cane = ble.caneState == BleConnectionState.connected
        ? 'Cane connected.'
        : 'Cane disconnected.';
    final telemetry = ble.lastTelemetry;
    final battery = telemetry == null
        ? ''
        : ' Battery ${telemetry.batteryPercent} percent.';
    return '$eye $cane$battery';
  }

  @override
  bool get canDescribeNow => homeViewModel?.canDescribe ?? false;

  @override
  bool get canRepeatLast =>
      (homeViewModel?.lastDescription ?? '').trim().isNotEmpty;

  @override
  bool get canControlDescriptions => homeViewModel != null;

  @override
  bool get canStartLiveDetection =>
      (homeViewModel?.isEyeConnected ?? false) &&
      (BleService.instance.eyeReadinessStatus.ready) &&
      !(homeViewModel?.liveVisionActive ?? false);

  @override
  bool get canStopLiveDetection => homeViewModel?.liveVisionActive ?? false;

  @override
  bool get canScanDevices => homeViewModel != null;

  @override
  bool get canContactCaretaker => NotificationService.caretakerAlertsSupported;

  @override
  Future<void> setSpeechRate(double rate) async {
    settings?.setSpeechRate(rate);
  }

  @override
  Future<void> setVolume(double volume) async {
    settings?.setVolume(volume);
  }

  @override
  Future<void> resetSpeechDefaults() async {
    await settings?.restoreSafeSpeechDefaults();
  }

  @override
  Future<void> setDetailLevel(DetailLevel level) async {
    settings?.setDetailLevel(level);
  }

  @override
  Future<void> setLiveDetectionVerbosity(
    LiveDetectionVerbosity verbosity,
  ) async {
    settings?.setLiveDetectionVerbosity(verbosity);
  }

  @override
  Future<void> setVisionMode(VisionMode mode) async {
    final vm = homeViewModel;
    if (vm != null) {
      if (mode == VisionMode.cloudOnly || mode == VisionMode.auto) {
        await vm.setVisionControlMode(VisionControlMode.cloud);
        return;
      }
      if (mode == VisionMode.offlineOnly) {
        await vm.setVisionControlMode(VisionControlMode.local);
        return;
      }
    }
    await sceneService?.setMode(mode);
  }

  @override
  Future<String> describeNow() async {
    final vm = homeViewModel;
    if (vm == null) return 'Home is not ready yet.';
    return vm.describeNow();
  }

  @override
  Future<void> repeatLast() async => homeViewModel?.repeatLast();

  @override
  Future<void> pauseDescriptions() async => homeViewModel?.pauseDescriptions();

  @override
  Future<void> resumeDescriptions() async =>
      homeViewModel?.resumeDescriptions();

  @override
  Future<void> startLiveDetection() async => homeViewModel?.startLiveVision();

  @override
  Future<void> stopLiveDetection() async => homeViewModel?.stopLiveVision();

  @override
  Future<void> scanDevices() async {
    homeViewModel?.startScanForEye();
    homeViewModel?.startScanForCane();
  }

  @override
  Future<bool> sendCaretakerAlert() => NotificationService.showCaretakerAlert(
    reason: 'Voice command requested caretaker.',
  );
}

class VoiceControlService {
  final VoiceIntentParser parser;
  final VoiceIntentResolver resolver;
  final VoiceControlTarget target;

  VoiceControlService({
    this.parser = const VoiceIntentParser(),
    VoiceIntentResolver? resolver,
    required this.target,
  }) : resolver = resolver ?? VoiceIntentResolver(ruleParser: parser);

  Future<VoiceActionResult> handleTranscript(String transcript) async {
    return execute(await resolver.resolve(transcript));
  }

  Future<VoiceActionResult> execute(VoiceIntent intent) async {
    if (intent.confidence < 0.65 && intent.action != VoiceActionType.unknown) {
      return _fail(
        'I heard "${intent.rawTranscript}", but I am not confident enough to change settings.',
      );
    }
    switch (intent.action) {
      case VoiceActionType.describeNow:
        if (!target.canDescribeNow) {
          return _fail('Camera is not ready. Connect the iCan Eye first.');
        }
        final outcome = await target.describeNow();
        return _ok(outcome);
      case VoiceActionType.repeatLast:
        if (!target.canRepeatLast) {
          return _fail('No scene description yet.');
        }
        await target.repeatLast();
        return _ok('Repeating the last description.');
      case VoiceActionType.pauseDescriptions:
        if (!target.canControlDescriptions) {
          return _fail('Home is not ready yet.');
        }
        await target.pauseDescriptions();
        return _ok('Paused.');
      case VoiceActionType.resumeDescriptions:
        if (!target.canControlDescriptions) {
          return _fail('Home is not ready yet.');
        }
        await target.resumeDescriptions();
        return _ok('Resumed.');
      case VoiceActionType.startLiveDetection:
        if (!target.canStartLiveDetection) {
          return _fail('Live detection needs the iCan Eye connected.');
        }
        await target.startLiveDetection();
        return _ok('Starting live detection.');
      case VoiceActionType.stopLiveDetection:
        if (!target.canStopLiveDetection) {
          return _fail('Live detection is not running.');
        }
        await target.stopLiveDetection();
        return _ok('Stopping live detection.');
      case VoiceActionType.scanDevices:
        if (!target.canScanDevices) {
          return _fail('Home is not ready yet.');
        }
        await target.scanDevices();
        return _ok('Scanning for devices.');
      case VoiceActionType.announceStatus:
        return _ok(target.deviceStatusSummary);
      case VoiceActionType.announceVisionStatus:
        return _ok(target.visionStatusSummary);
      case VoiceActionType.repeatLastDiagnostic:
        return _ok(target.latestFailureSummary);
      case VoiceActionType.announceTime:
        return _ok(_timeConfirmation(DateTime.now()));
      case VoiceActionType.help:
        return _ok(_helpText);
      case VoiceActionType.contactCaretaker:
        if (!target.canContactCaretaker) {
          return _fail('Caretaker alerts are not available on this device.');
        }
        final sent = await target.sendCaretakerAlert();
        return sent
            ? _ok('Caretaker notified.')
            : _fail('Could not notify the caretaker.');
      case VoiceActionType.setSpeechRate:
        return _setSpeechRate(intent);
      case VoiceActionType.setVolume:
        return _setVolume(intent);
      case VoiceActionType.resetSpeechDefaults:
        await target.resetSpeechDefaults();
        return _ok('Speech defaults restored.', {
          'speechEngine': 'auto',
          'volume': 1.0,
        });
      case VoiceActionType.setDetailLevel:
        return _setDetailLevel(intent);
      case VoiceActionType.setVisionMode:
        return _setVisionMode(intent);
      case VoiceActionType.setLiveVerbosity:
        return _setLiveVerbosity(intent);
      case VoiceActionType.unknown:
        final clarification = intent.slots['clarification'];
        return VoiceActionResult(
          success: false,
          spokenConfirmation: clarification is String
              ? clarification
              : "I didn't understand. Say help for available commands.",
        );
    }
  }

  Future<VoiceActionResult> _setSpeechRate(VoiceIntent intent) async {
    final wpm = intent.slots['wpm'];
    final delta = intent.slots['delta'];
    final rate = wpm is int
        ? SettingsProvider.wpmToRate(wpm)
        : (target.speechRate + ((delta as double?) ?? 0)).clamp(0.0, 1.0);
    await target.setSpeechRate(rate);
    final changedWpm = (100 + (rate * 200)).round();
    return _ok('Speed set to $changedWpm words per minute.', {
      'speechRate': rate,
      'wordsPerMinute': changedWpm,
    });
  }

  Future<VoiceActionResult> _setVolume(VoiceIntent intent) async {
    final percent = intent.slots['percent'];
    final delta = intent.slots['delta'];
    final volume = percent is int
        ? (percent.clamp(0, 100) / 100.0)
        : (target.volume + ((delta as double?) ?? 0)).clamp(0.0, 1.0);
    await target.setVolume(volume);
    final changedPercent = (volume * 100).round();
    return _ok('Volume set to $changedPercent percent.', {
      'volume': volume,
      'volumePercent': changedPercent,
    });
  }

  Future<VoiceActionResult> _setDetailLevel(VoiceIntent intent) async {
    final level = DetailLevel.values.firstWhere(
      (value) => value.name == intent.slots['detailLevel'],
      orElse: () => target.detailLevel,
    );
    await target.setDetailLevel(level);
    if (level == DetailLevel.brief) {
      await target.setLiveDetectionVerbosity(LiveDetectionVerbosity.minimal);
    }
    return _ok(
      level == DetailLevel.brief
          ? 'Brief mode on. I will keep descriptions shorter.'
          : 'Rich mode on. I will describe more context.',
      {'detailLevel': level.name},
    );
  }

  Future<VoiceActionResult> _setVisionMode(VoiceIntent intent) async {
    final mode = VisionMode.values.firstWhere(
      (value) => value.name == intent.slots['visionMode'],
      orElse: () => target.visionMode,
    );
    await target.setVisionMode(mode);
    return _ok(_visionModeConfirmation(mode), {'visionMode': mode.name});
  }

  Future<VoiceActionResult> _setLiveVerbosity(VoiceIntent intent) async {
    final verbosity = LiveDetectionVerbosity.values.firstWhere(
      (value) => value.name == intent.slots['liveVerbosity'],
      orElse: () => target.liveDetectionVerbosity,
    );
    await target.setLiveDetectionVerbosity(verbosity);
    return _ok('Live detection set to ${verbosity.label.toLowerCase()}.', {
      'liveVerbosity': verbosity.name,
    });
  }

  static VoiceActionResult _ok(
    String confirmation, [
    Map<String, Object?> changedState = const {},
  ]) {
    return VoiceActionResult(
      success: true,
      spokenConfirmation: confirmation,
      changedState: changedState,
    );
  }

  static VoiceActionResult _fail(String confirmation) {
    return VoiceActionResult(success: false, spokenConfirmation: confirmation);
  }

  static String _visionModeConfirmation(VisionMode mode) {
    switch (mode) {
      case VisionMode.auto:
        return 'Cloud mode selected.';
      case VisionMode.offlineOnly:
        return 'Local mode selected.';
      case VisionMode.cloudOnly:
        return 'Cloud mode selected.';
    }
  }

  static String _timeConfirmation(DateTime now) {
    final hour = now.hour > 12
        ? now.hour - 12
        : (now.hour == 0 ? 12 : now.hour);
    final period = now.hour >= 12 ? 'PM' : 'AM';
    final minute = now.minute.toString().padLeft(2, '0');
    return "It's $hour:$minute $period.";
  }

  static const _helpText =
      'You can say: describe, repeat, pause, resume, start live detection, '
      'stop live detection, status, talk faster, talk slower, louder, quieter, '
      'reset speech, local mode, cloud mode, vision status, what failed, '
      'or contact caretaker.';
}
