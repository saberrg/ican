import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:ican/services/stt_service.dart';
import 'package:ican/services/voice_command_service.dart';
import 'package:ican/services/voice_control_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('VoiceCommandService', () {
    late _FakeTts tts;
    late _FakeStt stt;
    late _FakeBle ble;
    late _FakeProcessor processor;
    late VoiceCommandService service;

    setUp(() {
      tts = _FakeTts();
      stt = _FakeStt();
      ble = _FakeBle();
      processor = _FakeProcessor();
      service = VoiceCommandService.custom(
        tts: tts,
        stt: stt,
        ble: ble,
        processor: processor,
      );
    });

    tearDown(() {
      service.dispose();
      stt.dispose();
      ble.dispose();
    });

    test('activates listening and processes a spoken command', () async {
      await service.activateVoiceCommand();

      expect(service.state, VoiceCommandState.listening);
      expect(stt.startCount, 1);
      expect(tts.spoken, contains('Listening.'));

      stt.emit('repeat last');
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);

      expect(service.partialText, 'repeat last');
      expect(processor.transcripts, ['repeat last']);
      expect(service.lastResult, 'Repeating the last description.');
      expect(tts.spoken, contains('Repeating the last description.'));
      expect(service.state, VoiceCommandState.idle);
    });

    test(
      'exposes partial transcript without processing until final result',
      () async {
        await service.activateVoiceCommand();

        stt.emitPartial('repeat');
        await Future<void>.delayed(Duration.zero);

        expect(service.partialText, 'repeat');
        expect(processor.transcripts, isEmpty);
        expect(service.state, VoiceCommandState.listening);
      },
    );

    test('truthfully reports no speech after listen window expires', () async {
      service.dispose();
      service = VoiceCommandService.custom(
        tts: tts,
        stt: stt,
        ble: ble,
        processor: processor,
        listenWindow: const Duration(milliseconds: 1),
        pauseWindow: const Duration(milliseconds: 1),
      );

      await service.activateVoiceCommand();
      await Future<void>.delayed(const Duration(milliseconds: 10));

      expect(stt.stopCount, 1);
      expect(service.state, VoiceCommandState.idle);
      expect(service.lastResult, "I didn't hear anything.");
      expect(
        tts.spoken,
        contains(
          "I didn't hear a command. Double press or tap Listen to try again.",
        ),
      );
    });

    test('records speech recognition errors', () async {
      await service.activateVoiceCommand();

      stt.emitError('network unavailable');
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);

      expect(service.lastError, 'network unavailable');
      expect(
        service.lastResult,
        'I had trouble hearing that. Double press to try again.',
      );
      expect(service.state, VoiceCommandState.idle);
    });

    test(
      'returns to idle when TTS fails during command confirmation',
      () async {
        tts.failOnSpeak = true;

        await service.activateVoiceCommand();
        stt.emit('repeat last');
        await Future<void>.delayed(Duration.zero);
        await Future<void>.delayed(Duration.zero);

        expect(service.lastError, contains('TTS failed'));
        expect(service.state, VoiceCommandState.idle);
      },
    );

    test('records microphone unavailable as the last result', () async {
      stt.available = false;
      stt.initResult = false;

      await service.activateVoiceCommand();

      expect(service.state, VoiceCommandState.idle);
      expect(service.lastResult, 'Microphone not available.');
      expect(stt.startCount, 0);
      expect(
        tts.spoken,
        contains('Microphone not available. Check permissions in settings.'),
      );
    });

    // Regression lock: per AGENTS.md "Eye Button Contract", DOUBLE is owned
    // by HomeViewModel (Cloud ↔ Local toggle). Voice must NOT listen to the
    // hardware button stream. Any future edit that re-wires this will fail.
    test('Eye hardware button events never activate voice command', () async {
      ble.emit('BUTTON:SINGLE');
      ble.emit('BUTTON:DOUBLE');
      ble.emit('BUTTON:LONG');
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);

      expect(
        service.state,
        VoiceCommandState.idle,
        reason: 'Voice must only activate via in-app Listen button, not BLE.',
      );
      expect(stt.startCount, 0);
    });
  });
}

class _FakeTts implements VoiceCommandTts {
  final List<String> spoken = [];
  var stopCount = 0;
  var failOnSpeak = false;

  @override
  Future<void> speak(String text) async {
    if (failOnSpeak) throw StateError('speaker unavailable');
    spoken.add(text);
  }

  @override
  Future<void> stop() async {
    stopCount++;
  }
}

class _FakeStt implements VoiceCommandStt {
  final _controller = StreamController<String>.broadcast();
  final _partialController = StreamController<String>.broadcast();
  final _errorController = StreamController<SttRecognitionError>.broadcast();
  @override
  var available = true;
  var initResult = true;
  var initCount = 0;
  var startCount = 0;
  var stopCount = 0;

  @override
  Stream<String> get resultStream => _controller.stream;

  @override
  Stream<String> get partialResultStream => _partialController.stream;

  @override
  Stream<SttRecognitionError> get errorStream => _errorController.stream;

  @override
  Future<bool> init() async {
    initCount++;
    available = initResult;
    return initResult;
  }

  @override
  Future<void> startListening({
    Duration listenFor = const Duration(seconds: 8),
    Duration pauseFor = const Duration(seconds: 3),
  }) async {
    startCount++;
  }

  @override
  Future<void> stopListening() async {
    stopCount++;
  }

  void emit(String text) {
    _controller.add(text);
  }

  void emitPartial(String text) {
    _partialController.add(text);
  }

  void emitError(String message, {bool permanent = false}) {
    _errorController.add(
      SttRecognitionError(message: message, permanent: permanent),
    );
  }

  void dispose() {
    _controller.close();
    _partialController.close();
    _errorController.close();
  }
}

class _FakeBle implements VoiceCommandBle {
  final _controller = StreamController<String>.broadcast();

  @override
  Stream<String> get buttonEventStream => _controller.stream;

  void emit(String event) {
    _controller.add(event);
  }

  void dispose() {
    _controller.close();
  }
}

class _FakeProcessor implements VoiceCommandProcessor {
  final List<String> transcripts = [];

  @override
  Future<VoiceActionResult> handleTranscript(String transcript) async {
    transcripts.add(transcript);
    return const VoiceActionResult(
      success: true,
      spokenConfirmation: 'Repeating the last description.',
    );
  }
}
