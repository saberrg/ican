import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:ican/models/home_view_model.dart';
import 'package:ican/models/settings_provider.dart';
import 'package:ican/protocol/ble_protocol.dart';
import 'package:ican/protocol/describe_attempt_trace.dart';
import 'package:ican/protocol/eye_capture_diagnostics.dart';
import 'package:ican/services/ble_service.dart';
import 'package:ican/services/on_device_vision_service.dart';
import 'package:ican/services/scene_description_service.dart';
import 'package:ican/services/scene_prompt_builder.dart';
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
      BleService.instance.resetEyeReliabilityForTesting();
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
      BleService.instance.resetEyeReliabilityForTesting();
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

    test(
      'offline Describe sends original Eye JPEG without enhancement',
      () async {
        final jpeg = _validJpeg();

        await viewModel.processImageForTesting(jpeg, offline: true);

        expect(sceneService.offlineImageBytes, same(jpeg));
        expect(sceneService.cloudImageBytes, isNull);
        expect(speech.spoken.last, 'A hallway is clear.');
      },
    );

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

    test('Describe requests BALANCED Eye profile before capture', () async {
      settingsReadyForDescribe(viewModel);
      BleService.instance.enableEyeCommandLoopbackForTesting();

      final resultFuture = viewModel.describeNow();
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);

      expect(
        BleService.instance.eyeCommandsSentForTesting,
        contains(EyeCommands.profile(EyeProfileIndex.balanced)),
      );
      expect(
        BleService.instance.eyeCommandsSentForTesting,
        contains(EyeCommands.capture),
      );
      await viewModel.handleEyeCaptureDiagnosticForTesting(_e01());
      await resultFuture;
    });

    test('Eye long press cycles the active vision mode', () async {
      expect(viewModel.visionControlMode, VisionControlMode.cloud);

      BleService.instance.handleEyeControlMessageForTesting(
        EyeEvents.buttonLong,
      );
      await Future<void>.delayed(Duration.zero);

      expect(viewModel.visionControlMode, VisionControlMode.local);
      expect(speech.spoken, contains('Local mode selected.'));
    });

    test('Eye single press executes the selected cloud mode', () async {
      settingsReadyForDescribe(viewModel);
      BleService.instance.enableEyeCommandLoopbackForTesting();

      BleService.instance.handleEyeControlMessageForTesting(
        EyeEvents.buttonSingle,
      );
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);

      expect(
        BleService.instance.eyeCommandsSentForTesting,
        contains(EyeCommands.profile(EyeProfileIndex.balanced)),
      );
      expect(
        BleService.instance.eyeCommandsSentForTesting,
        contains(EyeCommands.capture),
      );

      await viewModel.handleEyeCaptureDiagnosticForTesting(_e01());
      await Future<void>.delayed(Duration.zero);
      expect(viewModel.isProcessing, isFalse);
    });

    test('unclear quality-flagged image retries once before speaking', () async {
      viewModel.dispose();
      sceneService = _FakeSceneDescriptionService();
      speech = _FakeSpeechOutput();
      viewModel = HomeViewModel(
        sceneService: sceneService,
        ttsService: speech,
        settingsProvider: SettingsProvider(ttsService: speech),
        processingTimeout: const Duration(seconds: 1),
      );
      await Future<void>.delayed(Duration.zero);
      speech.spoken.clear();
      settingsReadyForDescribe(viewModel);
      BleService.instance.enableEyeCommandLoopbackForTesting();
      sceneService.responses = [
        'The scene could not be clearly identified.',
        'A brighter hallway is clear.',
      ];

      final resultFuture = viewModel.describeNow();
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);
      BleService.instance.handleEyeControlMessageForTesting(
        'STATUS:0:FAST:IDLE:1500:1.0.0+26:8000000:247:240:none:OV3660:16000:700:70:5:55:40:boost_light_contrast',
      );
      BleService.instance.emitEyeImageForTesting(_validJpeg());
      await Future<void>.delayed(const Duration(milliseconds: 80));

      expect(
        BleService.instance.eyeCommandsSentForTesting
            .where((command) => command == EyeCommands.capture)
            .length,
        greaterThanOrEqualTo(2),
      );

      BleService.instance.handleEyeControlMessageForTesting(
        'STATUS:0:FAST:IDLE:1500:1.0.0+26:8000000:247:240:none:OV3660:15000:650:65:0:120:180:hold',
      );
      BleService.instance.emitEyeImageForTesting(_validJpeg(red: 32));

      final result = await resultFuture;
      expect(result, 'Scene description complete.');
      expect(speech.spoken, contains('A brighter hallway is clear.'));
      expect(
        speech.spoken,
        isNot(contains('The scene could not be clearly identified.')),
      );
      expect(sceneService.describeCalls, 2);
    });

    test('profile ack timeout falls back and still triggers capture', () async {
      settingsReadyForDescribe(viewModel);
      BleService.instance.setEyeProfileAckTimeoutForTesting(
        const Duration(milliseconds: 1),
      );
      BleService.instance.enableEyeCommandLoopbackForTesting(
        autoProfileAck: false,
      );

      final resultFuture = viewModel.describeNow();
      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect(
        BleService.instance.eyeCommandsSentForTesting,
        contains(EyeCommands.profile(EyeProfileIndex.balanced)),
      );
      expect(
        BleService.instance.eyeCommandsSentForTesting,
        contains(EyeCommands.capture),
      );
      await viewModel.handleEyeCaptureDiagnosticForTesting(_e01());
      await resultFuture;
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
        // The trace must echo
        // whatever default SettingsProvider currently ships so the test
        // does not silently drift when the default moves again.
        expect(trace.detailLevel, DetailLevel.detailed.name);
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

void settingsReadyForDescribe(HomeViewModel viewModel) {
  BleService.instance.setEyeConnectionStateForTesting(
    BleConnectionState.connected,
  );
  BleService.instance.updateEyeReadinessForTesting(
    BleReadinessPhase.ready,
    requiredCharacteristicsReady: true,
    commandPathReady: true,
  );
}

EyeCaptureDiagnostic _e01() {
  return const EyeCaptureDiagnostic(
    code: EyeCaptureDiagnosticCode.noCaptureStartOrSize,
    captureStarted: false,
    sizeArrived: false,
    expectedBytes: 0,
    receivedBytes: 0,
    uniqueChunks: 0,
    duplicateChunks: 0,
    endArrived: false,
    jpegMagicValid: false,
    jpegEndValid: false,
    timeoutStage: EyeTransferTimeoutStage.awaitingCaptureStart,
  );
}

Uint8List _validJpeg({int red = 0}) {
  final image = img.Image(width: 2, height: 2);
  image.setPixelRgb(0, 0, red, 0, 0);
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
  List<String>? responses;
  int describeCalls = 0;
  Uint8List? cloudImageBytes;
  Uint8List? offlineImageBytes;
  ScenePromptContext? lastPromptContext;

  String _nextResponse() {
    final queued = responses;
    if (queued != null && queued.isNotEmpty) return queued.removeAt(0);
    return 'A hallway is clear.';
  }

  @override
  Future<SceneDescriptionResult> describeCloud(
    Uint8List imageBytes, {
    ScenePromptContext promptContext = const ScenePromptContext(),
  }) async {
    describeCalls++;
    cloudImageBytes = imageBytes;
    lastPromptContext = promptContext;
    final failure = error;
    if (failure != null) throw failure;
    return SceneDescriptionResult(
      text: _nextResponse(),
      backend: VisionBackend.cloud,
      completionMetadata: SceneCompletionMetadata.complete,
    );
  }

  @override
  Future<SceneDescriptionResult> describeOffline(
    Uint8List imageBytes, {
    ScenePromptContext promptContext = const ScenePromptContext(),
  }) async {
    describeCalls++;
    offlineImageBytes = imageBytes;
    lastPromptContext = promptContext;
    final failure = error;
    if (failure != null) throw failure;
    return SceneDescriptionResult(
      text: _nextResponse(),
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
    ScenePromptContext promptContext = const ScenePromptContext(),
    void Function(String status, VisionBackend backend)? onStatusUpdate,
  }) async* {
    describeCalls++;
    lastPromptContext = promptContext;
    final failure = error;
    if (failure != null) throw failure;
    yield _nextResponse();
  }
}

class _FakeOnDeviceVisionService extends OnDeviceVisionService {}
