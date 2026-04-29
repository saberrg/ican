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
  group('SceneDescriptionService explicit offline flow', () {
    late _FakeOnDeviceVisionService onDevice;
    late SceneDescriptionService service;

    setUp(() {
      SharedPreferences.setMockInitialValues({});
      onDevice = _FakeOnDeviceVisionService();
      service = SceneDescriptionService(
        cloudService: _FakeVertexAiService(),
        onDeviceService: onDevice,
      );
    });

    test('uses Foundation Models when available', () async {
      onDevice.foundationModelsAvailable = true;
      onDevice.foundationModelsOutput = 'Foundation model description';

      final result = await service.describeOffline(_jpegBytes);

      expect(result.backend, VisionBackend.foundationModels);
      expect(result.text, 'Foundation model description.');
      expect(onDevice.loadVlmCalls, 0);
      expect(onDevice.analyzeSceneCalls, 0);
      expect(onDevice.analyzeWithVisionCalls, 1);
    });

    test('offline generated prompt receives selected prompt context', () async {
      onDevice.foundationModelsAvailable = true;
      onDevice.foundationModelsOutput = 'Reading output';

      await service.describeOffline(
        _jpegBytes,
        promptContext: const ScenePromptContext(
          profile: PromptProfile.reading,
          detailLevel: DetailLevel.detailed,
          hazardSensitivity: HazardSensitivity.high,
        ),
      );

      expect(
        onDevice.foundationSystemPrompts.single,
        contains('Reading profile'),
      );
      expect(onDevice.foundationSystemPrompts.single, contains('visible text'));
      expect(
        onDevice.foundationSystemPrompts.single,
        contains('150 centimeters'),
      );
    });

    test(
      'loads and uses SmolVLM when Foundation Models are unavailable',
      () async {
        onDevice.modelStatus = ModelStatus.ready;
        onDevice.loadVlmResult = true;
        onDevice.vlmOutput = 'SmolVLM2 description';

        final result = await service.describeOffline(_jpegBytes);

        expect(result.backend, VisionBackend.vlm);
        expect(result.text, 'SmolVLM2 description.');
        expect(onDevice.loadVlmCalls, 1);
        expect(onDevice.analyzeSceneCalls, 0);
        expect(onDevice.analyzeWithVisionCalls, 1);
      },
    );

    test(
      'falls back to SmolVLM when Foundation Models produce no output',
      () async {
        onDevice.foundationModelsAvailable = true;
        onDevice.foundationModelsOutput = '';
        onDevice.modelStatus = ModelStatus.loaded;
        onDevice.vlmOutput = 'SmolVLM2 description';

        final result = await service.describeOffline(_jpegBytes);

        expect(result.backend, VisionBackend.vlm);
        expect(result.text, 'SmolVLM2 description.');
        expect(onDevice.loadVlmCalls, 0);
        expect(onDevice.analyzeSceneCalls, 0);
        expect(onDevice.analyzeWithVisionCalls, 1);
      },
    );

    test(
      'falls back to spatial template when generative backends fail',
      () async {
        onDevice.foundationModelsAvailable = true;
        onDevice.foundationModelsError = StateError('FM failed');
        onDevice.modelStatus = ModelStatus.ready;
        onDevice.loadVlmResult = true;
        onDevice.vlmError = const LocalVisionException(
          'Local L20',
          'SmolVLM2 failed.',
        );

        final result = await service.describeOffline(_jpegBytes);

        expect(result.backend, VisionBackend.visionOnly);
        expect(result.text, contains('hallway setting'));
        expect(onDevice.loadVlmCalls, 1);
        expect(onDevice.analyzeSceneCalls, 0);
        expect(onDevice.analyzeWithVisionCalls, 1);
      },
    );

    test(
      'reports local failure when Apple Vision cannot analyze the image',
      () async {
        onDevice.analyzeWithVisionError = const LocalVisionException(
          'Local L03',
          'Apple Vision failed.',
        );

        await expectLater(
          service.describeOffline(_jpegBytes),
          throwsA(
            isA<SceneDescriptionException>()
                .having(
                  (e) => e.stage,
                  'stage',
                  SceneDescriptionFailureStage.localVision,
                )
                .having((e) => e.cause, 'cause', isA<LocalVisionException>()),
          ),
        );

        expect(onDevice.loadVlmCalls, 0);
        expect(onDevice.analyzeWithVisionCalls, 1);
      },
    );
  });

  group('SceneDescriptionService cloud fallback', () {
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

    test('Auto mode falls back to local vision after cloud failure', () async {
      cloud.error = CloudVisionException.httpStatus(403);
      onDevice.nativeReady = true;
      onDevice.appleVisionReady = true;

      final chunks = await service
          .describeScene(_jpegBytes, systemPrompt: 'Describe safely.')
          .toList();

      expect(cloud.streamCalls, 1);
      expect(service.lastCloudFailure, isA<CloudVisionException>());
      expect(service.lastBackend, VisionBackend.visionOnly);
      expect(chunks.join(), contains('hallway setting'));
      expect(onDevice.analyzeSceneCalls, 0);
      expect(onDevice.analyzeWithVisionCalls, 1);
    });

    test(
      'Auto mode blocks local fallback when native Vision is unhealthy',
      () async {
        cloud.error = CloudVisionException.httpStatus(403);
        onDevice.nativeReady = false;
        onDevice.appleVisionReady = false;

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
        expect(onDevice.analyzeSceneCalls, 0);
      },
    );

    test('Cloud-only mode reports cloud failure without fallback', () async {
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
      expect(onDevice.analyzeSceneCalls, 0);
    });

    test('cloud prompt receives selected prompt context', () async {
      await service.setMode(VisionMode.cloudOnly);

      await service.describeCloud(
        _jpegBytes,
        promptContext: const ScenePromptContext(
          profile: PromptProfile.safety,
          detailLevel: DetailLevel.brief,
          hazardSensitivity: HazardSensitivity.high,
        ),
      );

      expect(cloud.systemPrompts.single, contains('Safety profile'));
      expect(cloud.systemPrompts.single, contains('150 centimeters'));
      expect(cloud.userPrompts.single, contains('safety-first'));
    });

    test(
      'Gemini MAX_TOKENS retries continuation before yielding text',
      () async {
        await service.setMode(VisionMode.cloudOnly);
        cloud.responseChunks = [
          ['A hallway has a clear'],
          [' path ahead.'],
        ];
        cloud.finishReasons = ['MAX_TOKENS', 'STOP'];

        final chunks = await service
            .describeScene(_jpegBytes, systemPrompt: 'Describe safely.')
            .toList();

        expect(cloud.streamCalls, 2);
        expect(chunks, ['A hallway has a clear path ahead.']);
        expect(service.lastCompletionMetadata.didRetryContinuation, isTrue);
        expect(service.lastCompletionMetadata.wasTruncated, isFalse);
      },
    );

    test(
      'Gemini continuation meta text is stripped from spoken output',
      () async {
        await service.setMode(VisionMode.cloudOnly);
        cloud.responseChunks = [
          ['A hallway has a clear path ahead.'],
          ['The description was cut off.'],
        ];
        cloud.finishReasons = ['MAX_TOKENS', 'STOP'];

        final chunks = await service
            .describeScene(_jpegBytes, systemPrompt: 'Describe safely.')
            .toList();

        expect(cloud.streamCalls, 2);
        expect(chunks.single, 'A hallway has a clear path ahead.');
        expect(chunks.single.toLowerCase(), isNot(contains('cut off')));
        expect(
          cloud.userPrompts.last.toLowerCase(),
          isNot(contains('cut off')),
        );
        expect(
          cloud.userPrompts.last.toLowerCase(),
          isNot(contains('previous response')),
        );
      },
    );

    test(
      'Gemini incomplete useful text without MAX_TOKENS is rescued locally',
      () async {
        await service.setMode(VisionMode.cloudOnly);
        cloud.responseChunks = [
          ['A hallway has a clear path ahead'],
        ];
        cloud.finishReasons = ['STOP'];

        final chunks = await service
            .describeScene(_jpegBytes, systemPrompt: 'Describe safely.')
            .toList();

        expect(cloud.streamCalls, 1);
        expect(chunks.single, 'A hallway has a clear path ahead.');
        expect(service.lastCompletionMetadata.didRetryContinuation, isFalse);
        expect(service.lastCompletionMetadata.wasTruncated, isFalse);
      },
    );

    test(
      'Gemini MAX_TOKENS continuation joins useful visual text only',
      () async {
        await service.setMode(VisionMode.cloudOnly);
        cloud.responseChunks = [
          ['A hallway has a clear path ahead.'],
          ['The previous response hit the token limit. A red chair is ahead.'],
        ];
        cloud.finishReasons = ['MAX_TOKENS', 'STOP'];

        final chunks = await service
            .describeScene(_jpegBytes, systemPrompt: 'Describe safely.')
            .toList();

        expect(
          chunks.single,
          'A hallway has a clear path ahead. A red chair is ahead.',
        );
        expect(
          chunks.single.toLowerCase(),
          isNot(contains('previous response')),
        );
        expect(chunks.single.toLowerCase(), isNot(contains('token limit')));
      },
    );

    test('Gemini MAX_TOKENS with no punctuation never says cut off', () async {
      await service.setMode(VisionMode.cloudOnly);
      cloud.responseChunks = [
        ['A hallway has a clear path ahead with an exit sign'],
        [' and a chair directly ahead'],
      ];
      cloud.finishReasons = ['MAX_TOKENS', 'MAX_TOKENS'];

      final chunks = await service
          .describeScene(_jpegBytes, systemPrompt: 'Describe safely.')
          .toList();

      expect(
        chunks.single,
        'A hallway has a clear path ahead with an exit sign and a chair directly ahead.',
      );
      expect(chunks.single, isNot(contains('cut off')));
      expect(service.lastCompletionMetadata.wasTruncated, isTrue);
    });

    test(
      'Gemini partial complete sentence returns complete prefix only',
      () async {
        await service.setMode(VisionMode.cloudOnly);
        cloud.responseChunks = [
          ['A hallway has a clear path ahead. A sign says'],
          [' EXIT'],
        ];
        cloud.finishReasons = ['MAX_TOKENS', 'MAX_TOKENS'];

        final chunks = await service
            .describeScene(_jpegBytes, systemPrompt: 'Describe safely.')
            .toList();

        expect(chunks.single, 'A hallway has a clear path ahead.');
        expect(chunks.single, isNot(contains('cut off')));
        expect(service.lastCompletionMetadata.wasTruncated, isTrue);
      },
    );

    test('"I see" meta openings are stripped from Gemini output', () async {
      await service.setMode(VisionMode.cloudOnly);
      cloud.responseChunks = [
        ['I see a clear hallway. The exit sign is at 11 o clock.'],
      ];
      cloud.finishReasons = ['STOP'];

      final chunks = await service
          .describeScene(_jpegBytes, systemPrompt: 'Describe safely.')
          .toList();

      expect(chunks.single.toLowerCase(), isNot(contains('i see')));
      expect(chunks.single, contains('The exit sign is at 11 o clock.'));
    });

    test(
      '"The image shows" meta openings are stripped from Gemini output',
      () async {
        await service.setMode(VisionMode.cloudOnly);
        cloud.responseChunks = [
          ['The image shows a chair. A red chair is at 2 o clock.'],
        ];
        cloud.finishReasons = ['STOP'];

        final chunks = await service
            .describeScene(_jpegBytes, systemPrompt: 'Describe safely.')
            .toList();

        expect(chunks.single.toLowerCase(), isNot(contains('image shows')));
        expect(chunks.single, contains('A red chair is at 2 o clock.'));
      },
    );

    test('Gemini empty truncated output reports cloud diagnostic', () async {
      await service.setMode(VisionMode.cloudOnly);
      cloud.responseChunks = [
        [''],
        [''],
      ];
      cloud.finishReasons = ['MAX_TOKENS', 'MAX_TOKENS'];

      await expectLater(
        service
            .describeScene(_jpegBytes, systemPrompt: 'Describe safely.')
            .toList(),
        throwsA(
          isA<CloudVisionException>().having(
            (e) => e.kind,
            'kind',
            CloudVisionFailureKind.malformedResponse,
          ),
        ),
      );
    });
  });
}

