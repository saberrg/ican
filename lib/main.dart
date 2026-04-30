import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:provider/provider.dart';

import 'core/router.dart';
import 'core/theme.dart';
import 'models/settings_provider.dart';
import 'services/app_log_service.dart';
import 'services/ble_service.dart';
import 'services/notification_service.dart';
import 'services/stt_service.dart';
import 'services/tts_service.dart';
import 'services/voice_command_service.dart';

late VoiceCommandService voiceCommandService;
late SettingsProvider appSettingsProvider;

@visibleForTesting
void configureAppForTesting({
  required VoiceCommandService voiceCommands,
  required SettingsProvider settings,
}) {
  voiceCommandService = voiceCommands;
  appSettingsProvider = settings;
}

Future<void> main() async {
  await runZonedGuarded<Future<void>>(
    () async {
      WidgetsFlutterBinding.ensureInitialized();
      await AppLogService.instance.init();
      AppLogService.instance.installDebugPrintHook();
      await AppLogService.instance.record('App startup begin', source: 'main');

      if (const String.fromEnvironment('API_KEY').isEmpty) {
        await AppLogService.instance.record(
          'API_KEY not set at build time',
          source: 'main',
        );
      }

      FlutterError.onError = (details) {
        debugPrint('[FlutterError] ${details.exceptionAsString()}');
        unawaited(
          AppLogService.instance.record(
            '[FlutterError] ${details.exceptionAsString()}',
            source: 'flutter',
          ),
        );
        FlutterError.presentError(details);
      };

      try {
        await NotificationService.init();
      } catch (e) {
        debugPrint('[main] NotificationService.init() failed: $e');
      }

      try {
        await TtsService.instance.init();
      } on PlatformException catch (e) {
        debugPrint(
          '[main] TtsService.init() platform failure: ${e.code} ${e.message}',
        );
      } catch (e) {
        debugPrint('[main] TtsService.init() failed: $e');
      }

      try {
        await SttService.instance.init();
      } catch (e) {
        debugPrint('[main] SttService.init() failed: $e');
      }

      appSettingsProvider = SettingsProvider(ttsService: TtsService.instance);

      voiceCommandService = VoiceCommandService(
        tts: TtsService.instance,
        stt: SttService.instance,
        ble: BleService.instance,
      );
      voiceCommandService.attachSettings(appSettingsProvider);

      runApp(const ICanApp());
      debugPrint('[main] App startup complete');
    },
    (error, stackTrace) {
      debugPrint('[ZoneError] $error');
      unawaited(
        AppLogService.instance.record('[ZoneError] $error', source: 'zone'),
      );
      debugPrintStack(stackTrace: stackTrace);
    },
  );
}

class ICanApp extends StatelessWidget {
  const ICanApp({super.key});

  static final _router = buildRouter();

  @override
  Widget build(BuildContext context) {
    return ScreenUtilInit(
      designSize: const Size(375, 812),
      minTextAdapt: true,
      // Expose the app-wide SettingsProvider above the router so every route
      // (Home, Settings, Live Detection) can read/write it without each route
      // having to re-scope its own provider.
      builder: (context, child) =>
          ChangeNotifierProvider<SettingsProvider>.value(
            value: appSettingsProvider,
            child: MaterialApp.router(
              title: 'iCan',
              debugShowCheckedModeBanner: false,
              theme: ICanTheme.lightTheme,
              darkTheme: ICanTheme.darkTheme,
              themeMode: ThemeMode.system,
              routerConfig: _router,
            ),
          ),
    );
  }
}
