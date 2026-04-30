import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:ican/models/settings_provider.dart';
import 'package:ican/services/connectivity_service.dart';
import 'package:ican/services/on_device_vision_service.dart';
import 'package:ican/services/scene_description_service.dart';
import 'package:ican/services/scene_prompt_builder.dart';
import 'package:ican/services/vertex_ai_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  late _FakeVertexAiService cloud;
  late _FakeOnDeviceVisionService onDevice;
  late _FakeConnectivityService connectivity;
  late SceneDescriptionService service;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    cloud = _FakeVertexAiService();
    onDevice = _FakeOnDeviceVisionService();
    connectivity = _FakeConnectivityService(online: true);
    service = SceneDescriptionService(
      cloudService: cloud,
      onDeviceService: onDevice,
      connectivityService: connectivity,
    );
  });

  test('offline mode uses Gemma after readiness passes', () async {
    onDevice.gemmaReadinessPassed = true;
    onDevice.gemmaOutput = _richGemmaDescription;

    final result = await service.describeOffline(_jpegBytes);

    expect(result.backend, VisionBackend.gemma);
    expect(result.text, _richGemmaDescription);
    expect(onDevice.gemmaReadinessCalls, 1);
    expect(onDevice.gemmaSystemPrompts.single, contains('readable text'));
    expect(onDevice.analyzeSceneCalls, 0);
    expect(onDevice.analyzeWithVisionCalls, 0);
  });

  test(
    'offline mode fails closed when Gemma readiness has not passed',
    () async {
      onDevice.gemmaReadinessPassed = false;

      await expectLater(
        service.describeOffline(_jpegBytes),
        throwsA(
          isA<SceneDescriptionException>()
              .having(
                (e) => e.stage,
                'stage',
                SceneDescriptionFailureStage.localVision,
              )
              .having((e) => e.userMessage, 'userMessage', contains('Gemma')),
        ),
      );

      expect(onDevice.gemmaSystemPrompts, isEmpty);
      expect(onDevice.analyzeSceneCalls, 0);
    },
  );

  test('offline prompt receives selected prompt context', () async {
    onDevice.gemmaReadinessPassed = true;
    onDevice.gemmaOutput = 'Reading output';

    await service.describeOffline(
      _jpegBytes,
      promptContext: const ScenePromptContext(
        detailLevel: DetailLevel.detailed,
        hazardSensitivity: HazardSensitivity.high,
      ),
    );

    expect(
      onDevice.gemmaSystemPrompts.single,
      contains('Report hazards, layout, readable text verbatim, and landmarks'),
    );
    expect(onDevice.gemmaSystemPrompts.single, contains('150 centimeters'));
  });

  test('auto mode is cloud first', () async {
    cloud.responseChunks = const [
      ['Cloud description.'],
    ];

    final chunks = await service
        .describeScene(_jpegBytes, systemPrompt: 'Describe safely.')
        .toList();

    expect(chunks.single, 'Cloud description.');
    expect(cloud.streamCalls, 1);
    expect(onDevice.gemmaReadinessCalls, 0);
    expect(service.lastBackend, VisionBackend.cloud);
  });

  test('auto mode falls back to Gemma after cloud failure', () async {
    cloud.error = CloudVisionException.httpStatus(403);
    onDevice.nativeReady = true;
    onDevice.gemmaReadinessPassed = true;
    onDevice.gemmaOutput = _richGemmaDescription;

    final chunks = await service
        .describeScene(_jpegBytes, systemPrompt: 'Describe safely.')
        .toList();

    expect(cloud.streamCalls, 1);
    expect(service.lastCloudFailure, isA<CloudVisionException>());
    expect(service.lastBackend, VisionBackend.gemma);
    expect(chunks.join(), _richGemmaDescription);
  });

  test(
    'auto mode blocks local fallback when native channel is unhealthy',
    () async {
      cloud.error = CloudVisionException.httpStatus(403);
      onDevice.nativeReady = false;
      onDevice.gemmaReadinessPassed = true;

      await expectLater(
        service
            .describeScene(_jpegBytes, systemPrompt: 'Describe safely.')
            .toList(),
        throwsA(
          isA<SceneDescriptionException>()
              .having(
                (e) => e.stage,
                'stage',
                SceneDescriptionFailureStage.localVision,
              )
              .having((e) => e.cloudFailure, 'cloudFailure', isNotNull),
        ),
      );

      expect(cloud.streamCalls, 1);
      expect(onDevice.gemmaReadinessCalls, 0);
    },
  );

  test('cloud-only mode reports cloud failure without fallback', () async {
    cloud.error = CloudVisionException.httpStatus(429);
    await service.setMode(VisionMode.cloudOnly);

    await expectLater(
      service
          .describeScene(_jpegBytes, systemPrompt: 'Describe safely.')
          .toList(),
      throwsA(
        isA<CloudVisionException>()
            .having((e) => e.kind, 'kind', CloudVisionFailureKind.httpStatus)
            .having((e) => e.statusCode, 'statusCode', 429),
      ),
    );

    expect(cloud.streamCalls, 1);
    expect(service.lastBackend, VisionBackend.cloud);
    expect(onDevice.gemmaReadinessCalls, 0);
  });
}

