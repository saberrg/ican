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
    },
  );
}
