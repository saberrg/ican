import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:ican/models/settings_provider.dart';
import 'package:ican/protocol/ble_protocol.dart';
import 'package:ican/services/ble_service.dart';
import 'package:ican/services/live_detection_controller.dart';
import 'package:ican/services/on_device_vision_service.dart';
import 'package:ican/services/tts_service.dart';
import 'package:ican/services/vertex_ai_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    BleService.instance.resetEyeReliabilityForTesting();
    BleService.instance.setEyeConnectionStateForTesting(
      BleConnectionState.connected,
    );
    BleService.instance.updateEyeReadinessForTesting(
      BleReadinessPhase.ready,
      requiredCharacteristicsReady: true,
      commandPathReady: true,
    );
    BleService.instance.enableEyeCommandLoopbackForTesting();
  });

  tearDown(() {
    BleService.instance.resetEyeReliabilityForTesting();
    BleService.instance.setEyeConnectionStateForTesting(
      BleConnectionState.disconnected,
    );
  });

  test('LiveX starts fast capture and speaks spatial clock details', () async {
    final tts = _FakeSpeechOutput();
    final vision = _FakeOnDeviceVisionService(
      sceneResult: const ScenePerceptionResult(
        ocrTexts: ['Main Street'],
        sceneClassification: 'sidewalk',
        sceneConfidence: 0.91,
        personCount: 0,
        personRects: [],
        detectedObjects: [
          SpatialObjectData(
            label: 'tree',
            confidence: 0.92,
            clockPosition: 1,
            relativeDepth: 0.28,
            centerX: 0.72,
            centerY: 0.5,
          ),
          SpatialObjectData(
            label: 'bench',
            confidence: 0.78,
            clockPosition: 11,
            relativeDepth: 0.62,
            centerX: 0.25,
            centerY: 0.5,
          ),
        ],
        hasDepthMap: true,
      ),
    );
    final controller = LiveDetectionController(
      onDeviceService: vision,
      ttsService: tts,
      verbosityProvider: () => LiveDetectionVerbosity.full,
    );

    await controller.start();
    BleService.instance.emitEyeImageForTesting(_validJpeg());
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);

    expect(
      BleService.instance.eyeCommandsSentForTesting,
      contains(EyeCommands.profile(EyeProfileIndex.fast)),
    );
    expect(
      BleService.instance.eyeCommandsSentForTesting,
      contains(EyeCommands.liveStart(900)),
    );
    expect(tts.spoken, contains('LiveX started.'));
    expect(tts.spoken.last, contains("tree at your 1 o'clock"));
    expect(tts.spoken.last, contains('within reach'));
    expect(tts.spoken.last, contains('Text reads Main Street'));
    expect(vision.analyzeSceneCalls, 1);
    expect(vision.analyzeLiveFrameCalls, 0);

    await controller.stop(speak: false);
    controller.dispose();
  });

  test('localOnly policy never calls the cloud', () async {
    final tts = _FakeSpeechOutput();
    final vision = _FakeOnDeviceVisionService(sceneResult: _stableSceneResult);
    final cloud = _FakeVertexAiService()..configuredForTest = true;
    final controller = LiveDetectionController(
      onDeviceService: vision,
      cloudService: cloud,
      ttsService: tts,
      verbosityProvider: () => LiveDetectionVerbosity.full,
      cloudPolicyProvider: () => LiveCloudPolicy.localOnly,
    );

    await controller.start();
    // Emit enough stable frames to exceed Tier 1 hold + Tier 2 hold.
    for (var i = 0; i < 30; i++) {
      BleService.instance.emitEyeImageForTesting(_validJpeg());
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }

    expect(cloud.streamCalls, 0);
    expect(controller.cloudCallsUsed, 0);

    await controller.stop(speak: false);
    controller.dispose();
  });

  test('cloud call counter increments on hybrid policy', () async {
    final tts = _FakeSpeechOutput();
    final vision = _FakeOnDeviceVisionService(sceneResult: _stableSceneResult);
    final cloud = _FakeVertexAiService()
      ..configuredForTest = true
      ..responseChunks = [
        ['Cloud tier 2.'],
        ['Cloud tier 3.'],
      ];
    final controller = LiveDetectionController(
      onDeviceService: vision,
      cloudService: cloud,
      ttsService: tts,
      verbosityProvider: () => LiveDetectionVerbosity.full,
      cloudPolicyProvider: () => LiveCloudPolicy.hybridOnSceneChange,
    );

    expect(controller.cloudCallsMax, 10);
    expect(controller.cloudCallsUsed, 0);

    await controller.start();
    expect(controller.cloudCallsUsed, 0);

    await controller.stop(speak: false);
    controller.dispose();
  });

  test('LiveX falls back to the stable live lane with position', () async {
    final tts = _FakeSpeechOutput();
    final vision = _FakeOnDeviceVisionService(
      sceneError: const LocalVisionException(
        'Local L02',
        'Spatial models unavailable.',
      ),
      liveResult: const VisionAnalysis(
        ocrTexts: [],
        sceneClassification: 'hallway',
        sceneConfidence: 0.8,
        personCount: 1,
        personRects: [
          {'x': 0.68, 'y': 0.1, 'w': 0.12, 'h': 0.6},
        ],
      ),
    );
    final controller = LiveDetectionController(
      onDeviceService: vision,
      ttsService: tts,
      verbosityProvider: () => LiveDetectionVerbosity.full,
    );

    await controller.start();
    BleService.instance.emitEyeImageForTesting(_validJpeg());
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);

    expect(tts.spoken.last, 'Person at your 1 o\'clock.');
    expect(vision.analyzeSceneCalls, 1);
    expect(vision.analyzeLiveFrameCalls, 1);

    await controller.stop(speak: false);
    controller.dispose();
  });
}

