import 'package:flutter/widgets.dart';

class Routes {
  Routes._();

  // Path segments
  static const String home = '/';
  static const String settings = '/settings';
  static const String help = '/help';
  static const String devicePairing = '/device-pairing';
  static const String roleSelection = '/dev/role-selection';
  static const String caretakerDashboard = '/dev/caretaker-dashboard';

  // Named routes — used by GoRouter name: parameter and context.goNamed()
  static const String homeName = 'home';
  static const String settingsName = 'settings';
  static const String helpName = 'help';
  static const String devicePairingName = 'device-pairing';
  static const String roleSelectionName = 'role-selection';
  static const String caretakerDashboardName = 'caretaker-dashboard';
  static const String notFoundName = 'not-found';

  // Tab index lookup — keeps bottom nav logic in one place
  static const Map<String, int> tabIndex = {
    homeName: 0,
    settingsName: 1,
    helpName: 2,
  };

  // Screen titles announced via SemanticsService on every route change
  static const Map<String, String> screenTitles = {
    homeName: 'Home',
    settingsName: 'Settings',
    helpName: 'Help',
    devicePairingName: 'Device Pairing',
    'nav': 'Navigation',
    'gps': 'GPS',
    'live-detection': 'Live Detection',
    'vision-diagnostic': 'Vision Diagnostic',
    'splash': 'Loading',
    'role-selection': 'Role Selection',
    'caretaker-dashboard': 'Caretaker Dashboard',
    'connection-error': 'Connection Error',
    notFoundName: 'Page Not Found',
  };

  static String titleFor(String? name) =>
      screenTitles[name] ?? 'Unknown screen';

  static final navigatorKey = GlobalKey<NavigatorState>();
}
