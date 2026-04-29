import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:ican/models/home_view_model.dart';
import 'package:ican/models/settings_provider.dart';
import 'package:ican/protocol/describe_attempt_trace.dart';
import 'package:ican/protocol/eye_capture_diagnostics.dart';
import 'package:ican/services/ble_service.dart';
import 'package:ican/services/on_device_vision_service.dart';
import 'package:ican/services/scene_description_service.dart';
import 'package:ican/services/tts_service.dart';
import 'package:ican/services/vertex_ai_service.dart';
import 'package:image/image.dart' as img;
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('HomeViewModel vision diagnostics', () {
    late _FakeSceneDescriptionService sceneService;
    late _FakeSpeechOutput speech;
    late HomeViewModel viewModel;

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      BleService.instance.setEyeConnectionStateForTesting(
        BleConnectionState.disconnected,
      );
      sceneService = _FakeSceneDescriptionService();
      speech = _FakeSpeechOutput();
      viewModel = HomeViewModel(
        sceneService: sceneService,
        ttsService: speech,
        settingsProvider: SettingsProvider(ttsService: speech),
        processingTimeout: const Duration(milliseconds: 5),
      );
      await Future<void>.delayed(Duration.zero);
      speech.spoken.clear();
    });

    tearDown(() {
      viewModel.dispose();
      BleService.instance.setEyeConnectionStateForTesting(
        BleConnectionState.disconnected,
      );
    });

    test('speaks camera transfer failure when capture times out', () async {
      viewModel.startCaptureTimeoutForTesting();

      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect(speech.spoken.last, startsWith('Eye E01:'));
      expect(viewModel.isProcessing, isFalse);
    });

    test('speaks Eye E01 when Eye disconnects before capture starts', () async {
      viewModel.startCaptureTimeoutForTesting();

      BleService.instance.setEyeConnectionStateForTesting(
        BleConnectionState.disconnected,
      );
      await Future<void>.delayed(Duration.zero);

      expect(speech.spoken.last, startsWith('Eye E01:'));
      expect(speech.spoken.last, isNot(startsWith('Eye E02:')));
      expect(viewModel.isProcessing, isFalse);
    });

    test('rejects Describe while Eye command path is not ready', () async {
      BleService.instance.setEyeConnectionStateForTesting(
        BleConnectionState.connected,
      );
      BleService.instance.updateEyeReadinessForTesting(
        BleReadinessPhase.verifyingCommandPath,
        requiredCharacteristicsReady: true,
        commandPathReady: false,
      );

      final result = await viewModel.describeNow();

      expect(result, startsWith('Eye E01:'));
      expect(sceneService.describeCalls, 0);
      expect(viewModel.isProcessing, isFalse);
    });

    test('speaks incomplete image failure without calling vision', () async {
      await viewModel.processImageForTesting(
        Uint8List.fromList([0xff, 0xd8, 0x00]),
      );

      expect(
        speech.spoken.last,
        startsWith('Eye E03: corrupt or incomplete JPEG.'),
      );
      expect(sceneService.describeCalls, 0);
      expect(viewModel.isProcessing, isFalse);
    });

    test('speaks API-key cloud configuration failure', () async {
      sceneService.error = CloudVisionException.missingApiKey();

      await viewModel.processImageForTesting(_validJpeg());

      expect(speech.spoken.last, 'Cloud C01: missing API key/config.');
    });

    test('speaks cloud HTTP failure status', () async {
      sceneService.error = CloudVisionException.httpStatus(403);

      await viewModel.processImageForTesting(_validJpeg());

      expect(speech.spoken.last, 'Cloud C02: Gemini HTTP status failure 403.');
    });

    test('speaks cloud timeout failure', () async {
      sceneService.error = CloudVisionException.timeout();

      await viewModel.processImageForTesting(_validJpeg());

      expect(speech.spoken.last, 'Cloud C03: cloud timeout/network failure.');
    });

    test('speaks local vision failure', () async {
      sceneService.error = SceneDescriptionException.localVision(
        Exception('Core ML failed'),
      );

      await viewModel.processImageForTesting(_validJpeg());

      expect(speech.spoken.last, 'Local L03: Apple Vision or Core ML failed.');
    });

    test('speaks BLE CRC mismatch diagnostic exactly', () async {
      viewModel.startCaptureTimeoutForTesting();

      await viewModel.handleEyeCaptureDiagnosticForTesting(
        const EyeCaptureDiagnostic(
          code: EyeCaptureDiagnosticCode.crcMismatch,
          captureStarted: true,
          sizeArrived: true,
          expectedBytes: 4,
          receivedBytes: 4,
          uniqueChunks: 1,
          duplicateChunks: 0,
          endArrived: true,
          jpegMagicValid: true,
          jpegEndValid: true,
          expectedCrc: '11111111',
          actualCrc: '22222222',
        ),
      );

      expect(
        speech.spoken.last,
        'Eye E04: CRC mismatch. Expected 11111111, got 22222222. Received 4/4 bytes.',
      );
      expect(viewModel.lastDiagnostic, speech.spoken.last);
    });

    test('vision mode changes notify the view model', () async {
      var notifications = 0;
      viewModel.addListener(() {
        notifications++;
      });

      await sceneService.setMode(VisionMode.cloudOnly);

      expect(viewModel.visionMode, VisionMode.cloudOnly);
      expect(notifications, greaterThan(0));
    });

    test(
      'persists completed describe trace after successful processing',
      () async {
        await viewModel.processImageForTesting(_validJpeg());

        final trace = await DescribeAttemptTraceStore().loadLast();

        expect(trace, isNotNull);
        expect(trace!.stage, DescribePipelineStage.completed);
        expect(trace.imageBytes, greaterThan(0));
        expect(trace.visionMode, VisionMode.auto.name);
        // SettingsProvider default is now DetailLevel.brief (reliability
        // overhaul: one opinionated spoken contract).  The trace must echo
        // whatever default SettingsProvider currently ships so the test
        // does not silently drift when the default moves again.
        expect(trace.detailLevel, DetailLevel.brief.name);
      },
    );

    test('surfaces unfinished describe trace on startup', () async {
      final now = DateTime.now();
      SharedPreferences.setMockInitialValues({
        'describe_trace.attemptId': 'previous',
        'describe_trace.stage': DescribePipelineStage.cloudRequest.name,
        'describe_trace.startedAt': now
            .subtract(const Duration(minutes: 1))
            .toIso8601String(),
        'describe_trace.updatedAt': now.toIso8601String(),
        'describe_trace.imageBytes': 12,
        'describe_trace.visionMode': VisionMode.auto.name,
        'describe_trace.detailLevel': DetailLevel.detailed.name,
      });
      final vm = HomeViewModel(
        sceneService: _FakeSceneDescriptionService(),
        ttsService: speech,
        settingsProvider: SettingsProvider(ttsService: speech),
      );

      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);

      expect(vm.lastDiagnostic, contains('Previous Describe did not finish'));
      expect(vm.lastDiagnostic, contains('Cloud describe request'));
      vm.dispose();
    });
  });

  group('SettingsProvider speech defaults', () {
    test('defaults to native iOS/system speech settings', () async {
      SharedPreferences.setMockInitialValues({});
      final speech = _FakeSpeechOutput();
      final settings = SettingsProvider(ttsService: speech);
      await Future<void>.delayed(Duration.zero);

      expect(settings.speechEngine, SpeechEngine.nativeIos);
      expect(settings.speechRate, 0.5);
      expect(settings.pitch, 1.0);
      expect(settings.volume, 1.0);
    });
  });
}

