import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ican/services/on_device_vision_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Build a JPEG envelope big enough to pass `isLikelyValidJpeg`. Contents in
/// the middle are irrelevant to the tests — only the SOI/EOI markers and the
/// >= 1024-byte length are checked.
Uint8List _fakeJpeg({int length = 2048}) {
  final bytes = Uint8List(length);
  bytes[0] = 0xFF;
  bytes[1] = 0xD8;
  bytes[length - 2] = 0xFF;
  bytes[length - 1] = 0xD9;
  return bytes;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('com.ican/on_device_vision');
  const vlmChannel = EventChannel('com.ican/gemma_stream');
  const fmChannel = EventChannel('com.ican/fm_stream');
  const downloadChannel = EventChannel('com.ican/model_download_progress');

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockStreamHandler(vlmChannel, null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockStreamHandler(fmChannel, null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockStreamHandler(downloadChannel, null);
  });

  test(
    'reports vision-only when all advanced offline artifacts are missing',
    () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            return switch (call.method) {
              'isFoundationModelsAvailable' => false,
              'getGemmaStatus' => 'not_available',
              'isObjectDetectionAvailable' => false,
              'isDepthEstimationAvailable' => false,
              'getNativeModelDiagnostics' => _diagnostics,
              _ => throw PlatformException(code: 'unexpected'),
            };
          });

      final status = await OnDeviceVisionService().getOfflineVisionStatus();

      expect(status.foundationModelsAvailable, isFalse);
      expect(status.modelStatus, ModelStatus.notAvailable);
      expect(status.objectDetectionAvailable, isFalse);
      expect(status.depthEstimationAvailable, isFalse);
      expect(status.bestLocalBackendLabel, 'Gemma local unavailable');
      expect(
        status.missingRequirements,
        containsAll(['Gemma runtime unavailable']),
      );
    },
  );

  test('rejects malformed JPEG before crossing native channel', () async {
    var methodCalls = 0;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          methodCalls++;
          throw PlatformException(
            code: 'SHOULD_NOT_REACH',
            message: 'pre-validator must gate this call',
          );
        });

    final service = OnDeviceVisionService();
    final truncated = Uint8List.fromList([0xFF, 0xD8, 0xFF, 0xD9]);

    await expectLater(
      service.analyzeWithVision(truncated),
      throwsA(
        isA<LocalVisionException>()
            .having((e) => e.code, 'code', 'Local L00')
            .having(
              (e) => e.message,
              'message',
              contains('corrupt or incomplete'),
            ),
      ),
    );
    await expectLater(
      service.analyzeScene(truncated),
      throwsA(
        isA<LocalVisionException>().having((e) => e.code, 'code', 'Local L00'),
      ),
    );
    await expectLater(
      service.analyzeLiveFrame(truncated),
      throwsA(
        isA<LocalVisionException>().having((e) => e.code, 'code', 'Local L00'),
      ),
    );
    await expectLater(
      service.describeWithGemma(truncated, systemPrompt: 'p').first,
      throwsA(
        isA<LocalVisionException>().having((e) => e.code, 'code', 'Local L00'),
      ),
    );

    expect(methodCalls, 0);
  });

  test('pings native channel and Apple Vision availability', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          return switch (call.method) {
            'ping' => true,
            'isAppleVisionAvailable' => true,
            _ => throw PlatformException(code: 'unexpected'),
          };
        });

    final service = OnDeviceVisionService();

    expect(await service.pingNativeChannel(), isTrue);
    expect(await service.isAppleVisionAvailable(), isTrue);
  });

  test('malformed native Vision map falls back instead of throwing', () {
    final analysis = VisionAnalysis.fromMap({
      'ocr_texts': 'EXIT',
      'scene_classification': 123,
      'scene_confidence': '0.42',
      'person_count': '2',
      'person_rects': [
        {'x': '0.1', 'y': 0.2, 'w': null, 'h': 'bad'},
        'bad rect',
      ],
    });

    expect(analysis.ocrTexts, ['EXIT']);
    expect(analysis.sceneClassification, '123');
    expect(analysis.sceneConfidence, 0.42);
    expect(analysis.personCount, 2);
    expect(analysis.personRects.single, containsPair('x', 0.1));
    expect(analysis.personRects.single, containsPair('y', 0.2));
  });

  test(
    'native Vision PlatformException becomes copyable local diagnostic',
    () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            if (call.method == 'analyzeWithVision') {
              throw PlatformException(
                code: 'VISION_CRASH',
                message: 'classification failed',
                details: {'stage': 'classification'},
              );
            }
            throw PlatformException(code: 'unexpected');
          });

      await expectLater(
        OnDeviceVisionService().analyzeWithVision(_fakeJpeg()),
        throwsA(
          isA<LocalVisionException>()
              .having((e) => e.code, 'code', 'Local L03')
              .having(
                (e) => e.userMessage,
                'userMessage',
                contains('VISION_CRASH'),
              )
              .having(
                (e) => e.userMessage,
                'userMessage',
                contains('classification'),
              ),
        ),
      );
    },
  );

  test(
    'reports spatial perception when object and depth models are present',
    () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            return switch (call.method) {
              'isFoundationModelsAvailable' => false,
              'getGemmaStatus' => 'not_downloaded',
              'isObjectDetectionAvailable' => true,
              'isDepthEstimationAvailable' => true,
              'getNativeModelDiagnostics' => _diagnostics,
              _ => throw PlatformException(code: 'unexpected'),
            };
          });

      final status = await OnDeviceVisionService().getOfflineVisionStatus();

      expect(status.bestLocalBackendLabel, 'Local live perception');
      expect(status.hasSpatialPerception, isTrue);
      expect(
        status.missingRequirements,
        contains('Gemma 4 E2B model not downloaded'),
      );
    },
  );

  test('reports loaded Gemma as the best local backend', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          return switch (call.method) {
            'isFoundationModelsAvailable' => true,
            'getGemmaStatus' => 'loaded',
            'isObjectDetectionAvailable' => true,
            'isDepthEstimationAvailable' => true,
            'getNativeModelDiagnostics' => _diagnostics,
            _ => throw PlatformException(code: 'unexpected'),
          };
        });

    final status = await OnDeviceVisionService().getOfflineVisionStatus();

    expect(status.bestLocalBackendLabel, 'Gemma 4 E2B');
    expect(status.modelStatus, ModelStatus.loaded);
    expect(status.missingRequirements, isEmpty);
  });

  test('live frame analysis uses the stable native live lane', () async {
    final methods = <String>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          methods.add(call.method);
          if (call.method == 'analyzeLiveFrame') {
            return {
              'ocr_texts': ['EXIT'],
              'scene_classification': 'hallway',
              'scene_confidence': 0.84,
              'person_count': 1,
              'person_rects': [],
            };
          }
          throw PlatformException(code: 'unexpected');
        });

    final result = await OnDeviceVisionService().analyzeLiveFrame(_fakeJpeg());

    expect(methods, ['analyzeLiveFrame']);
    expect(result.ocrTexts, ['EXIT']);
    expect(result.personCount, 1);
  });

  test('returns native model diagnostics', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          return switch (call.method) {
            'getNativeModelDiagnostics' => _diagnostics,
            _ => throw PlatformException(code: 'unexpected'),
          };
        });

    final diagnostics = await OnDeviceVisionService()
        .getOfflineVisionDiagnostics();

    expect(diagnostics.objectDetector.name, 'YOLOv3Tiny');
    expect(diagnostics.objectDetector.loaded, isFalse);
    expect(diagnostics.objectDetector.message, contains('not found'));
  });

  test('parses validated Gemma 4 E2B model info from native channel', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          return switch (call.method) {
            'getGemmaModelInfo' => _modelInfo,
            _ => throw PlatformException(code: 'unexpected'),
          };
        });

    final info = await OnDeviceVisionService().getGemmaModelInfo();

    expect(info.downloaded, isTrue);
    expect(info.valid, isTrue);
    expect(info.modelName, 'Gemma 4 E2B IT LiteRT-LM');
    expect(info.requiredBytes, 2583085056);
    expect(info.files.first.name, 'gemma-4-E2B-it.litertlm');
    expect(info.files.first.expectedSizeBytes, 2583085056);
    expect(
      info.files.first.sha256,
      'ab7838cdfc8f77e54d8ca45eadceb20452d9f01e4bfade03e5dce27911b27e42',
    );
    expect(info.files, hasLength(1));
    expect(info.files.first.downloaded, isTrue);
  });

  test(
    'model download subscribes to progress before invoking native download',
    () async {
      final order = <String>[];

      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockStreamHandler(
            downloadChannel,
            MockStreamHandler.inline(
              onListen: (_, events) {
                order.add('listen');
                Future<void>.microtask(() {
                  events.success({
                    'status': 'downloading',
                    'phase': 'downloading',
                    'progress': 0.5,
                    'filesDownloaded': 0,
                    'totalFiles': 1,
                    'requiredBytes': 2583085056,
                    'fileName': 'gemma-4-E2B-it.litertlm',
                  });
                  events.success({
                    'status': 'complete',
                    'phase': 'validated',
                    'progress': 1.0,
                    'filesDownloaded': 1,
                    'totalFiles': 1,
                    'requiredBytes': 2583085056,
                  });
                  events.endOfStream();
                });
              },
            ),
          );

      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            if (call.method == 'downloadGemmaModel') {
              order.add('invoke');
              return true;
            }
            throw PlatformException(code: 'unexpected');
          });

      final events = await OnDeviceVisionService()
          .startModelDownload()
          .toList();

      expect(order.take(2), ['listen', 'invoke']);
      expect(events.first.progress, 0.5);
      expect(events.last.isComplete, isTrue);
    },
  );

  test('VLM stream subscribes before invoking native inference', () async {
    final order = <String>[];

    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockStreamHandler(
          vlmChannel,
          MockStreamHandler.inline(
            onListen: (_, events) {
              order.add('listen');
              Future<void>.microtask(() {
                events.success('direct ');
                events.success('description');
                events.endOfStream();
              });
            },
          ),
        );

    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          if (call.method == 'describeImageWithGemma') {
            order.add('invoke');
            return true;
          }
          throw PlatformException(code: 'unexpected');
        });

    final chunks = await OnDeviceVisionService()
        .describeWithGemma(_fakeJpeg(), systemPrompt: 'Describe.')
        .toList();

    expect(order.take(2), ['listen', 'invoke']);
    expect(chunks.join(), 'direct description');
  });

  test('empty VLM stream reports a Local diagnostic', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockStreamHandler(
          vlmChannel,
          MockStreamHandler.inline(
            onListen: (_, events) {
              Future<void>.microtask(events.endOfStream);
            },
          ),
        );

    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          if (call.method == 'describeImageWithGemma') return true;
          throw PlatformException(code: 'unexpected');
        });

    await expectLater(
      OnDeviceVisionService()
          .describeWithGemma(_fakeJpeg(), systemPrompt: 'Describe.')
          .drain<void>(),
      throwsA(
        isA<LocalVisionException>()
            .having((e) => e.code, 'code', 'Local L20')
            .having((e) => e.message, 'message', contains('no output')),
      ),
    );
  });

  test('native stream errors become Local diagnostics', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockStreamHandler(
          vlmChannel,
          MockStreamHandler.inline(
            onListen: (_, events) {
              Future<void>.microtask(() {
                events.error(code: 'GEMMA_ERROR', message: 'Gemma unavailable');
                events.endOfStream();
              });
            },
          ),
        );

    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          if (call.method == 'describeImageWithGemma') return true;
          throw PlatformException(code: 'unexpected');
        });

    await expectLater(
      OnDeviceVisionService()
          .describeWithGemma(_fakeJpeg(), systemPrompt: 'Describe.')
          .drain<void>(),
      throwsA(
        isA<LocalVisionException>()
            .having((e) => e.code, 'code', 'Local L20')
            .having((e) => e.detail, 'detail', contains('GEMMA_ERROR')),
      ),
    );
  });

  test('returns copyable Gemma 4 E2B self-test diagnostics', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          return switch (call.method) {
            'runGemmaSelfTest' => {
              'runtimeLinked': true,
              'loadSuccess': true,
              'tokenCount': 4,
              'textModel': {'fileName': 'gemma-4-E2B-it.litertlm'},
            },
            _ => throw PlatformException(code: 'unexpected'),
          };
        });

    final result = await OnDeviceVisionService().runGemmaSelfTest(
      Uint8List.fromList([0xff, 0xd8, 0xff, 0xd9]),
    );

    expect(result['runtimeLinked'], isTrue);
    expect(result['tokenCount'], 4);
    expect(
      result['textModel'],
      containsPair('fileName', 'gemma-4-E2B-it.litertlm'),
    );
  });

  test(
    'readiness probe passes only when native runtime and output gates pass',
    () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            return switch (call.method) {
              'getGemmaReadinessContext' => _readinessContext,
              'runGemmaReadinessProbe' => _passingReadinessReport,
              _ => throw PlatformException(code: 'unexpected'),
            };
          });

      final report = await OnDeviceVisionService().runGemmaReadinessProbe(
        _fakeJpeg(),
      );

      expect(report.passed, isTrue);
      expect(report.runtimeLinked, isTrue);
      expect(report.shaVerified, isTrue);
      expect(report.sanitizedOutput, contains('clear path'));
    },
  );

  test('readiness probe fails closed on low memory', () {
    final report = GemmaReadinessReport.fromMap({
      ..._passingReadinessReport,
      'memoryBeforeBytes': 500000000,
    });

    expect(report.passed, isFalse);
    expect(report.failureReason, contains('1.1 GB'));
  });

  test('readiness probe fails closed on latency timeout', () {
    final report = GemmaReadinessReport.fromMap({
      ..._passingReadinessReport,
      'totalLatencyMs': 46000,
    });

    expect(report.passed, isFalse);
    expect(report.failureReason, contains('45 second'));
  });

  test('readiness probe fails closed on empty or repeated output', () {
    final empty = GemmaReadinessReport.fromMap({
      ..._passingReadinessReport,
      'tokenCount': 0,
      'sanitizedOutput': '',
    });
    final repeated = GemmaReadinessReport.fromMap({
      ..._passingReadinessReport,
      'sanitizedOutput':
          'clear path ahead now clear path ahead now clear path ahead now.',
    });

    expect(empty.passed, isFalse);
    expect(repeated.passed, isFalse);
  });

  test('readiness probe rejects malformed JPEG before native probe', () async {
    var calls = 0;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls++;
          if (call.method == 'getGemmaReadinessContext') {
            return _readinessContext;
          }
          throw PlatformException(code: 'SHOULD_NOT_REACH');
        });

    final report = await OnDeviceVisionService().runGemmaReadinessProbe(
      Uint8List.fromList([0xff, 0xd8, 0xff, 0xd9]),
    );

    expect(report.passed, isFalse);
    expect(report.failureReason, contains('corrupt'));
    expect(calls, 1);
  });

  test('readiness probe fails closed when native runtime is missing', () async {
    final report = await OnDeviceVisionService().runGemmaReadinessProbe(
      _fakeJpeg(),
    );

    expect(report.passed, isFalse);
    expect(report.runtimeLinked, isFalse);
    expect(report.failureReason, contains('not registered'));
  });

  test(
    'support snapshot redacts local paths and includes readiness fields',
    () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            return switch (call.method) {
              'getGemmaReadinessContext' => {
                ..._readinessContext,
                'modelsDirectory': '/Users/me/Documents/models',
              },
              'runGemmaReadinessProbe' => {
                ..._passingReadinessReport,
                'modelsDirectory': '/Users/me/Documents/models',
                'textModel': {'path': '/Users/me/Documents/models/text.gguf'},
              },
              _ => throw PlatformException(code: 'unexpected'),
            };
          });

      final service = OnDeviceVisionService();
      await service.runGemmaReadinessProbe(_fakeJpeg());
      final snapshot = await service.getGemmaReadinessSupportSnapshot();

      expect(snapshot, contains('"runtimeLinked": true'));
      expect(snapshot, contains('"passed": true'));
      expect(snapshot, isNot(contains('/Users/me')));
      expect(snapshot, contains('<redacted>'));
    },
  );

  group('hasUsefulSpokenOutput', () {
    // Relaxed from the earlier 8-word / terminal-punctuation requirements so
    // short Gemma 4 E2B probe outputs don't permanently disable the model.
    test('accepts 4-word outputs with punctuation', () {
      expect(
        GemmaReadinessReport.hasUsefulSpokenOutput('A dim room ahead.'),
        isTrue,
      );
    });

    test('accepts 4-word outputs without terminal punctuation', () {
      expect(
        GemmaReadinessReport.hasUsefulSpokenOutput('a hallway with two chairs'),
        isTrue,
      );
    });

    test('rejects outputs under the 4-word floor', () {
      expect(
        GemmaReadinessReport.hasUsefulSpokenOutput('A dim room.'),
        isFalse,
      );
    });

    test('still rejects banned meta tokens', () {
      expect(
        GemmaReadinessReport.hasUsefulSpokenOutput(
          'Gemma says hello world here',
        ),
        isFalse,
      );
      expect(
        GemmaReadinessReport.hasUsefulSpokenOutput(
          'as an ai i cannot really see this',
        ),
        isFalse,
      );
    });

    test('still rejects 4-word repetition loops', () {
      expect(
        GemmaReadinessReport.hasUsefulSpokenOutput(
          'the door is open the door is open',
        ),
        isFalse,
      );
    });
  });

  test('clearReadinessFailureCache empties the in-memory failure set', () {
    // Method is a no-throw side effect; smoke test that it runs without error.
    OnDeviceVisionService.clearReadinessFailureCache();
  });
}

