import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:ican/protocol/ble_protocol.dart';
import 'package:ican/services/app_log_service.dart';
import 'package:ican/services/ble_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  tearDown(() {
    BleService.instance.resetEyeReliabilityForTesting();
    BleService.instance.setEyeConnectionStateForTesting(
      BleConnectionState.disconnected,
    );
  });

  test('Eye command write failure emits immediate E01 diagnostic', () async {
    SharedPreferences.setMockInitialValues({});
    AppLogService.instance.resetForTesting();
    await AppLogService.instance.init();

    final diagnosticFuture =
        BleService.instance.eyeCaptureDiagnosticStream.first;

    BleService.instance.emitEyeCommandWriteFailureForTesting(
      EyeCommands.capture,
      StateError('write failed'),
    );

    final diagnostic = await diagnosticFuture;
    expect(diagnostic.stableCode, 'Eye E01');
    expect(diagnostic.captureStarted, isFalse);
    expect(diagnostic.sizeArrived, isFalse);
    expect(diagnostic.spokenMessage, contains('no capture start or SIZE'));

    await Future<void>.delayed(Duration.zero);
    final logs = await AppLogService.instance.exportText();
    expect(logs, contains('Eye command CAPTURE write failed'));
    expect(logs, contains('Eye diagnostic Eye E01'));
  });

  test('STATUS control notification promotes command path readiness', () async {
    SharedPreferences.setMockInitialValues({});
    AppLogService.instance.resetForTesting();
    await AppLogService.instance.init();

    BleService.instance.updateEyeReadinessForTesting(
      BleReadinessPhase.verifyingCommandPath,
      requiredCharacteristicsReady: true,
      commandPathReady: false,
    );

    expect(BleService.instance.eyeReadinessStatus.ready, isFalse);
    expect(BleService.instance.eyeReadinessStatus.commandPathReady, isFalse);

    BleService.instance.handleEyeControlMessageForTesting(
      'STATUS:1:BALANCED:IDLE:1500:1.0.0+25',
    );

    expect(
      BleService.instance.eyeReadinessStatus.phase,
      BleReadinessPhase.ready,
    );
    expect(BleService.instance.eyeReadinessStatus.ready, isTrue);
    expect(
      BleService.instance.eyeReadinessStatus.requiredCharacteristicsReady,
      isTrue,
    );
    expect(BleService.instance.eyeReadinessStatus.commandPathReady, isTrue);

    await Future<void>.delayed(Duration.zero);
    final logs = await AppLogService.instance.exportText();
    expect(logs, contains('Eye control notification: STATUS:1:BALANCED'));
    expect(logs, contains('Eye STATUS round trip verified'));
    expect(
      logs,
      contains('keeping current camera profile until Describe or Live policy'),
    );
    expect(logs, isNot(contains('BALANCED describe')));
  });

  test('extended STATUS fields are parsed for hardware diagnostics', () async {
    SharedPreferences.setMockInitialValues({});

    BleService.instance.handleEyeControlMessageForTesting(
      'STATUS:0:FAST:IDLE:1500:1.0.0+26:8123456:247:240:none:OV3660:12345:890:52:5:61:44:boost_light_contrast',
    );

    final status = BleService.instance.lastEyeStatus!;
    expect(status.profileIndex, EyeProfileIndex.fast);
    expect(status.profileName, 'FAST');
    expect(status.freePsramBytes, 8123456);
    expect(status.negotiatedMtu, 247);
    expect(status.payloadCap, 240);
    expect(status.lastError, 'none');
    expect(status.cameraSensor, 'OV3660');
    expect(status.lastStreamBytes, 12345);
    expect(status.lastStreamMs, 890);
    expect(status.lastStreamChunks, 52);
    expect(status.qualityFlags, 5);
    expect(status.brightnessEstimate, 61);
    expect(status.contrastEstimate, 44);
    expect(status.tuneAction, 'boost_light_contrast');
    expect(status.hasDimFrame, isTrue);
    expect(status.hasLowContrastFrame, isTrue);
    expect(status.hasImageQualityIssue, isTrue);
    expect(status.qualityFlagLabel, 'dim,low_contrast');
  });

  test('CAPTURE retries once before emitting E01 when Eye is silent', () async {
    SharedPreferences.setMockInitialValues({});
    AppLogService.instance.resetForTesting();
    await AppLogService.instance.init();

    BleService.instance.beginEyeCaptureCommandForTesting();

    await BleService.instance.handleCaptureResponseTimeoutForTesting();

    await Future<void>.delayed(Duration.zero);
    var logs = await AppLogService.instance.exportText();
    expect(logs, contains('retrying once'));
    expect(logs, isNot(contains('retry also got no CAPTURE:START')));

    final diagnosticFuture =
        BleService.instance.eyeCaptureDiagnosticStream.first;

    await BleService.instance.handleCaptureResponseTimeoutForTesting();

    final diagnostic = await diagnosticFuture;
    expect(diagnostic.stableCode, 'Eye E01');
    expect(diagnostic.captureStarted, isFalse);
    expect(diagnostic.sizeArrived, isFalse);

    await Future<void>.delayed(Duration.zero);
    logs = await AppLogService.instance.exportText();
    expect(logs, contains('retry also got no CAPTURE:START or SIZE'));
    expect(logs, contains('Capture command response timeout.'));
  });

  test('logs tracked Eye control messages', () async {
    SharedPreferences.setMockInitialValues({});
    AppLogService.instance.resetForTesting();
    await AppLogService.instance.init();

    for (final message in <String>[
      EyeEvents.captureStart,
      'PROFILE_SET:1:BALANCED',
      'SIZE:123',
      'CRC:ABCDEF12',
      'END:2',
      'ERR:CAMERA_CAPTURE_FAILED',
    ]) {
      BleService.instance.handleEyeControlMessageForTesting(message);
    }

    await Future<void>.delayed(Duration.zero);
    final logs = await AppLogService.instance.exportText();
    expect(logs, contains('Eye control notification: CAPTURE:START'));
    expect(logs, contains('Eye control notification: PROFILE_SET:1:BALANCED'));
    expect(logs, contains('Eye control notification: SIZE:123'));
    expect(logs, contains('Eye control notification: CRC:ABCDEF12'));
    expect(logs, contains('Eye control notification: END:2'));
    expect(
      logs,
      contains('Eye control notification: ERR:CAMERA_CAPTURE_FAILED'),
    );
  });

  test(
    'PROFILE_SET updates current profile and completes matching ack',
    () async {
      SharedPreferences.setMockInitialValues({});
      AppLogService.instance.resetForTesting();
      await AppLogService.instance.init();
      BleService.instance.setEyeConnectionStateForTesting(
        BleConnectionState.connected,
      );
      BleService.instance.enableEyeCommandLoopbackForTesting(
        autoProfileAck: false,
      );

      final setFuture = BleService.instance.setEyeProfile(
        EyeProfileIndex.balanced,
        ackTimeout: const Duration(milliseconds: 100),
      );
      await Future<void>.delayed(Duration.zero);
      BleService.instance.handleEyeControlMessageForTesting(
        'PROFILE_SET:1:BALANCED',
      );
      await setFuture;

      expect(
        BleService.instance.currentEyeProfileIndex,
        EyeProfileIndex.balanced,
      );
      expect(BleService.instance.currentEyeProfileName, 'BALANCED');
      expect(BleService.instance.currentEyeProfileLabel, 'BALANCED(1)');
    },
  );

  test('setEyeProfile skips write when STATUS already matches', () async {
    SharedPreferences.setMockInitialValues({});
    AppLogService.instance.resetForTesting();
    await AppLogService.instance.init();
    BleService.instance.setEyeConnectionStateForTesting(
      BleConnectionState.connected,
    );
    BleService.instance.updateEyeReadinessForTesting(
      BleReadinessPhase.ready,
      requiredCharacteristicsReady: true,
      commandPathReady: true,
    );
    BleService.instance.enableEyeCommandLoopbackForTesting();
    BleService.instance.handleEyeControlMessageForTesting(
      'STATUS:1:BALANCED:IDLE:1500:1.0.0+26',
    );

    await BleService.instance.setEyeProfile(EyeProfileIndex.balanced);

    expect(
      BleService.instance.eyeCommandsSentForTesting,
      isNot(contains(EyeCommands.profile(EyeProfileIndex.balanced))),
    );
  });

  test('setEyeProfile times out when PROFILE_SET ack is missing', () async {
    SharedPreferences.setMockInitialValues({});
    AppLogService.instance.resetForTesting();
    await AppLogService.instance.init();
    BleService.instance.setEyeConnectionStateForTesting(
      BleConnectionState.connected,
    );
    BleService.instance.enableEyeCommandLoopbackForTesting(
      autoProfileAck: false,
    );

    await expectLater(
      BleService.instance.setEyeProfile(
        EyeProfileIndex.balanced,
        ackTimeout: const Duration(milliseconds: 1),
      ),
      throwsA(isA<TimeoutException>()),
    );
  });

  test('stream instability queues FAST profile fallback', () async {
    SharedPreferences.setMockInitialValues({});
    AppLogService.instance.resetForTesting();
    await AppLogService.instance.init();

    final diagnosticFuture =
        BleService.instance.eyeCaptureDiagnosticStream.first;

    BleService.instance.handleEyeControlMessageForTesting(
      'ERR:STREAM_ABORTED:3:720:1440',
    );

    final diagnostic = await diagnosticFuture;
    expect(diagnostic.stableCode, 'Eye E02');

    await Future<void>.delayed(Duration.zero);
    final logs = await AppLogService.instance.exportText();
    expect(logs, contains('Eye profile fallback queued: FAST. reason=Eye E02'));
  });

  test('Eye disconnect schedules one reconnect, not multiple', () async {
    SharedPreferences.setMockInitialValues({});
    AppLogService.instance.resetForTesting();
    await AppLogService.instance.init();

    BleService.instance.scheduleEyeReconnectForTesting('first disconnect');
    BleService.instance.scheduleEyeReconnectForTesting('duplicate disconnect');

    expect(BleService.instance.eyeReconnectPendingForTesting, isTrue);
    expect(BleService.instance.eyeReconnectAttemptForTesting, 1);

    await Future<void>.delayed(Duration.zero);
    final logs = await AppLogService.instance.exportText();
    expect(logs, contains('Eye reconnect scheduled attempt=1'));
    expect(logs, contains('Eye reconnect already scheduled'));
  });

  test(
    'sendEyeAbort while disconnected resets assembler and emits no diagnostic',
    () async {
      SharedPreferences.setMockInitialValues({});
      AppLogService.instance.resetForTesting();
      await AppLogService.instance.init();

      BleService.instance.setEyeConnectionStateForTesting(
        BleConnectionState.disconnected,
      );

      // Arm the assembler as if a capture were mid-flight.
      BleService.instance.beginEyeCaptureCommandForTesting();
      BleService.instance.handleEyeControlMessageForTesting(
        EyeEvents.captureStart,
      );
      BleService.instance.handleEyeControlMessageForTesting(
        '${EyeEvents.sizePrefix}1024',
      );

      var diagnosticCount = 0;
      final sub = BleService.instance.eyeCaptureDiagnosticStream.listen((_) {
        diagnosticCount++;
      });

      await BleService.instance.sendEyeAbort();
      await Future<void>.delayed(Duration.zero);

      // The abort path resets state silently — no diagnostic, no last-error
      // capture surfaced to the UI.
      expect(diagnosticCount, 0);
      expect(BleService.instance.lastEyeCaptureDiagnostic, isNull);

      await sub.cancel();
    },
  );

  test(
    'missed Eye heartbeat marks not ready and schedules reconnect',
    () async {
      SharedPreferences.setMockInitialValues({});
      AppLogService.instance.resetForTesting();
      await AppLogService.instance.init();

      BleService.instance.setEyeConnectionStateForTesting(
        BleConnectionState.connected,
      );
      BleService.instance.updateEyeReadinessForTesting(
        BleReadinessPhase.ready,
        requiredCharacteristicsReady: true,
        commandPathReady: true,
      );

      await BleService.instance.handleEyeHeartbeatTickForTesting();
      expect(BleService.instance.eyeReadinessStatus.ready, isTrue);
      expect(BleService.instance.missedEyeHeartbeatsForTesting, 1);

      await BleService.instance.handleEyeHeartbeatTickForTesting();

      expect(BleService.instance.eyeReadinessStatus.ready, isFalse);
      expect(BleService.instance.eyeReconnectPendingForTesting, isTrue);

      await Future<void>.delayed(Duration.zero);
      final logs = await AppLogService.instance.exportText();
      expect(
        logs,
        contains(
          'Eye profile fallback queued: FAST. reason=missed STATUS heartbeat',
        ),
      );
    },
  );
}
