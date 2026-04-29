import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:provider/provider.dart';

import '../core/theme.dart';
import '../models/home_view_model.dart';
import '../services/ble_service.dart';
import '../services/device_prefs_service.dart';
import '../widgets/accessible_button.dart';
import '../widgets/device_status_card.dart';
import '../widgets/hazard_alert_banner.dart';

class AccessibleHomeScreen extends StatefulWidget {
  const AccessibleHomeScreen({super.key});

  @override
  State<AccessibleHomeScreen> createState() => _AccessibleHomeScreenState();
}

class _AccessibleHomeScreenState extends State<AccessibleHomeScreen> {
  final GlobalKey<HazardAlertBannerState> _alertKey = GlobalKey();
  StreamSubscription<ObstacleAlert>? _obstacleSub;

  @override
  void initState() {
    super.initState();
    _obstacleSub = BleService.instance.obstacleStream.listen((alert) {
      _alertKey.currentState?.show(
        side: alert.side,
        distanceCm: alert.distanceCm,
      );
    });

    WidgetsBinding.instance.addPostFrameCallback((_) {
      SemanticsService.announce('iCan Eye home', TextDirection.ltr);
      _retryBleIfNeeded();
    });
  }

  Future<void> _retryBleIfNeeded() async {
    if (BleService.instance.state != BleConnectionState.disconnected) return;
    final savedId = await DevicePrefsService.instance.getLastDeviceId();
    if (savedId == null || savedId.isEmpty) return;
    unawaited(BleService.instance.connectToEyeByMac(savedId));
  }

  @override
  void dispose() {
    _obstacleSub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final vm = context.watch<HomeViewModel>();
    final topPadding = MediaQuery.of(context).padding.top;

    return Scaffold(
      backgroundColor: AppColors.backgroundLight,
      body: Stack(
        children: [
          SafeArea(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(AppSpacing.sm),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Semantics(
                    header: true,
                    label: 'iCan Eye',
                    child: ExcludeSemantics(
                      child: Text(
                        'iCan Eye',
                        style: TextStyle(
                          fontSize: 30.sp,
                          fontWeight: FontWeight.w800,
                          color: AppColors.textOnLight,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: AppSpacing.xs),
                  Text(
                    'Describe what is in front of you.',
                    style: TextStyle(
                      fontSize: 17.sp,
                      color: AppColors.textSecondaryOnLight,
                      height: 1.35,
                    ),
                  ),
                  const SizedBox(height: AppSpacing.md),
                  DeviceStatusCard(
                    deviceName: 'iCan Eye',
                    connectionState: vm.eyeConnection,
                    batteryPercent: -1,
                    onTap: () => vm.startScanForEye(),
                    tapHint: 'Scans for iCan Eye camera over Bluetooth',
                  ),
                  const SizedBox(height: AppSpacing.md),
                  _DescriptionPanel(vm: vm),
                  if (vm.lastDiagnostic.isNotEmpty) ...[
                    const SizedBox(height: AppSpacing.sm),
                    _DiagnosticPanel(diagnostic: vm.lastDiagnostic),
                  ],
                  const SizedBox(height: AppSpacing.md),
                  _FlowActions(vm: vm),
                ],
              ),
            ),
          ),
          Positioned(
            top: topPadding,
            left: 0,
            right: 0,
            child: HazardAlertBanner(key: _alertKey),
          ),
        ],
      ),
    );
  }
}

class _DescriptionPanel extends StatelessWidget {
  const _DescriptionPanel({required this.vm});

  final HomeViewModel vm;

  @override
  Widget build(BuildContext context) {
    final hasDescription = vm.lastDescription.isNotEmpty;
    final text = hasDescription
        ? vm.lastDescription
        : vm.liveVisionActive
        ? 'Live Detection is running.'
        : vm.isProcessing
        ? 'Processing camera image...'
        : 'Choose Cloud Describe, Offline Describe, or Live Detection.';

    return Semantics(
      liveRegion: true,
      label: text,
      child: Container(
        constraints: const BoxConstraints(minHeight: 156),
        padding: const EdgeInsets.all(AppSpacing.sm),
        decoration: BoxDecoration(
          color: AppColors.surfaceCardLight,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: AppColors.borderLight),
        ),
        child: ExcludeSemantics(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Text(
                    'Latest Description',
                    style: TextStyle(
                      fontSize: 14.sp,
                      fontWeight: FontWeight.w700,
                      color: AppColors.textSecondaryOnLight,
                    ),
                  ),
                  if (vm.isProcessing) ...[
                    const SizedBox(width: AppSpacing.xs),
                    const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  ],
                ],
              ),
              const SizedBox(height: AppSpacing.xs),
              Text(
                text,
                style: TextStyle(
                  fontSize: 19.sp,
                  color: hasDescription
                      ? AppColors.textOnLight
                      : AppColors.textSecondaryOnLight,
                  height: 1.45,
                ),
              ),
              if (hasDescription) ...[
                const SizedBox(height: AppSpacing.sm),
                TextButton.icon(
                  onPressed: vm.repeatLast,
                  icon: const Icon(Icons.volume_up_outlined),
                  label: const Text('Repeat'),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _DiagnosticPanel extends StatelessWidget {
  const _DiagnosticPanel({required this.diagnostic});

  final String diagnostic;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      liveRegion: true,
      label: 'Latest diagnostic. $diagnostic',
      child: Container(
        padding: const EdgeInsets.all(AppSpacing.sm),
        decoration: BoxDecoration(
          color: AppColors.surfaceCardLight,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: AppColors.error, width: 2),
        ),
        child: ExcludeSemantics(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Icon(Icons.error_outline, color: AppColors.error),
              const SizedBox(width: AppSpacing.xs),
              Expanded(
                child: SelectableText(
                  diagnostic,
                  style: TextStyle(
                    fontSize: 15.sp,
                    color: AppColors.textOnLight,
                    height: 1.35,
                  ),
                ),
              ),
              IconButton(
                tooltip: 'Copy diagnostic',
                icon: const Icon(Icons.copy),
                onPressed: () =>
                    Clipboard.setData(ClipboardData(text: diagnostic)),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _FlowActions extends StatelessWidget {
  const _FlowActions({required this.vm});

  final HomeViewModel vm;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        AccessibleButton(
          label: vm.isProcessing ? 'Cloud Describe Running' : 'Cloud Describe',
          hint: 'Takes one Eye photo and describes it with cloud vision',
          subtitle: 'Gemini 2.5 Flash',
          onPressed: vm.canCloudDescribe ? vm.describeCloudNow : null,
        ),
        const SizedBox(height: AppSpacing.sm),
        AccessibleButton(
          label: vm.isProcessing
              ? 'Offline Describe Running'
              : 'Offline Describe',
          hint: 'Takes one Eye photo and describes it on this iPhone',
          subtitle: 'Apple Vision, YOLOv3 Tiny, and Depth Anything template',
          onPressed: vm.canOfflineDescribe ? vm.describeOfflineNow : null,
        ),
        const SizedBox(height: AppSpacing.sm),
        AccessibleButton(
          label: vm.liveVisionActive
              ? 'Stop Live Detection'
              : 'Start Live Detection',
          hint: vm.liveVisionActive
              ? 'Stops live Eye detection'
              : 'Starts firmware-driven live Eye detection',
          subtitle: vm.liveVisionActive ? 'Running' : '2 second frame interval',
          onPressed: vm.isEyeConnected
              ? () {
                  if (vm.liveVisionActive) {
                    vm.stopLiveVision();
                  } else {
                    vm.startLiveVision();
                  }
                }
              : null,
        ),
      ],
    );
  }
}