Uint8List _validJpeg() {
  final image = img.Image(width: 2, height: 2);
  return Uint8List.fromList(img.encodeJpg(image));
}

class _FakeSpeechOutput implements TtsSettingsController {
  final List<String> spoken = [];
  double _rate = 0.5;
  double _pitch = 1.0;

  @override
  double get rate => _rate;

  @override
  double get pitch => _pitch;

  @override
  String? get selectedVoiceId => null;

  @override
  Future<void> speak(String text) async {
    spoken.add(text);
  }

  @override
  Future<void> stop() async {}

  @override
  void setRate(double rate) {
    _rate = rate;
  }

  @override
  void setPitch(double pitch) {
    _pitch = pitch;
  }

  @override
  void setVolume(double vol) {}

  @override
  Future<List<TtsVoiceOption>> availableVoices() async => const [];

  @override
  Future<void> setVoice(TtsVoiceOption voice) async {}

  @override
  Future<void> previewVoice([String sample = '']) async {
    spoken.add(sample);
  }
}

class _FakeSceneDescriptionService extends SceneDescriptionService {
  _FakeSceneDescriptionService()
    : super(
        cloudService: VertexAiService(apiKey: 'test-key'),
        onDeviceService: _FakeOnDeviceVisionService(),
      );

  Object? error;
  int describeCalls = 0;

  @override
  Future<SceneDescriptionResult> describeCloud(Uint8List imageBytes) async {
    describeCalls++;
    final failure = error;
    if (failure != null) throw failure;
    return const SceneDescriptionResult(
      text: 'A hallway is clear.',
      backend: VisionBackend.cloud,
      completionMetadata: SceneCompletionMetadata.complete,
    );
  }

  @override
  Future<SceneDescriptionResult> describeOffline(Uint8List imageBytes) async {
    describeCalls++;
    final failure = error;
    if (failure != null) throw failure;
    return const SceneDescriptionResult(
      text: 'A hallway is clear.',
      backend: VisionBackend.visionOnly,
      completionMetadata: SceneCompletionMetadata.complete,
    );
  }

  @override
  Stream<String> describeScene(
    Uint8List imageBytes, {
    required String systemPrompt,
    String userPrompt = 'Describe what you see.',
    int maxOutputTokens = 500,
    void Function(String status, VisionBackend backend)? onStatusUpdate,
  }) async* {
    describeCalls++;
    final failure = error;
    if (failure != null) throw failure;
    yield 'A hallway is clear.';
  }
}

class _FakeOnDeviceVisionService extends OnDeviceVisionService {}
