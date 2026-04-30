import 'package:flutter_test/flutter_test.dart';
import 'package:ican/models/settings_provider.dart';
import 'package:ican/services/scene_description_service.dart';
import 'package:ican/services/voice_control_service.dart';

void main() {
  group('VoiceControlService', () {
    late _FakeVoiceControlTarget target;
    late VoiceControlService service;

    setUp(() {
      target = _FakeVoiceControlTarget();
      service = VoiceControlService(target: target);
    });

    test('increases speech rate from natural language', () async {
      final result = await service.handleTranscript('talk faster');

      expect(result.success, isTrue);
      expect(target.speechRate, closeTo(0.6, 0.001));
      expect(target.wordsPerMinute, 220);
      expect(result.spokenConfirmation, 'Speed set to 220 words per minute.');
    });

    test('sets exact volume by percent', () async {
      final result = await service.handleTranscript('volume 70');

      expect(result.success, isTrue);
      expect(target.volume, closeTo(0.7, 0.001));
      expect(result.changedState['volumePercent'], 70);
      expect(result.spokenConfirmation, 'Volume set to 70 percent.');
    });

    test('restores safe speech defaults by voice command', () async {
      target.volume = 0.2;

      final result = await service.handleTranscript('reset speech');

      expect(result.success, isTrue);
      expect(target.resetSpeechDefaultsCount, 1);
      expect(result.spokenConfirmation, 'Speech defaults restored.');
    });

    test('switches to offline local vision mode', () async {
      final result = await service.handleTranscript('use local model');

      expect(result.success, isTrue);
      expect(target.visionMode, VisionMode.offlineOnly);
      expect(result.changedState['visionMode'], 'offlineOnly');
      expect(result.spokenConfirmation, 'Local mode selected.');
    });

    test('stop live detection does not match start live detection', () async {
      final result = await service.handleTranscript('stop live detection');

      expect(result.success, isTrue);
      expect(target.stopLiveCount, 1);
      expect(target.startLiveCount, 0);
      expect(result.spokenConfirmation, 'Stopping live detection.');
    });

    test('understands natural scene and safety phrases', () async {
      var result = await service.handleTranscript("what's in front of me");
      expect(result.success, isTrue);
      expect(target.describeCount, 1);

      result = await service.handleTranscript('am I clear to walk');
      expect(result.success, isTrue);
      expect(target.detailLevel, DetailLevel.brief);
    });

    test('asks clarification for ambiguous mode commands', () async {
      final result = await service.handleTranscript('change detail');

      expect(result.success, isFalse);
      expect(result.spokenConfirmation, contains('brief descriptions'));
      expect(target.detailLevel, DetailLevel.detailed);
    });

    test('rule hit skips fallback parsers', () async {
      final fallback = _FakeFallbackParser(
        const VoiceIntent(
          action: VoiceActionType.setVolume,
          slots: {'percent': 10},
          confidence: 0.95,
          source: 'cloud',
          rawTranscript: 'describe now',
        ),
      );
      service = VoiceControlService(
        target: target,
        resolver: VoiceIntentResolver(cloudParser: fallback),
      );

      final result = await service.handleTranscript('describe now');

      expect(result.success, isTrue);
      expect(fallback.calls, 0);
      expect(target.describeCount, 1);
      expect(target.volume, 1.0);
    });

    test('low-confidence fallback does not mutate settings', () async {
      final fallback = _FakeFallbackParser(
        const VoiceIntent(
          action: VoiceActionType.setVisionMode,
          slots: {'visionMode': 'cloudOnly'},
          confidence: 0.5,
          source: 'cloud',
          rawTranscript: 'maybe internet thing',
        ),
      );
      service = VoiceControlService(
        target: target,
        resolver: VoiceIntentResolver(cloudParser: fallback),
      );

      final result = await service.handleTranscript('maybe internet thing');

      expect(result.success, isFalse);
      expect(target.visionMode, VisionMode.auto);
    });

    test(
      'fallback cannot contact caretaker without explicit caretaker intent',
      () async {
        final fallback = _FakeFallbackParser(
          const VoiceIntent(
            action: VoiceActionType.contactCaretaker,
            confidence: 0.95,
            source: 'cloud',
            rawTranscript: 'call someone',
          ),
        );
        service = VoiceControlService(
          target: target,
          resolver: VoiceIntentResolver(cloudParser: fallback),
        );

        final result = await service.handleTranscript('call someone');

        expect(result.success, isFalse);
        expect(result.spokenConfirmation, contains("I didn't understand"));
      },
    );

    test(
      'sets live detection verbosity without changing scene detail',
      () async {
        final result = await service.handleTranscript('live less chatty');

        expect(result.success, isTrue);
        expect(target.detailLevel, DetailLevel.detailed);
        expect(target.liveDetectionVerbosity, LiveDetectionVerbosity.minimal);
        expect(result.changedState['liveVerbosity'], 'minimal');
      },
    );

    test('returns a failed result for unknown commands', () async {
      final result = await service.handleTranscript('make it sparkle');

      expect(result.success, isFalse);
      expect(result.spokenConfirmation, contains("I didn't understand"));
    });

    test('does not claim describe worked when camera is unavailable', () async {
      target.canDescribeNow = false;

      final result = await service.handleTranscript('describe now');

      expect(result.success, isFalse);
      expect(result.spokenConfirmation, contains('Camera is not ready'));
      expect(target.describeCount, 0);
    });

    test('describe the scene reports final pipeline outcome', () async {
      target.describeOutcome = 'Scene description complete.';

      final result = await service.handleTranscript('describe the scene');

      expect(result.success, isTrue);
      expect(target.describeCount, 1);
      expect(result.spokenConfirmation, 'Scene description complete.');
    });

    test('what failed repeats the latest diagnostic', () async {
      target.latestFailureSummary = 'Eye E04: CRC mismatch.';

      final result = await service.handleTranscript('what failed');

      expect(result.success, isTrue);
      expect(result.spokenConfirmation, 'Eye E04: CRC mismatch.');
    });

    test('vision status reports mode and backend status', () async {
      target.visionStatusSummary = 'Vision mode Cloud. Last backend cloud.';

      final result = await service.handleTranscript('vision status');

      expect(result.success, isTrue);
      expect(
        result.spokenConfirmation,
        'Vision mode Cloud. Last backend cloud.',
      );
    });

    test('contact caretaker dispatches to the notification target', () async {
      final result = await service.handleTranscript('contact caretaker');

      expect(result.success, isTrue);
      expect(target.caretakerAlertCount, 1);
      expect(result.spokenConfirmation, 'Caretaker notified.');
    });

    test('contact caretaker fails gracefully when unsupported', () async {
      target.canContactCaretaker = false;

      final result = await service.handleTranscript('contact caretaker');

      expect(result.success, isFalse);
      expect(target.caretakerAlertCount, 0);
      expect(
        result.spokenConfirmation,
        'Caretaker alerts are not available on this device.',
      );
    });

    test('does not claim repeat worked without a prior description', () async {
      target.canRepeatLast = false;

      final result = await service.handleTranscript('repeat last');

      expect(result.success, isFalse);
      expect(result.spokenConfirmation, 'No scene description yet.');
      expect(target.repeatCount, 0);
    });
  });
}

