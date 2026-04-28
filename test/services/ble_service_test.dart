import 'package:flutter_test/flutter_test.dart';
import 'package:ican/protocol/ble_protocol.dart';
import 'package:ican/services/app_log_service.dart';
import 'package:ican/services/ble_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

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
}
