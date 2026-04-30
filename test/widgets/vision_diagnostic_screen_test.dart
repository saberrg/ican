import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ican/core/theme.dart';
import 'package:ican/screens/vision_diagnostic_screen.dart';
import 'package:ican/services/ble_service.dart';
import 'package:ican/services/on_device_vision_service.dart';
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
          }
          return null;
        });
  });

  tearDown(() {
    BleService.instance.resetEyeReliabilityForTesting();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null);
  });

  testWidgets('Vision Diagnostic reports local backend readiness', (
    tester,
  ) async {
    final onDevice = _FakeOnDeviceVisionService();
    BleService.instance.setLastEyeStatusForTesting(
      'STATUS:0:FAST:IDLE:1500:1.0.0+26:8123456:247:240:none:OV3660:12345:890:52:5:61:44:boost_light_contrast',
    );

    await tester.pumpWidget(
      _buildTestApp(VisionDiagnosticScreen(onDeviceService: onDevice)),
    );

    expect(find.text('Dev Diagnostics'), findsOneWidget);
    expect(find.text('Run Diagnostics'), findsOneWidget);

    await tester.tap(find.text('Run Diagnostics'));
    await tester.pumpAndSettle();

    expect(find.textContaining('Native channel: ready'), findsOneWidget);
    expect(find.textContaining('Camera sensor: OV3660'), findsOneWidget);
    expect(
      find.textContaining('Image quality: dim,low_contrast'),
      findsOneWidget,
    );
    expect(
      find.textContaining('Eye tune: boost_light_contrast'),
      findsOneWidget,
    );
    expect(find.textContaining('Apple Vision: ready'), findsOneWidget);
    expect(
      find.textContaining('Gemma 4 E2B status: downloaded'),
      findsOneWidget,
    );
    expect(
      find.textContaining('Gemma 4 E2B load: loaded successfully'),
      findsOneWidget,
    );
    expect(
      find.textContaining('Gemma 4 E2B readiness probe: failed'),
      findsOneWidget,
    );
    expect(
      find.textContaining('Gemma 4 E2B failure reason: Probe failed.'),
      findsOneWidget,
    );
    expect(find.textContaining('YOLOv3 Tiny: ready'), findsOneWidget);
    expect(find.textContaining('Depth Anything: unavailable'), findsOneWidget);

    await tester.tap(find.text('Copy Diagnostics'));
    await tester.pump();

    expect(clipboardText, contains('iCan Eye diagnostics'));
    expect(clipboardText, contains('Image quality: dim,low_contrast'));
    expect(clipboardText, contains('Gemma 4 E2B load: loaded successfully'));
    expect(clipboardText, contains('Gemma 4 E2B readiness probe: failed'));
    expect(
      clipboardText,
      contains('Gemma 4 E2B failure reason: Probe failed.'),
    );
    expect(clipboardText, contains('Gemma 4 E2B readiness snapshot'));
    expect(clipboardText, contains('"passed": false'));
    expect(clipboardText, contains('YOLOv3 Tiny: ready'));
  });

  testWidgets('Load Gemma button surfaces load failure', (tester) async {
    final onDevice = _FakeOnDeviceVisionService(loadResult: false);

    await tester.pumpWidget(
      _buildTestApp(VisionDiagnosticScreen(onDeviceService: onDevice)),
    );
    await tester.pumpAndSettle();

    await tester.ensureVisible(find.text('Load Gemma 4 E2B now'));
    await tester.pump();
    await tester.tap(find.text('Load Gemma 4 E2B now'));
    await tester.pumpAndSettle();

    expect(
      find.text('Gemma 4 E2B load failed. Run Diagnostics for details.'),
      findsOneWidget,
    );
  });

  testWidgets('picked phone photo is used for Gemma readiness probe', (
    tester,
  ) async {
    final onDevice = _FakeOnDeviceVisionService();
    final selectedPhotoBytes = Uint8List.fromList([
      0xff,
      0xd8,
      ...List<int>.filled(2044, 0x42),
      0xff,
      0xd9,
    ]);

    await tester.pumpWidget(
      _buildTestApp(
        VisionDiagnosticScreen(
          onDeviceService: onDevice,
          pickTestImageBytes: () async => selectedPhotoBytes,
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Pick Test Photo'));
    await tester.pumpAndSettle();

    expect(
      find.text('Selected phone photo (${selectedPhotoBytes.length} bytes).'),
      findsOneWidget,
    );

    await tester.tap(find.text('Run Diagnostics'));
    await tester.pumpAndSettle();

    expect(onDevice.lastProbeBytes, selectedPhotoBytes);
    expect(
      find.textContaining(
        'Gemma probe image: selected phone photo (${selectedPhotoBytes.length} bytes)',
      ),
      findsOneWidget,
    );
  });
}

Widget _buildTestApp(Widget child) {
  return ScreenUtilInit(
    designSize: const Size(375, 812),
    builder: (context, childWidget) =>
        MaterialApp(theme: ICanTheme.lightTheme, home: child),
  );
}

class _FakeOnDeviceVisionService extends OnDeviceVisionService {
  _FakeOnDeviceVisionService({this.loadResult = true});

  final bool loadResult;
  Uint8List? lastProbeBytes;

  @override
  Future<bool> pingNativeChannel() async => true;

  @override
  Future<bool> isAppleVisionAvailable() async => true;

  @override
  Future<ModelStatus> getModelStatus() async => ModelStatus.ready;

  @override
  Future<String> foundationModelsAvailabilityReason() async => 'unknown';

  @override
  Future<OfflineVisionStatus> getOfflineVisionStatus() async {
    return const OfflineVisionStatus(
      foundationModelsAvailable: false,
      modelStatus: ModelStatus.ready,
      objectDetectionAvailable: true,
      depthEstimationAvailable: false,
    );
  }

  @override
  Future<bool> loadGemmaModel() async => loadResult;

  @override
  Future<GemmaReadinessReport> runGemmaReadinessProbe(
    Uint8List jpegBytes, {
    String systemPrompt =
        'Describe this image for a blind user in 3 complete spoken sentences with hazards, layout, text, and path details.',
    Map<String, dynamic>? context,
    String? cacheKey,
  }) async {
    lastProbeBytes = jpegBytes;
    return GemmaReadinessReport.fromMap({
      'runtimeLinked': true,
      'filesPresent': true,
      'shaVerified': true,
      'loadSuccess': loadResult,
      'loadLatencyMs': 100,
      'imageEvalLatencyMs': 100,
      'firstTokenLatencyMs': 100,
      'totalLatencyMs': 300,
      'tokenCount': 0,
      'sanitizedOutput': '',
      'passed': false,
      'failureReason': 'Probe failed.',
    });
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
        bundleFound: false,
        compiledModelFound: false,
        loaded: false,
        message: 'DepthAnythingV2SmallF16P6 missing.',
      ),
    );
  }

  @override
  Future<String> getGemmaReadinessSupportSnapshot() async {
    return const JsonEncoder.withIndent('  ').convert({
      'readiness': {
        'runtimeLinked': true,
        'passed': false,
        'failureReason': 'No cached probe.',
      },
    });
  }
}
