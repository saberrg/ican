import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ican/core/theme.dart';
import 'package:ican/models/home_view_model.dart';
import 'package:ican/models/settings_provider.dart';
import 'package:ican/protocol/eye_capture_diagnostics.dart';
import 'package:ican/screens/accessible_home_screen.dart';
import 'package:ican/services/on_device_vision_service.dart';
import 'package:ican/services/scene_description_service.dart';
import 'package:ican/services/tts_service.dart';
import 'package:ican/services/vertex_ai_service.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('Home shows only the three demo flow actions', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final vm = _buildHomeViewModel(_FakeTts());

    await tester.pumpWidget(_wrap(vm));

    expect(find.text('Cloud Describe'), findsOneWidget);
    expect(find.text('Offline Describe'), findsOneWidget);
    expect(find.text('Start Live Detection'), findsOneWidget);
    expect(find.text('Start Voice Command'), findsNothing);
    expect(find.textContaining('Settings'), findsNothing);
    expect(find.textContaining('iCan Cane'), findsNothing);

    vm.dispose();
  });

  testWidgets('Home shows the latest vision diagnostic as visible text', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final tts = _FakeTts();
    final vm = _buildHomeViewModel(tts);

    vm.startCaptureTimeoutForTesting();
    await vm.handleEyeCaptureDiagnosticForTesting(
      const EyeCaptureDiagnostic(
        code: EyeCaptureDiagnosticCode.streamStalled,
        captureStarted: true,
        sizeArrived: true,
        expectedBytes: 1024,
        receivedBytes: 512,
        uniqueChunks: 4,
        duplicateChunks: 1,
        endArrived: false,
        jpegMagicValid: true,
        jpegEndValid: false,
        timeoutStage: EyeTransferTimeoutStage.awaitingEnd,
      ),
    );

    await tester.pumpWidget(_wrap(vm));

    expect(find.textContaining('Eye E02'), findsOneWidget);
    expect(find.textContaining('512/1024 bytes'), findsOneWidget);

    vm.dispose();
  });
}

HomeViewModel _buildHomeViewModel(TtsSettingsController tts) {
  final settings = SettingsProvider(ttsService: tts);
  return HomeViewModel(
    sceneService: SceneDescriptionService(
      cloudService: VertexAiService(apiKey: 'test-key'),
      onDeviceService: OnDeviceVisionService(),
    ),
    ttsService: tts,
    settingsProvider: settings,
  );
}

Widget _wrap(HomeViewModel vm) {
  return ScreenUtilInit(
    designSize: const Size(375, 812),
    builder: (context, child) => ChangeNotifierProvider<HomeViewModel>.value(
      value: vm,
      child: MaterialApp(
        theme: ICanTheme.lightTheme,
        home: const AccessibleHomeScreen(),
      ),
    ),
  );
}

class _FakeTts implements TtsSettingsController {
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
