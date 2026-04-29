import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:go_router/go_router.dart';
import '../core/route_constants.dart';
import '../services/ble_service.dart';
import '../services/device_prefs_service.dart';

class SplashScreen extends StatefulWidget {
  const SplashScreen({super.key});

  @visibleForTesting
  static bool disableBleAutoConnectForTesting = false;

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen>
    with TickerProviderStateMixin {
  late AnimationController _logoController;
  late Animation<double> _logoScale;
  late Animation<double> _logoOpacity;

  late AnimationController _textController;
  late Animation<double> _textOpacity;

  late AnimationController _subtitleController;
  late Animation<double> _subtitleOpacity;

  @override
  void initState() {
    super.initState();

    _logoController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    );
    _logoScale = Tween<double>(begin: 0.6, end: 1.0).animate(
      CurvedAnimation(parent: _logoController, curve: Curves.easeOutBack),
    );
    _logoOpacity = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(
        parent: _logoController,
        curve: const Interval(0.0, 0.6, curve: Curves.easeIn),
      ),
    );

    _textController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 800),
    );
    _textOpacity = Tween<double>(
      begin: 0.0,
      end: 1.0,
    ).animate(CurvedAnimation(parent: _textController, curve: Curves.easeIn));

    _subtitleController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 600),
    );
    _subtitleOpacity = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(parent: _subtitleController, curve: Curves.easeIn),
    );

    _runSequence();
  }

  Future<void> _runSequence() async {
    // Staggered animation: logo → title → subtitle
    _logoController.forward();
    await Future.delayed(const Duration(milliseconds: 600));
    _textController.forward();
    await Future.delayed(const Duration(milliseconds: 400));
    _subtitleController.forward();

    // BLE auto-connect in background (fire-and-forget)
    if (!SplashScreen.disableBleAutoConnectForTesting) {
      _startBleAutoConnect();
    }

    // Minimum display time for the splash
    await Future.delayed(const Duration(milliseconds: 1500));

    if (!mounted) return;

    // Route based on saved role. First launch has no role → Role Selection.
    final role = await DevicePrefsService.instance.getUserRole();
    if (!mounted) return;
    switch (role) {
      case 'caretaker':
        context.goNamed(Routes.caretakerDashboardName);
      case 'user':
        context.goNamed(Routes.homeName);
      default:
        context.goNamed(Routes.roleSelectionName);
    }
  }

  void _startBleAutoConnect() async {
    try {
      // Wait for the iOS CoreBluetooth stack to power on before attempting
      // to connect. Calling connectToEyeByMac before the adapter is ready
      // causes startScan() to fail silently with no retry scheduled.
      await FlutterBluePlus.adapterState
          .where((s) => s == BluetoothAdapterState.on)
          .first
          .timeout(const Duration(seconds: 8));
    } catch (_) {
      // Adapter didn't come up in time (e.g. BT disabled) — proceed anyway
      // so the rest of the app still launches.
    }
    try {
      final savedEyeMac =
          await DevicePrefsService.instance.getLastDeviceId() ??
          BleService.fallbackEyeDeviceId;
      BleService.instance.connectToEyeByMac(savedEyeMac);
    } catch (e) {
      debugPrint('[Splash] BLE auto-connect error: $e');
    }
  }

  @override
  void dispose() {
    _logoController.dispose();
    _textController.dispose();
    _subtitleController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    return Scaffold(
      backgroundColor: theme.scaffoldBackgroundColor,
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            // App icon with scale + fade
            AnimatedBuilder(
              animation: _logoController,
              builder: (context, child) {
                return Transform.scale(
                  scale: _logoScale.value,
                  child: Opacity(opacity: _logoOpacity.value, child: child),
                );
              },
              child: ClipRRect(
                borderRadius: BorderRadius.circular(32),
                child: Image.asset(
                  'assets/ican-app-icon.png',
                  width: 140,
                  height: 140,
                ),
              ),
            ),
            const SizedBox(height: 28),

            // "iCan" title
            AnimatedBuilder(
              animation: _textController,
              builder: (context, child) {
                return Opacity(opacity: _textOpacity.value, child: child);
              },
              child: Text(
                'iCan',
                style: TextStyle(
                  fontSize: 42,
                  fontWeight: FontWeight.bold,
                  color: theme.colorScheme.primary,
                  letterSpacing: 2.0,
                ),
              ),
            ),
            const SizedBox(height: 12),

            // Subtitle
            AnimatedBuilder(
              animation: _subtitleController,
              builder: (context, child) {
                return Opacity(opacity: _subtitleOpacity.value, child: child);
              },
              child: Text(
                'See the world, your way',
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w400,
                  color: isDark ? Colors.white70 : Colors.black54,
                  letterSpacing: 0.5,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