class _FakeVoiceControlTarget implements VoiceControlTarget {
  @override
  double speechRate = 0.5;

  @override
  double volume = 1.0;

  @override
  DetailLevel detailLevel = DetailLevel.detailed;

  @override
  LiveDetectionVerbosity liveDetectionVerbosity =
      LiveDetectionVerbosity.positional;

  @override
  VisionMode visionMode = VisionMode.auto;

  @override
  String deviceStatusSummary = 'Camera disconnected. Cane disconnected.';

  @override
  String latestSceneSummary = 'A hallway with a door ahead.';

  @override
  String latestFailureSummary = 'No failure recorded.';

  @override
  String visionStatusSummary = 'Vision mode Auto. Last backend none yet.';

  @override
  bool canDescribeNow = true;

  @override
  bool canRepeatLast = true;

  @override
  bool canControlDescriptions = true;

  @override
  bool canStartLiveDetection = true;

  @override
  bool canStopLiveDetection = true;

  @override
  bool canScanDevices = true;

  @override
  bool canContactCaretaker = true;

  var describeCount = 0;
  var repeatCount = 0;
  var startLiveCount = 0;
  var stopLiveCount = 0;
  var resetSpeechDefaultsCount = 0;
  var caretakerAlertCount = 0;
  var caretakerAlertResult = true;
  var describeOutcome = 'Scene description complete.';

  @override
  int get wordsPerMinute => (100 + (speechRate * 200)).round();

  @override
  Future<void> setSpeechRate(double rate) async {
    speechRate = rate;
  }

  @override
  Future<void> setVolume(double volume) async {
    this.volume = volume;
  }

  @override
  Future<void> resetSpeechDefaults() async {
    resetSpeechDefaultsCount++;
    speechRate = 0.5;
    volume = 1.0;
  }

  @override
  Future<void> setDetailLevel(DetailLevel level) async {
    detailLevel = level;
  }

  @override
  Future<void> setLiveDetectionVerbosity(
    LiveDetectionVerbosity verbosity,
  ) async {
    liveDetectionVerbosity = verbosity;
  }

  @override
  Future<void> setVisionMode(VisionMode mode) async {
    visionMode = mode;
  }

  @override
  Future<String> describeNow() async {
    describeCount++;
    return describeOutcome;
  }

  @override
  Future<void> repeatLast() async {
    repeatCount++;
  }

  @override
  Future<void> pauseDescriptions() async {}

  @override
  Future<void> resumeDescriptions() async {}

  @override
  Future<void> startLiveDetection() async {
    startLiveCount++;
  }

  @override
  Future<void> stopLiveDetection() async {
    stopLiveCount++;
  }

  @override
  Future<void> scanDevices() async {}

  @override
  Future<bool> sendCaretakerAlert() async {
    caretakerAlertCount++;
    return caretakerAlertResult;
  }
}

class _FakeFallbackParser implements VoiceIntentFallbackParser {
  _FakeFallbackParser(this.intent);

  final VoiceIntent intent;
  var calls = 0;

  @override
  Future<VoiceIntent?> resolve(String transcript) async {
    calls++;
    return VoiceIntent(
      action: intent.action,
      slots: intent.slots,
      confidence: intent.confidence,
      source: intent.source,
      rawTranscript: transcript,
    );
  }
}