const _diagnostics = {
  'object_detector': {
    'name': 'YOLOv3Tiny',
    'bundle_found': false,
    'compiled_model_found': false,
    'loaded': false,
    'message': 'YOLOv3Tiny was not found in the app bundle.',
  },
  'depth_estimator': {
    'name': 'DepthAnythingV2SmallF16P6',
    'bundle_found': false,
    'compiled_model_found': false,
    'loaded': false,
    'message': 'DepthAnythingV2SmallF16P6 was not found in the app bundle.',
  },
};

const _modelInfo = {
  'downloaded': true,
  'valid': true,
  'downloading': false,
  'sizeBytes': 2583085056,
  'requiredBytes': 2583085056,
  'path': '/Documents/models',
  'modelName': 'Gemma 4 E2B IT LiteRT-LM',
  'files': [
    {
      'name': 'gemma-4-E2B-it.litertlm',
      'downloaded': true,
      'sizeBytes': 2583085056,
      'expectedSizeBytes': 2583085056,
      'sha256':
          'ab7838cdfc8f77e54d8ca45eadceb20452d9f01e4bfade03e5dce27911b27e42',
    },
  ],
};

const _readinessContext = {
  'runtimeLinked': true,
  'appVersion': '1.0.0',
  'buildNumber': '29',
  'osVersion': 'iOS 26.4.1',
  'deviceModel': 'iPhone14,3',
  'files': [
    {
      'fileName': 'gemma-4-E2B-it.litertlm',
      'expectedSizeBytes': 2583085056,
      'sha256':
          'ab7838cdfc8f77e54d8ca45eadceb20452d9f01e4bfade03e5dce27911b27e42',
    },
  ],
};

const _passingReadinessReport = {
  'runtimeLinked': true,
  'filesPresent': true,
  'shaVerified': true,
  'loadSuccess': true,
  'memoryBeforeBytes': 1500000000,
  'memoryAfterLoadBytes': 500000000,
  'memoryAfterInferenceBytes': 450000000,
  'memoryWarningDuringProbe': false,
  'loadLatencyMs': 5000,
  'imageEvalLatencyMs': 4000,
  'firstTokenLatencyMs': 12000,
  'totalLatencyMs': 30000,
  'tokenCount': 16,
  'sanitizedOutput':
      'A hallway has a clear path ahead with an exit sign nearby.',
  'passed': true,
  'failureReason': '',
};
