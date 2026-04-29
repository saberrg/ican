import 'package:flutter_test/flutter_test.dart';
import 'package:ican/main.dart' as app;
import 'package:ican/models/settings_provider.dart';
import 'package:ican/screens/splash_screen.dart';
import 'package:ican/services/stt_service.dart';
import 'package:ican/services/tts_service.dart';
import 'package:ican/services/voice_command_service.dart';
import 'package:ican/services/voice_control_service.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:integration_test/integration_test.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    SplashScreen.disableBleAutoConnectForTesting = true;
    final settings = SettingsProvider(ttsService: _FakeTtsSettings());
    final voiceCommands = VoiceCommandService.custom(
      tts: _FakeVoiceTts(),
      stt: _FakeVoiceStt(),
      ble: _FakeVoiceBle(),
      processor: _NoopVoiceProcessor(),
    );
    app.configureAppForTesting(
      voiceCommands: voiceCommands,
      settings: settings,
    );
  });

  testWidgets('demo startup lands on Home and hides unfinished paths', (
    tester,
  ) async {
    await tester.pumpWidget(const app.ICanApp());

    await tester.pump(const Duration(seconds: 4));
    await tester.pump();

    expect(find.text('iCan Eye'), findsWidgets);
    expect(find.text('Cloud Describe'), findsOneWidget);
    expect(find.text('Offline Describe'), findsOneWidget);
    expect(find.text('Start Live Detection'), findsOneWidget);

    expect(find.textContaining('Role Selection'), findsNothing);
    expect(find.textContaining('Caretaker'), findsNothing);
  });
}

class _FakeTtsSettings implements TtsSettingsController {
  double _rate = 0.5;
  double _pitch = 1.0;
  double _volume = 1.0;

  @override
  double get rate => _rate;

  @override
  double get pitch => _pitch;

  @override
  String? get selectedVoiceId => null;

  @override
  void setRate(double rate) {
    _rate = rate;
  }

  @override
  void setPitch(double pitch) {
    _pitch = pitch;
  }

  @override
  void setVolume(double vol) {
    _volume = vol;
  }

  @override
  Future<List<TtsVoiceOption>> availableVoices() async => const [];

  @override
  Future<void> previewVoice([String sample = '']) async {}

  @override
  Future<void> setVoice(TtsVoiceOption voice) async {}

  @override
  Future<void> speak(String text) async {}

  @override
  Future<void> stop() async {}

  // Kept observable for debugger inspection during real-device runs.
  double get volume => _volume;
}

class _FakeVoiceTts implements VoiceCommandTts {
  @override
  Future<void> speak(String text) async {}

  @override
  Future<void> stop() async {}
}

class _FakeVoiceStt implements VoiceCommandStt {
  @override
  bool get available => true;

  @override
  Stream<SttRecognitionError> get errorStream =>
      const Stream<SttRecognitionError>.empty();

  @override
  Stream<String> get partialResultStream => const Stream<String>.empty();

  @override
  Stream<String> get resultStream => const Stream<String>.empty();

  @override
  Future<bool> init() async => true;

  @override
  Future<void> startListening({
    Duration listenFor = const Duration(seconds: 8),
    Duration pauseFor = const Duration(seconds: 3),
  }) async {}

  @override
  Future<void> stopListening() async {}
}

class _FakeVoiceBle implements VoiceCommandBle {
  @override
  Stream<String> get buttonEventStream => const Stream<String>.empty();
}

class _NoopVoiceProcessor implements VoiceCommandProcessor {
  @override
  Future<VoiceActionResult> handleTranscript(String transcript) async {
    return const VoiceActionResult(
      success: true,
      spokenConfirmation: 'Handled.',
    );
  }
}
