import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ican/services/on_device_vision_service.dart';

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
  const vlmChannel = EventChannel('com.ican/vlm_stream');
  const fmChannel = EventChannel('com.ican/fm_stream');
  const downloadChannel = EventChannel('com.ican/model_download_progress');

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
              'getModelStatus' => 'not_available',
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
      expect(status.bestLocalBackendLabel, 'Local basic vision');
      expect(
        status.missingRequirements,
        containsAll([
          'Foundation Models unavailable',
          'SmolVLM2 unavailable',
          'YOLOv3Tiny model missing',
          'Depth Anything model missing',
        ]),
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
      service.describeWithVlm(truncated, systemPrompt: 'p').first,
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
              'getModelStatus' => 'not_downloaded',
              'isObjectDetectionAvailable' => true,
              'isDepthEstimationAvailable' => true,
              'getNativeModelDiagnostics' => _diagnostics,
              _ => throw PlatformException(code: 'unexpected'),
            };
          });

      final status = await OnDeviceVisionService().getOfflineVisionStatus();

      expect(status.bestLocalBackendLabel, 'Core ML spatial perception');
      expect(status.hasSpatialPerception, isTrue);
      expect(
        status.missingRequirements,
        contains('SmolVLM2 model not downloaded'),
      );
    },
  );

  test(
    'reports Foundation Models as the best local backend when available',
    () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            return switch (call.method) {
              'isFoundationModelsAvailable' => true,
              'getModelStatus' => 'loaded',
              'isObjectDetectionAvailable' => true,
              'isDepthEstimationAvailable' => true,
              'getNativeModelDiagnostics' => _diagnostics,
              _ => throw PlatformException(code: 'unexpected'),
            };
          });

      final status = await OnDeviceVisionService().getOfflineVisionStatus();

      expect(status.bestLocalBackendLabel, 'Foundation Models');
      expect(status.modelStatus, ModelStatus.loaded);
      expect(status.missingRequirements, isEmpty);
    },
  );

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

  test('parses validated SmolVLM2 model info from native channel', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          return switch (call.method) {
            'getModelInfo' => _modelInfo,
            _ => throw PlatformException(code: 'unexpected'),
          };
        });

    final info = await OnDeviceVisionService().getSmolVlmModelInfo();

    expect(info.downloaded, isTrue);
    expect(info.valid, isTrue);
    expect(info.modelName, 'SmolVLM2-500M-Video-Instruct Q8_0');
    expect(info.requiredBytes, 545592752);
    expect(info.files.first.name, 'SmolVLM2-500M-Video-Instruct-Q8_0.gguf');
    expect(info.files.first.expectedSizeBytes, 436807568);
    expect(
      info.files.first.sha256,
      '6f67b8036b2469fcd71728702720c6b51aebd759b78137a8120733b4d66438bc',
    );
    expect(info.files, hasLength(2));
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
                    'totalFiles': 2,
                    'requiredBytes': 545592752,
                    'fileName': 'SmolVLM2-500M-Video-Instruct-Q8_0.gguf',
                  });
                  events.success({
                    'status': 'complete',
                    'phase': 'validated',
                    'progress': 1.0,
                    'filesDownloaded': 2,
                    'totalFiles': 2,
                    'requiredBytes': 545592752,
                  });
                  events.endOfStream();
                });
              },
            ),
          );

      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            if (call.method == 'downloadModel') {
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
          if (call.method == 'describeImage') {
            order.add('invoke');
            return true;
          }
          throw PlatformException(code: 'unexpected');
        });

    final chunks = await OnDeviceVisionService()
        .describeWithVlm(_fakeJpeg(), systemPrompt: 'Describe.')
        .toList();

    expect(order.take(2), ['listen', 'invoke']);
    expect(chunks.join(), 'direct description');
  });

  test(
    'Foundation Models stream subscribes before invoking native synthesis',
    () async {
      final order = <String>[];

      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockStreamHandler(
            fmChannel,
            MockStreamHandler.inline(
              onListen: (_, events) {
                order.add('listen');
                Future<void>.microtask(() {
                  events.success('foundation description');
                  events.endOfStream();
                });
              },
            ),
          );

      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            if (call.method == 'synthesizeDescription') {
              order.add('invoke');
              return true;
            }
            throw PlatformException(code: 'unexpected');
          });

      final chunks = await OnDeviceVisionService()
          .synthesizeWithFoundationModels(
            'Layer 1 context',
            systemPrompt: 'Describe.',
          )
          .toList();

      expect(order.take(2), ['listen', 'invoke']);
      expect(chunks.single, 'foundation description');
    },
  );

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
          if (call.method == 'describeImage') return true;
          throw PlatformException(code: 'unexpected');
        });

    await expectLater(
      OnDeviceVisionService()
          .describeWithVlm(_fakeJpeg(), systemPrompt: 'Describe.')
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
          fmChannel,
          MockStreamHandler.inline(
            onListen: (_, events) {
              Future<void>.microtask(() {
                events.error(
                  code: 'FM_ERROR',
                  message: 'Foundation Models unavailable',
                );
                events.endOfStream();
              });
            },
          ),
        );

    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          if (call.method == 'synthesizeDescription') return true;
          throw PlatformException(code: 'unexpected');
        });

    await expectLater(
      OnDeviceVisionService()
          .synthesizeWithFoundationModels('context', systemPrompt: 'Describe.')
          .drain<void>(),
      throwsA(
        isA<LocalVisionException>()
            .having((e) => e.code, 'code', 'Local L30')
            .having((e) => e.detail, 'detail', contains('FM_ERROR')),
      ),
    );
  });

  test('returns copyable SmolVLM2 self-test diagnostics', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          return switch (call.method) {
            'runSmolVlmSelfTest' => {
              'llamaLinked': true,
              'loadSuccess': true,
              'tokenCount': 4,
              'textModel': {
                'fileName': 'SmolVLM2-500M-Video-Instruct-Q8_0.gguf',
              },
            },
            _ => throw PlatformException(code: 'unexpected'),
          };
        });

    final result = await OnDeviceVisionService().runSmolVlmSelfTest(
      Uint8List.fromList([0xff, 0xd8, 0xff, 0xd9]),
    );

    expect(result['llamaLinked'], isTrue);
    expect(result['tokenCount'], 4);
    expect(
      result['textModel'],
      containsPair('fileName', 'SmolVLM2-500M-Video-Instruct-Q8_0.gguf'),
    );
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
  'sizeBytes': 545592752,
  'requiredBytes': 545592752,
  'path': '/Documents/models',
  'modelName': 'SmolVLM2-500M-Video-Instruct Q8_0',
  'files': [
    {
      'name': 'SmolVLM2-500M-Video-Instruct-Q8_0.gguf',
      'downloaded': true,
      'sizeBytes': 436807568,
      'expectedSizeBytes': 436807568,
      'sha256':
          '6f67b8036b2469fcd71728702720c6b51aebd759b78137a8120733b4d66438bc',
    },
    {
      'name': 'mmproj-SmolVLM2-500M-Video-Instruct-Q8_0.gguf',
      'downloaded': true,
      'sizeBytes': 108785184,
      'expectedSizeBytes': 108785184,
      'sha256':
          '921dc7e259f308e5b027111fa185efcbf33db13f6e35749ddf7f5cdb60ef520b',
    },
  ],
};
