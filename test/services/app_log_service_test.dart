import 'package:flutter_test/flutter_test.dart';
import 'package:ican/services/app_log_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('app log service redacts key material before persistence', () async {
    SharedPreferences.setMockInitialValues({});
    AppLogService.instance.resetForTesting();
    await AppLogService.instance.init();
    final queryKey = 'abcde' * 6;
    final googleKey =
        'AI'
        'za${'abcde' * 6}';

    await AppLogService.instance.record(
      'API_KEY=secret-value x-goog-api-key: another-secret '
      'https://example.test?key=$queryKey '
      '$googleKey',
      source: 'test',
    );

    final export = await AppLogService.instance.exportText();

    expect(export, contains('API_KEY=<redacted>'));
    expect(export, contains('x-goog-api-key: <redacted>'));
    expect(export, contains('key=<redacted>'));
    expect(export, contains('AIza<redacted>'));
    expect(export, isNot(contains('secret-value')));
    expect(export, isNot(contains('another-secret')));
    expect(export, isNot(contains(queryKey)));
    expect(export, isNot(contains(googleKey)));
  });
}