final _jpegBytes = Uint8List.fromList([0xff, 0xd8, 0xff, 0xd9]);

class _FakeOnDeviceVisionService extends OnDeviceVisionService {
  bool foundationModelsAvailable = false;
  ModelStatus modelStatus = ModelStatus.notDownloaded;
  bool loadVlmResult = false;
  bool nativeReady = false;
  bool appleVisionReady = false;
  bool vlmProducesOutput = true;
  String foundationModelsOutput = 'Foundation model description.';
  String vlmOutput = 'SmolVLM2 description.';
  Object? foundationModelsError;
  Object? vlmError;
  Object? analyzeSceneError;
  Object? analyzeWithVisionError;
  int loadVlmCalls = 0;
  int analyzeWithVisionCalls = 0;
  int analyzeSceneCalls = 0;
  final List<String> foundationSystemPrompts = [];
  final List<String> vlmSystemPrompts = [];

  @override
  Future<bool> isFoundationModelsAvailable() async => foundationModelsAvailable;

  @override
  Future<ModelStatus> getModelStatus() async => modelStatus;

  @override
  Future<bool> pingNativeChannel() async => nativeReady;

  @override
  Future<bool> isAppleVisionAvailable() async => appleVisionReady;

  @override
  Future<bool> loadVlmModel() async {
    loadVlmCalls++;
    return loadVlmResult;
  }

