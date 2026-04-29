import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ican/core/theme.dart';
import 'package:ican/screens/vision_diagnostic_screen.dart';
import 'package:ican/services/connectivity_service.dart';
import 'package:ican/services/on_device_vision_service.dart';
import 'package:ican/services/scene_description_service.dart';
import 'package:ican/services/vertex_ai_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  String? clipboardText;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    clipboardText = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
          if (call.method == 'Clipboard.setData') {
            final args = call.arguments as Map<dynamic, dynamic>;
            clipboardText = args['text']?.toString();
            return null;
          }
          return null;
        });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null);
  });

  testWidgets(
    'Vision Diagnostic shows SmolVLM2 setup and copies direct VLM timing',
    (tester) async {
      final onDevice = _FakeOnDeviceVisionService();
      final sceneService = SceneDescriptionService(
        cloudService: _FakeVertexAiService(),
        onDeviceService: onDevice,
        connectivityService: _FakeConnectivityService(),
      );

      await tester.pumpWidget(
        _buildTestApp(
          VisionDiagnosticScreen(
            onDeviceService: onDevice,
            sceneService: sceneService,
            initialImageBytes: _jpegBytes,
            initialImageSource: 'Fake image',
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('SmolVLM2 Setup'), findsOneWidget);
      expect(find.text('Run SmolVLM2 Self-Test'), findsOneWidget);
      expect(find.text('Run SmolVLM2 Direct'), findsOneWidget);
      expect(find.text('Run Full Local Pipeline'), findsOneWidget);
      expect(
        find.textContaining(
          RegExp(r'^SmolVLM2-500M-Video-Instruct-Q8_0\.gguf'),
        ),
        findsOneWidget,
      );

      await tester.ensureVisible(find.text('Run SmolVLM2 Direct'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Run SmolVLM2 Direct'));
      await tester.pumpAndSettle();

      expect(find.text('SmolVLM2 description.'), findsOneWidget);
      expect(find.text('Run SmolVLM2 Direct'), findsWidgets);

      await tester.ensureVisible(find.text('Copy Result'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Copy Result'));
      await tester.pump();

      expect(clipboardText, contains('Diagnostic: Run SmolVLM2 Direct'));
      expect(clipboardText, contains('Image: Fake image'));
      expect(clipboardText, contains('Time to first token:'));
      expect(clipboardText, contains('Total time:'));
      expect(clipboardText, contains('SmolVLM2 description.'));
    },
  );

  testWidgets('Vision Diagnostic vision-only run shows copyable native error', (
    tester,
  ) async {
    final onDevice = _FakeOnDeviceVisionService()
      ..visionOnlyError = const LocalVisionException(
        'Local L03',
        'Apple Vision or Core ML failed.',
        detail: 'VISION_CRASH: classification failed',
      );
    final sceneService = SceneDescriptionService(
      cloudService: _FakeVertexAiService(),
      onDeviceService: onDevice,
      connectivityService: _FakeConnectivityService(),
    );

    await tester.pumpWidget(
      _buildTestApp(
        VisionDiagnosticScreen(
          onDeviceService: onDevice,
          sceneService: sceneService,
          initialImageBytes: _jpegBytes,
          initialImageSource: 'Fake image',
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.ensureVisible(find.text('Cloud Gemini'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cloud Gemini'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Vision-only template').last);
    await tester.pumpAndSettle();

    await tester.ensureVisible(find.text('Run Description'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Run Description'));
    await tester.pumpAndSettle();

    expect(find.textContaining('Local L03'), findsOneWidget);
    expect(find.text('Copy Result'), findsOneWidget);

    await tester.tap(find.text('Copy Result'));
    await tester.pump();

    expect(clipboardText, contains('Diagnostic: Vision-only template'));
    expect(clipboardText, contains('Error:'));
    expect(clipboardText, contains('VISION_CRASH'));
    expect(clipboardText, contains('classification failed'));
  });
}

Widget _buildTestApp(Widget child) {
  return ScreenUtilInit(
    designSize: const Size(375, 812),
    builder: (context, childWidget) =>
        MaterialApp(theme: ICanTheme.lightTheme, home: child),
  );
}

final _jpegBytes = Uint8List.fromList([
  0x89,
  0x50,
  0x4e,
  0x47,
  0x0d,
  0x0a,
  0x1a,
  0x0a,
  0x00,
  0x00,
  0x00,
  0x0d,
  0x49,
  0x48,
  0x44,
  0x52,
  0x00,
  0x00,
  0x00,
  0x01,
  0x00,
  0x00,
  0x00,
  0x01,
  0x08,
  0x06,
  0x00,
  0x00,
  0x00,
  0x1f,
  0x15,
  0xc4,
  0x89,
  0x00,
  0x00,
  0x00,
  0x0a,
  0x49,
  0x44,
  0x41,
  0x54,
  0x78,
  0x9c,
  0x63,
  0x00,
  0x01,
  0x00,
  0x00,
  0x05,
  0x00,
  0x01,
  0x0d,
  0x0a,
  0x2d,
  0xb4,
  0x00,
  0x00,
  0x00,
  0x00,
  0x49,
  0x45,
  0x4e,
  0x44,
  0xae,
  0x42,
  0x60,
  0x82,
]);

class _FakeOnDeviceVisionService extends OnDeviceVisionService {
  LocalVisionException? visionOnlyError;

  @override
  Future<ModelStatus> getModelStatus() async => ModelStatus.loaded;

  @override
  Future<SmolVlmModelInfo> getSmolVlmModelInfo() async {
    return const SmolVlmModelInfo(
      downloaded: true,
      valid: true,
      downloading: false,
      sizeBytes: 545592752,
      requiredBytes: 545592752,
      path: '/Documents/models',
      modelName: 'SmolVLM2-500M-Video-Instruct Q8_0',
      files: [
        ModelFileDownloadInfo(
          name: 'SmolVLM2-500M-Video-Instruct-Q8_0.gguf',
          downloaded: true,
          sizeBytes: 436807568,
          expectedSizeBytes: 436807568,
          sha256:
              '6f67b8036b2469fcd71728702720c6b51aebd759b78137a8120733b4d66438bc',
        ),
        ModelFileDownloadInfo(
          name: 'mmproj-SmolVLM2-500M-Video-Instruct-Q8_0.gguf',
          downloaded: true,
          sizeBytes: 108785184,
          expectedSizeBytes: 108785184,
          sha256:
              '921dc7e259f308e5b027111fa185efcbf33db13f6e35749ddf7f5cdb60ef520b',
        ),
      ],
    );
  }

  @override
  Future<OfflineVisionStatus> getOfflineVisionStatus() async {
    return const OfflineVisionStatus(
      foundationModelsAvailable: false,
      modelStatus: ModelStatus.loaded,
      objectDetectionAvailable: true,
      depthEstimationAvailable: true,
    );
  }

  @override
  Future<OfflineVisionDiagnostics> getOfflineVisionDiagnostics() async {
    return const OfflineVisionDiagnostics(
      objectDetector: NativeModelDiagnostic(
        name: 'YOLOv3Tiny',
        bundleFound: true,
        compiledModelFound: true,
        loaded: true,
        message: 'YOLOv3Tiny loaded.',
      ),
      depthEstimator: NativeModelDiagnostic(
        name: 'DepthAnythingV2SmallF16P6',
        bundleFound: true,
        compiledModelFound: true,
        loaded: true,
        message: 'DepthAnythingV2SmallF16P6 loaded.',
      ),
    );
  }

  @override
  Future<bool> loadVlmModel() async => true;

  @override
  Future<ScenePerceptionResult> analyzeScene(Uint8List jpegBytes) async {
    return const ScenePerceptionResult(
      ocrTexts: ['EXIT'],
      sceneClassification: 'hallway',
      sceneConfidence: 0.91,
      personCount: 0,
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
    final error = visionOnlyError;
    if (error != null) throw error;
    return const VisionAnalysis(
      ocrTexts: ['EXIT'],
      sceneClassification: 'hallway',
      sceneConfidence: 0.91,
      personCount: 1,
      personRects: [],
    );
  }

  @override
  Stream<String> describeWithVlm(
    Uint8List jpegBytes, {
    required String systemPrompt,
    String? visionContext,
  }) async* {
    yield 'SmolVLM2 description.';
  }

  @override
  Future<Map<String, dynamic>> runSmolVlmSelfTest(
    Uint8List jpegBytes, {
    String systemPrompt =
        'Describe this image in one concise sentence for a blind user.',
  }) async {
    return {
      'llamaLinked': true,
      'loadSuccess': true,
      'firstTokenLatencyMs': 12,
      'totalLatencyMs': 34,
      'outputPreview': 'SmolVLM2 description.',
    };
  }
}

class _FakeVertexAiService extends VertexAiService {
  @override
  Stream<String> streamContentFromImage(
    Uint8List imageBytes, {
    required String systemPrompt,
    String userPrompt = 'Describe what you see.',
    int maxOutputTokens = 500,
  }) async* {
    yield 'Cloud description.';
  }
}

class _FakeConnectivityService extends ConnectivityService {
  @override
  Future<bool> hasInternet() async => false;
}