class _FakeOnDeviceVisionService extends OnDeviceVisionService {
  _FakeOnDeviceVisionService({
    this.sceneResult,
    this.sceneError,
    this.liveResult = const VisionAnalysis(
      ocrTexts: [],
      sceneClassification: 'unknown',
      sceneConfidence: 0,
      personCount: 0,
      personRects: [],
    ),
  });

  final ScenePerceptionResult? sceneResult;
  final Object? sceneError;
  final VisionAnalysis liveResult;
  int analyzeSceneCalls = 0;
  int analyzeLiveFrameCalls = 0;

  @override
  Future<ScenePerceptionResult> analyzeScene(Uint8List jpegBytes) async {
    analyzeSceneCalls++;
    final error = sceneError;
    if (error != null) throw error;
    return sceneResult!;
  }

  @override
  Future<VisionAnalysis> analyzeLiveFrame(Uint8List jpegBytes) async {
    analyzeLiveFrameCalls++;
    return liveResult;
  }
}

class _FakeSpeechOutput implements SpeechOutput {
  final List<String> spoken = [];

  @override
  Future<void> speak(String text) async {
    spoken.add(text);
  }

  @override
  Future<void> stop() async {}
}

Uint8List _validJpeg() {
  final bytes = Uint8List(1200);
  bytes[0] = 0xff;
  bytes[1] = 0xd8;
  bytes[1198] = 0xff;
  bytes[1199] = 0xd9;
  return bytes;
}

const _stableSceneResult = ScenePerceptionResult(
  ocrTexts: [],
  sceneClassification: 'hallway',
  sceneConfidence: 0.85,
  personCount: 0,
  personRects: [],
  detectedObjects: [
    SpatialObjectData(
      label: 'chair',
      confidence: 0.9,
      clockPosition: 12,
      relativeDepth: 0.3,
      centerX: 0.5,
      centerY: 0.5,
    ),
    SpatialObjectData(
      label: 'table',
      confidence: 0.7,
      clockPosition: 1,
      relativeDepth: 0.5,
      centerX: 0.6,
      centerY: 0.5,
    ),
  ],
  hasDepthMap: true,
);

class _FakeVertexAiService extends VertexAiService {
  int streamCalls = 0;
  bool configuredForTest = true;
  List<List<String>> responseChunks = const [
    ['Cloud chunk.'],
  ];

  @override
  bool get isConfigured => configuredForTest;

  @override
  Stream<String> streamContentFromImage(
    Uint8List imageBytes, {
    required String systemPrompt,
    String userPrompt = 'Describe what you see.',
    int maxOutputTokens = 500,
  }) async* {
    streamCalls++;
    final idx = streamCalls - 1;
    final chunks = idx < responseChunks.length
        ? responseChunks[idx]
        : responseChunks.last;
    for (final chunk in chunks) {
      yield chunk;
    }
  }
}