  @override
  Future<ScenePerceptionResult> analyzeScene(Uint8List jpegBytes) async {
    analyzeSceneCalls++;
    final failure = analyzeSceneError;
    if (failure != null) throw failure;
    return const ScenePerceptionResult(
      ocrTexts: ['EXIT'],
      sceneClassification: 'hallway',
      sceneConfidence: 0.91,
      personCount: 1,
      personRects: [],
      detectedObjects: [
        SpatialObjectData(
          label: 'chair',
          confidence: 0.82,
          clockPosition: 12,
          relativeDepth: 0.24,
          centerX: 0.5,
          centerY: 0.5,
        ),
      ],
      hasDepthMap: true,
    );
  }

  @override
  Future<VisionAnalysis> analyzeWithVision(Uint8List jpegBytes) async {
    analyzeWithVisionCalls++;
    final failure = analyzeWithVisionError;
    if (failure != null) throw failure;
    return const VisionAnalysis(
      ocrTexts: ['EXIT'],
      sceneClassification: 'hallway',
      sceneConfidence: 0.91,
      personCount: 1,
      personRects: [],
    );
  }

  @override
  Stream<String> synthesizeWithFoundationModels(
    String context, {
    required String systemPrompt,
  }) async* {
    foundationSystemPrompts.add(systemPrompt);
    final failure = foundationModelsError;
    if (failure != null) throw failure;
    if (foundationModelsOutput.isNotEmpty) yield foundationModelsOutput;
  }

  @override
  Stream<String> describeWithVlm(
    Uint8List jpegBytes, {
    required String systemPrompt,
    String? visionContext,
  }) async* {
    vlmSystemPrompts.add(systemPrompt);
    final failure = vlmError;
    if (failure != null) throw failure;
    if (!vlmProducesOutput) return;
    if (vlmOutput.isNotEmpty) yield vlmOutput;
  }
}

class _FakeVertexAiService extends VertexAiService {
  Object? error;
  int streamCalls = 0;
  final List<String> systemPrompts = [];
  final List<String> userPrompts = [];
  List<List<String>> responseChunks = const [
    ['Cloud description.'],
  ];
  List<String?> finishReasons = const [null];
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
    systemPrompts.add(systemPrompt);
    userPrompts.add(userPrompt);
    final failure = error;
    if (failure != null) throw failure;
    final index = streamCalls - 1;
    _lastFinishReason = index < finishReasons.length
        ? finishReasons[index]
        : (finishReasons.isEmpty ? null : finishReasons.last);
    final chunks = index < responseChunks.length
        ? responseChunks[index]
        : responseChunks.last;
    for (final chunk in chunks) {
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
