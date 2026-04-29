import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ican/core/theme.dart';
import 'package:ican/screens/vision_diagnostic_screen.dart';
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
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null);
  });

  testWidgets('Vision Diagnostic reports BLE and native health only', (
    tester,
  ) async {
    final onDevice = _FakeOnDeviceVisionService();

    await tester.pumpWidget(
      _buildTestApp(VisionDiagnosticScreen(onDeviceService: onDevice)),
    );

    expect(find.text('Dev Diagnostics'), findsOneWidget);
    expect(find.text('Run Diagnostics'), findsOneWidget);
    expect(find.textContaining('SmolVLM2'), findsNothing);

    await tester.tap(find.text('Run Diagnostics'));
    await tester.pumpAndSettle();

    expect(find.textContaining('Native channel: ready'), findsOneWidget);
    expect(find.textContaining('Apple Vision: ready'), findsOneWidget);
    expect(find.textContaining('YOLOv3 Tiny: ready'), findsOneWidget);
    expect(find.textContaining('Depth Anything: unavailable'), findsOneWidget);
    expect(find.textContaining('SmolVLM2'), findsNothing);

    await tester.tap(find.text('Copy Diagnostics'));
    await tester.pump();

    expect(clipboardText, contains('iCan Eye diagnostics'));
    expect(clipboardText, contains('YOLOv3 Tiny: ready'));
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
  @override
  Future<bool> pingNativeChannel() async => true;

  @override
  Future<bool> isAppleVisionAvailable() async => true;

  @override
  Future<OfflineVisionStatus> getOfflineVisionStatus() async {
    return const OfflineVisionStatus(
      foundationModelsAvailable: false,
      modelStatus: ModelStatus.notAvailable,
      objectDetectionAvailable: true,
      depthEstimationAvailable: false,
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
        bundleFound: false,
        compiledModelFound: false,
        loaded: false,
        message: 'DepthAnythingV2SmallF16P6 missing.',
      ),
    );
  }
}