final _jpegBytes = Uint8List.fromList([0xff, 0xd8, 0xff, 0xd9]);

const _richGemmaDescription =
    'Caution: a chair is directly ahead at 12 o clock within reach. The hallway is open beyond it with a person nearby. Text reads EXIT near the top of the scene.';

class _FakeOnDeviceVisionService extends OnDeviceVisionService {
  bool gemmaReadinessPassed = false;
  bool nativeReady = false;
  String gemmaOutput = _richGemmaDescription;
  Object? gemmaError;
  int gemmaReadinessCalls = 0;
  int analyzeWithVisionCalls = 0;
  int analyzeSceneCalls = 0;
  final List<String> gemmaSystemPrompts = [];

  @override
  Future<bool> pingNativeChannel() async => nativeReady;

  @override
  Future<bool> isGemmaReadyForDescribe(
    Uint8List jpegBytes, {
    String systemPrompt =
        'Describe this image for a blind user in 3 complete spoken sentences with hazards, layout, text, and path details.',
  }) async {
    gemmaReadinessCalls++;
    return gemmaReadinessPassed;
  }

  @override
  Stream<String> describeWithGemma(
    Uint8List jpegBytes, {
    required String systemPrompt,
    String? visionContext,
  }) async* {
    gemmaSystemPrompts.add(systemPrompt);
    final failure = gemmaError;
    if (failure != null) throw failure;
    if (gemmaOutput.isNotEmpty) yield gemmaOutput;
  }

  @override
  Future<ScenePerceptionResult> analyzeScene(Uint8List jpegBytes) async {
    analyzeSceneCalls++;
    throw StateError('Describe should not call perception for Gemma local.');
  }

  @override
  Future<VisionAnalysis> analyzeWithVision(Uint8List jpegBytes) async {
    analyzeWithVisionCalls++;
    throw StateError('Describe should not call Apple Vision for Gemma local.');
  }
}

class _FakeVertexAiService extends VertexAiService {
  Object? error;
  int streamCalls = 0;
  List<List<String>> responseChunks = const [
    ['Cloud description.'],
  ];
  String? _lastFinishReason;

  @override
  String? get lastFinishReason => _lastFinishReason;

  @override
  Stream<String> streamContentFromImage(
    Uint8List imageBytes, {
    required String systemPrompt,
    String userPrompt = 'Describe what you see.',
    int maxOutputTokens = 500,
  }) async* {
    streamCalls++;
    final failure = error;
    if (failure != null) throw failure;
    _lastFinishReason = null;
    for (final chunk
        in responseChunks[(streamCalls - 1).clamp(
          0,
          responseChunks.length - 1,
        )]) {
      yield chunk;
    }
  }
}

class _FakeConnectivityService extends ConnectivityService {
  _FakeConnectivityService({required this.online});

  final bool online;

  @override
  Future<bool> hasInternet() async => online;
}
