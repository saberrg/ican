import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/route_constants.dart';
import '../core/theme.dart';
import '../main.dart' show voiceCommandService;
import '../models/home_view_model.dart';
import '../models/settings_provider.dart';
import '../services/ble_service.dart';
import '../services/device_prefs_service.dart';
import '../services/on_device_vision_service.dart';
import '../services/scene_description_service.dart';
import '../services/voice_command_service.dart';
import '../widgets/accessible_button.dart';
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
    final settings = vm.settingsProvider;
    final voiceCommands = _voiceCommandsOrNull();
    final topPadding = MediaQuery.of(context).padding.top;

    return Scaffold(
      backgroundColor: AppColors.backgroundLight,
      body: Stack(
        children: [
          GestureDetector(
            behavior: HitTestBehavior.translucent,
            excludeFromSemantics: true,
            onDoubleTap: () => _launchVoiceIfIdle(voiceCommands),
            child: SafeArea(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(
                  AppSpacing.sm,
                  AppSpacing.sm,
                  AppSpacing.sm,
                  AppSpacing.lg,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const _ApiKeyWarningBanner(),
                    const _HomeHeader(),
                    const SizedBox(height: AppSpacing.sm),
                    _StatusBand(vm: vm, voiceCommands: voiceCommands),
                    const SizedBox(height: AppSpacing.sm),
                    const _EyeWifiRow(),
                    const SizedBox(height: AppSpacing.sm),
                    if (vm.liveVisionActive) ...[
                      const _LivePreview(),
                      const SizedBox(height: AppSpacing.sm),
                    ],
                    _ModeChips(vm: vm, settings: settings),
                    const SizedBox(height: AppSpacing.sm),
                    _VoiceCommandPanel(service: voiceCommands),
                    if (settings.lastChangeSummary.isNotEmpty) ...[
                      const SizedBox(height: AppSpacing.sm),
                      _TuningFeedbackBanner(
                        summary: settings.lastChangeSummary,
                      ),
                    ],
                    const SizedBox(height: AppSpacing.sm),
                    _DescriptionPanel(vm: vm),
                    const SizedBox(height: AppSpacing.sm),
                    const _LocalModelMissingBanner(),
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

  void _launchVoiceIfIdle(VoiceCommandService? service) {
    if (service == null) return;
    if (service.state != VoiceCommandState.idle) return;
    HapticFeedback.mediumImpact();
    SemanticsService.announce('Listening', TextDirection.ltr);
    unawaited(service.activateVoiceCommand());
  }

  VoiceCommandService? _voiceCommandsOrNull() {
    try {
      return voiceCommandService;
    } catch (_) {
      return null;
    }
  }
}

class _HomeHeader extends StatelessWidget {
  const _HomeHeader();

  @override
  Widget build(BuildContext context) {
    return Semantics(
      header: true,
      label: 'iCan Eye command center',
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: ExcludeSemantics(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'iCan Eye',
                    style: TextStyle(
                      fontSize: 32.sp,
                      fontWeight: FontWeight.w800,
                      color: AppColors.textOnLight,
                      height: 1.1,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    'Command center for Describe, Eye readiness, and voice tuning.',
                    style: TextStyle(
                      fontSize: 16.sp,
                      color: AppColors.textSecondaryOnLight,
                      height: 1.35,
                    ),
                  ),
                ],
              ),
            ),
          ),
          Semantics(
            button: true,
            label: 'Settings',
            hint: 'Opens app settings including Live cloud policy',
            child: IconButton(
              icon: const Icon(Icons.settings_rounded),
              color: AppColors.textOnLight,
              iconSize: 28,
              tooltip: 'Settings',
              onPressed: () => context.pushNamed(Routes.settingsName),
            ),
          ),
        ],
      ),
    );
  }
}

class _StatusBand extends StatelessWidget {
  const _StatusBand({required this.vm, required this.voiceCommands});

  final HomeViewModel vm;
  final VoiceCommandService? voiceCommands;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(AppSpacing.sm),
      decoration: BoxDecoration(
        color: AppColors.backgroundLight.withAlpha(238),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: AppColors.borderLight),
        boxShadow: const [
          BoxShadow(
            color: Color(0x14000000),
            blurRadius: 18,
            offset: Offset(0, 8),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Wrap(
            spacing: AppSpacing.xs,
            runSpacing: AppSpacing.xs,
            children: [
              _StatusTile(
                label: 'Eye',
                value: _eyeStatusLabel(vm),
                semanticLabel: 'iCan Eye status. ${_eyeStatusLabel(vm)}.',
                icon: Icons.camera_alt_outlined,
                tone: _eyeStatusTone(vm),
              ),
              _StatusTile(
                label: 'Voice',
                value: _voiceStatusLabel(voiceCommands),
                semanticLabel:
                    'Voice command status. ${_voiceStatusLabel(voiceCommands)}.',
                icon: Icons.graphic_eq,
                tone: _StatusTone.neutral,
              ),
              _StatusTile(
                label: 'Vision',
                value: _visionModeLabel(vm.visionMode),
                semanticLabel:
                    'Vision mode. ${_visionModeLabel(vm.visionMode)}.',
                icon: Icons.cloud_outlined,
                tone: _visionTone(vm.visionMode),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.xs),
          TextButton.icon(
            onPressed: vm.startScanForEye,
            icon: const Icon(Icons.bluetooth_searching),
            label: const Text('Scan Eye'),
          ),
        ],
      ),
    );
  }

  static String _eyeStatusLabel(HomeViewModel vm) {
    if (vm.isEyeConnected && BleService.instance.eyeReadinessStatus.ready) {
      return 'Ready';
    }
    return switch (vm.eyeConnection) {
      BleConnectionState.scanning => 'Scanning',
      BleConnectionState.connecting => 'Connecting',
      BleConnectionState.connected => 'Connecting',
      BleConnectionState.disconnected => 'Disconnected',
    };
  }

  static _StatusTone _eyeStatusTone(HomeViewModel vm) {
    if (vm.isEyeConnected && BleService.instance.eyeReadinessStatus.ready) {
      return _StatusTone.good;
    }
    return switch (vm.eyeConnection) {
      BleConnectionState.scanning ||
      BleConnectionState.connecting ||
      BleConnectionState.connected => _StatusTone.neutral,
      BleConnectionState.disconnected => _StatusTone.alert,
    };
  }

  static String _visionModeLabel(VisionMode mode) {
    return switch (mode) {
      VisionMode.auto => 'Cloud first',
      VisionMode.cloudOnly => 'Cloud',
      VisionMode.offlineOnly => 'Local',
    };
  }

  static _StatusTone _visionTone(VisionMode mode) {
    return mode == VisionMode.offlineOnly
        ? _StatusTone.neutral
        : _StatusTone.good;
  }

  static String _voiceStatusLabel(VoiceCommandService? service) {
    return switch (service?.state) {
      VoiceCommandState.listening => 'Listening',
      VoiceCommandState.processing => 'Processing',
      _ => 'Ready',
    };
  }
}

enum _StatusTone { good, alert, neutral }

class _StatusTile extends StatelessWidget {
  const _StatusTile({
    required this.label,
    required this.value,
    required this.semanticLabel,
    required this.icon,
    required this.tone,
  });

  final String label;
  final String value;
  final String semanticLabel;
  final IconData icon;
  final _StatusTone tone;

  @override
  Widget build(BuildContext context) {
    final color = switch (tone) {
      _StatusTone.good => AppColors.success,
      _StatusTone.alert => AppColors.error,
      _StatusTone.neutral => AppColors.interactive,
    };

    return Semantics(
      label: semanticLabel,
      child: ExcludeSemantics(
        child: Container(
          constraints: const BoxConstraints(minHeight: 56, minWidth: 98),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: BoxDecoration(
            color: AppColors.surfaceCardLight,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: AppColors.borderLight),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, color: color, size: 22),
              const SizedBox(width: 8),
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    label,
                    style: TextStyle(
                      fontSize: 12.sp,
                      color: AppColors.textSecondaryOnLight,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  Text(
                    value,
                    style: TextStyle(
                      fontSize: 15.sp,
                      color: AppColors.textOnLight,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ModeChips extends StatelessWidget {
  const _ModeChips({required this.vm, required this.settings});

  final HomeViewModel vm;
  final SettingsProvider settings;

  @override
  Widget build(BuildContext context) {
    final localReady = vm.visionRuntimeStatus?.basicLocalVisionReady ?? false;

    return Semantics(
      label:
          'Active mode. ${vm.visionControlMode.label}. Cloud, Local, and Live are available.',
      child: ExcludeSemantics(
        child: Wrap(
          spacing: AppSpacing.xs,
          runSpacing: AppSpacing.xs,
          children: [
            _ModeChip(
              label: 'Cloud',
              active: vm.visionControlMode == VisionControlMode.cloud,
            ),
            _ModeChip(
              label: localReady ? 'Local' : 'Local unavailable',
              active: vm.visionControlMode == VisionControlMode.local,
              unavailable: !localReady,
            ),
            _ModeChip(
              label: vm.liveVisionActive ? 'Live running' : 'Live',
              active:
                  vm.visionControlMode == VisionControlMode.live ||
                  vm.liveVisionActive,
            ),
          ],
        ),
      ),
    );
  }
}

class _VoiceCommandPanel extends StatelessWidget {
  const _VoiceCommandPanel({required this.service});

  final VoiceCommandService? service;

  @override
  Widget build(BuildContext context) {
    final current = service;
    final state = current?.state ?? VoiceCommandState.idle;
    final partial = current?.partialText ?? '';
    final result = current?.lastResult ?? '';
    final listening = state == VoiceCommandState.listening;
    final processing = state == VoiceCommandState.processing;
    final label = listening
        ? 'Listening'
        : processing
        ? 'Processing voice'
        : 'Listen';
    final body = partial.isNotEmpty
        ? partial
        : result.isNotEmpty
        ? result
        : 'Double-tap anywhere or press Listen to speak.';

    return Semantics(
      liveRegion: true,
      label: 'Voice command. $label. $body',
      child: Container(
        padding: const EdgeInsets.all(AppSpacing.sm),
        decoration: BoxDecoration(
          color: AppColors.surfaceCardLight,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: AppColors.borderLight),
        ),
        child: ExcludeSemantics(
          child: Row(
            children: [
              Expanded(
                child: Text(
                  body,
                  style: TextStyle(
                    fontSize: 15.sp,
                    color: AppColors.textOnLight,
                    fontWeight: FontWeight.w700,
                    height: 1.25,
                  ),
                ),
              ),
              const SizedBox(width: AppSpacing.xs),
              SizedBox(
                width: 136,
                child: ElevatedButton.icon(
                  onPressed: current == null || state != VoiceCommandState.idle
                      ? null
                      : () => unawaited(current.activateVoiceCommand()),
                  icon: Icon(listening ? Icons.graphic_eq : Icons.mic),
                  label: Text(label, textAlign: TextAlign.center),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ModeChip extends StatelessWidget {
  const _ModeChip({
    required this.label,
    required this.active,
    this.unavailable = false,
  });

  final String label;
  final bool active;
  final bool unavailable;

  @override
  Widget build(BuildContext context) {
    final background = active
        ? AppColors.interactive
        : unavailable
        ? const Color(0xFFE8E8E8)
        : AppColors.surfaceCardLight;
    final foreground = active ? AppColors.textOnDark : AppColors.textOnLight;
    final border = active ? AppColors.interactive : AppColors.borderLight;

    return Container(
      constraints: const BoxConstraints(minHeight: 40),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: border),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 14.sp,
          color: foreground,
          fontWeight: FontWeight.w800,
        ),
      ),
    );
  }
}

class _TuningFeedbackBanner extends StatelessWidget {
  const _TuningFeedbackBanner({required this.summary});

  final String summary;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      liveRegion: true,
      label: 'Voice tuning feedback. $summary.',
      child: Container(
        constraints: const BoxConstraints(minHeight: 48),
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.sm,
          vertical: 12,
        ),
        decoration: BoxDecoration(
          color: const Color(0xFFEAF3FF),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: AppColors.interactive),
        ),
        child: ExcludeSemantics(
          child: Row(
            children: [
              const Icon(Icons.tune, color: AppColors.interactive),
              const SizedBox(width: AppSpacing.xs),
              Expanded(
                child: Text(
                  summary,
                  style: TextStyle(
                    fontSize: 16.sp,
                    fontWeight: FontWeight.w800,
                    color: AppColors.textOnLight,
                    height: 1.25,
                  ),
                ),
              ),
            ],
          ),
        ),
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
        : 'Connect iCan Eye, then press Describe.';
    final state = vm.isProcessing
        ? 'Processing'
        : vm.liveVisionActive
        ? 'Live'
        : hasDescription
        ? 'Ready'
        : 'Waiting';

    return Semantics(
      liveRegion: true,
      label: 'Latest description. $text',
      child: Container(
        constraints: const BoxConstraints(minHeight: 184),
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
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Text(
                      'Latest Description',
                      style: TextStyle(
                        fontSize: 15.sp,
                        fontWeight: FontWeight.w800,
                        color: AppColors.textSecondaryOnLight,
                      ),
                    ),
                  ),
                  _BackendPill(backend: vm.lastBackend),
                  const SizedBox(width: AppSpacing.xs),
                  _StateBadge(label: state, busy: vm.isProcessing),
                ],
              ),
              const SizedBox(height: AppSpacing.sm),
              Text(
                text,
                style: TextStyle(
                  fontSize: 20.sp,
                  color: hasDescription
                      ? AppColors.textOnLight
                      : AppColors.textSecondaryOnLight,
                  height: 1.42,
                  fontWeight: hasDescription
                      ? FontWeight.w600
                      : FontWeight.w500,
                ),
              ),
              if (hasDescription) ...[
                const SizedBox(height: AppSpacing.sm),
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton.icon(
                    onPressed: vm.repeatLast,
                    icon: const Icon(Icons.volume_up_outlined),
                    label: const Text('Repeat'),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _StateBadge extends StatelessWidget {
  const _StateBadge({required this.label, required this.busy});

  final String label;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    return Container(
      constraints: const BoxConstraints(minHeight: 32),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
      decoration: BoxDecoration(
        color: busy ? const Color(0xFFEAF3FF) : AppColors.backgroundLight,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: AppColors.borderLight),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (busy) ...[
            const SizedBox(
              width: 14,
              height: 14,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            const SizedBox(width: 6),
          ],
          Text(
            label,
            style: TextStyle(
              fontSize: 13.sp,
              fontWeight: FontWeight.w800,
              color: AppColors.textOnLight,
            ),
          ),
        ],
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

/// Appears on Home when the user is in Local vision mode but no local
/// generative backend (SmolVLM2 or Foundation Models) is available. Tapping
/// the banner opens Vision Diagnostic where the model can be downloaded or
/// Apple Intelligence can be enabled. Dismissible per-session — reappears on
/// next app launch so the user isn't nagged while still pair-debugging.
class _LocalModelMissingBanner extends StatefulWidget {
  const _LocalModelMissingBanner();

  @override
  State<_LocalModelMissingBanner> createState() =>
      _LocalModelMissingBannerState();
}

class _LocalModelMissingBannerState extends State<_LocalModelMissingBanner> {
  final _vision = OnDeviceVisionService();
  bool _dismissed = false;
  ModelStatus? _status;
  bool? _fmAvailable;
  Timer? _poll;

  @override
  void initState() {
    super.initState();
    unawaited(_refresh());
    // Re-poll every 15s so the banner disappears once a download finishes or
    // the user enables Apple Intelligence — without a full navigation cycle.
    _poll = Timer.periodic(const Duration(seconds: 15), (_) => _refresh());
  }

  @override
  void dispose() {
    _poll?.cancel();
    super.dispose();
  }

  Future<void> _refresh() async {
    try {
      final status = await _vision.getModelStatus();
      final fm = await _vision.isFoundationModelsAvailable();
      if (!mounted) return;
      setState(() {
        _status = status;
        _fmAvailable = fm;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _status = ModelStatus.notDownloaded;
        _fmAvailable = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_dismissed) return const SizedBox.shrink();
    final vm = context.watch<HomeViewModel>();
    if (vm.liveVisionActive) return const SizedBox.shrink();
    // Only prod the user when they're actually using Local — Cloud mode users
    // don't care that the local model isn't installed.
    if (vm.sceneService.mode != VisionMode.offlineOnly) {
      return const SizedBox.shrink();
    }
    final status = _status;
    final fmAvailable = _fmAvailable;
    // Still checking — render nothing to avoid a flash of the banner.
    if (status == null || fmAvailable == null) return const SizedBox.shrink();
    // A usable local backend exists → hide.
    final smolReady =
        status == ModelStatus.ready || status == ModelStatus.loaded;
    if (smolReady || fmAvailable) return const SizedBox.shrink();

    final downloading = status == ModelStatus.downloading;
    final title = downloading
        ? 'Local vision model is downloading'
        : 'Local vision model not installed';
    final body = downloading
        ? 'Tap to open diagnostics and see progress.'
        : 'Tap to download (~1.6 GB, Wi-Fi recommended). Until then, Local mode falls back to a short template description.';

    return Semantics(
      button: true,
      label: '$title. $body',
      child: InkWell(
        onTap: () => context.pushNamed('vision-diagnostic'),
        borderRadius: BorderRadius.circular(8),
        child: Container(
          padding: const EdgeInsets.all(AppSpacing.sm),
          decoration: BoxDecoration(
            color: AppColors.surfaceCardLight,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: AppColors.warning.withValues(alpha: 0.7),
              width: 1.5,
            ),
          ),
          child: ExcludeSemantics(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Icon(Icons.download_rounded, color: AppColors.warning),
                const SizedBox(width: AppSpacing.xs),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        style: TextStyle(
                          fontSize: 15.sp,
                          fontWeight: FontWeight.w700,
                          color: AppColors.textOnLight,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        body,
                        style: TextStyle(
                          fontSize: 13.sp,
                          color: AppColors.textSecondaryOnLight,
                          height: 1.3,
                        ),
                      ),
                    ],
                  ),
                ),
                IconButton(
                  tooltip: 'Dismiss',
                  icon: const Icon(Icons.close),
                  onPressed: () => setState(() => _dismissed = true),
                ),
              ],
            ),
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
    final actionLabel = switch (vm.visionControlMode) {
      VisionControlMode.cloud =>
        vm.isProcessing ? 'Cloud Running' : 'Run Cloud',
      VisionControlMode.local =>
        vm.isProcessing ? 'Local Running' : 'Run Local',
      VisionControlMode.live =>
        vm.liveVisionActive ? 'Stop Live' : 'Start Live',
    };
    final actionHint = switch (vm.visionControlMode) {
      VisionControlMode.cloud =>
        'Takes one Eye photo and describes it with cloud vision',
      VisionControlMode.local =>
        'Takes one Eye photo and describes it on this iPhone when local vision is healthy',
      VisionControlMode.live =>
        vm.liveVisionActive
            ? 'Stops live Eye detection'
            : 'Starts firmware-driven live Eye detection',
    };
    final enabled = vm.visionControlMode == VisionControlMode.live
        ? vm.isEyeConnected
        : vm.canDescribe;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        AccessibleButton(
          label: actionLabel,
          hint: actionHint,
          subtitle:
              'Eye button: single describes, double swaps Cloud/Local, long toggles Live',
          onPressed: enabled ? vm.executeActiveVisionMode : null,
        ),
        const SizedBox(height: AppSpacing.sm),
        _ModeButtonRow(vm: vm),
      ],
    );
  }
}

class _ModeButtonRow extends StatelessWidget {
  const _ModeButtonRow({required this.vm});

  final HomeViewModel vm;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: AppSpacing.xs,
      runSpacing: AppSpacing.xs,
      alignment: WrapAlignment.center,
      children: [
        _ModeSelectButton(
          label: 'Cloud',
          icon: Icons.cloud_outlined,
          selected: vm.visionControlMode == VisionControlMode.cloud,
          onPressed: () =>
              unawaited(vm.setVisionControlMode(VisionControlMode.cloud)),
        ),
        _ModeSelectButton(
          label: 'Local',
          icon: Icons.phone_iphone,
          selected: vm.visionControlMode == VisionControlMode.local,
          onPressed: () =>
              unawaited(vm.setVisionControlMode(VisionControlMode.local)),
        ),
        _ModeSelectButton(
          label: 'Live',
          icon: Icons.sensors_outlined,
          selected: vm.visionControlMode == VisionControlMode.live,
          onPressed: () =>
              unawaited(vm.setVisionControlMode(VisionControlMode.live)),
        ),
      ],
    );
  }
}

class _ModeSelectButton extends StatelessWidget {
  const _ModeSelectButton({
    required this.label,
    required this.icon,
    required this.selected,
    required this.onPressed,
  });

  final String label;
  final IconData icon;
  final bool selected;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      selected: selected,
      label: '$label mode',
      child: selected
          ? FilledButton.icon(
              onPressed: onPressed,
              icon: Icon(icon),
              label: Text(label),
            )
          : OutlinedButton.icon(
              onPressed: onPressed,
              icon: Icon(icon),
              label: Text(label),
            ),
    );
  }
}

class _ApiKeyWarningBanner extends StatelessWidget {
  const _ApiKeyWarningBanner();

  static const String _apiKey = String.fromEnvironment('API_KEY');

  @override
  Widget build(BuildContext context) {
    if (_apiKey.isNotEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.sm),
      child: Semantics(
        liveRegion: true,
        label: 'Cloud vision disabled: API key missing at build time.',
        child: Container(
          constraints: const BoxConstraints(minHeight: 48),
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.sm,
            vertical: 12,
          ),
          decoration: BoxDecoration(
            color: const Color(0xFFFFF4E5),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: AppColors.error, width: 2),
          ),
          child: ExcludeSemantics(
            child: Row(
              children: [
                const Icon(Icons.warning_amber_rounded, color: AppColors.error),
                const SizedBox(width: AppSpacing.xs),
                Expanded(
                  child: Text(
                    'Cloud vision disabled: API key missing at build time.',
                    style: TextStyle(
                      fontSize: 16.sp,
                      fontWeight: FontWeight.w800,
                      color: AppColors.textOnLight,
                      height: 1.25,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ───────────────────────── Eye WiFi provisioning ─────────────────────────

class _EyeWifiRow extends StatefulWidget {
  const _EyeWifiRow();

  @override
  State<_EyeWifiRow> createState() => _EyeWifiRowState();
}

class _EyeWifiRowState extends State<_EyeWifiRow> {
  static const String _ssidPrefKey = 'eye_wifi_ssid';
  static const String _passwordPrefKey = 'eye_wifi_password';

  final TextEditingController _ssidCtrl = TextEditingController();
  final TextEditingController _passwordCtrl = TextEditingController();

  @override
  void initState() {
    super.initState();
    unawaited(_loadSavedCredentials());
  }

  Future<void> _loadSavedCredentials() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (!mounted) return;
      setState(() {
        _ssidCtrl.text = prefs.getString(_ssidPrefKey) ?? '';
        _passwordCtrl.text = prefs.getString(_passwordPrefKey) ?? '';
      });
    } catch (_) {
      // If prefs fail, the fields just stay blank; user can retype.
    }
  }

  Future<void> _sendWifi() async {
    final ssid = _ssidCtrl.text.trim();
    final password = _passwordCtrl.text;
    if (ssid.isEmpty) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_ssidPrefKey, ssid);
      await prefs.setString(_passwordPrefKey, password);
    } catch (_) {}
    unawaited(
      BleService.instance.configureWifi(ssid: ssid, password: password),
    );
  }

  @override
  void dispose() {
    _ssidCtrl.dispose();
    _passwordCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final vm = context.watch<HomeViewModel>();
    final status = vm.wifiStatus;

    if (status.state == EyeWifiState.ready) {
      return _ReadyPill(ip: status.ipAddress ?? 'unknown');
    }

    if (!vm.isEyeConnected) {
      return const SizedBox.shrink();
    }

    final trying = status.state == EyeWifiState.trying;
    final failed = status.state == EyeWifiState.failed;

    return Semantics(
      label: 'Eye WiFi provisioning',
      liveRegion: trying || failed,
      child: Container(
        padding: const EdgeInsets.all(AppSpacing.sm),
        decoration: BoxDecoration(
          color: AppColors.surfaceCardLight,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: AppColors.borderLight),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'Provision Eye WiFi',
              style: TextStyle(
                fontSize: 15.sp,
                fontWeight: FontWeight.w800,
                color: AppColors.textSecondaryOnLight,
              ),
            ),
            const SizedBox(height: AppSpacing.xs),
            TextField(
              controller: _ssidCtrl,
              enabled: !trying,
              decoration: const InputDecoration(
                labelText: 'Hotspot SSID',
                border: OutlineInputBorder(),
                isDense: true,
              ),
              style: TextStyle(fontSize: 16.sp),
            ),
            const SizedBox(height: AppSpacing.xs),
            TextField(
              controller: _passwordCtrl,
              enabled: !trying,
              obscureText: true,
              decoration: const InputDecoration(
                labelText: 'Password',
                border: OutlineInputBorder(),
                isDense: true,
              ),
              style: TextStyle(fontSize: 16.sp),
            ),
            const SizedBox(height: AppSpacing.xs),
            Row(
              children: [
                if (trying) ...[
                  const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                  const SizedBox(width: AppSpacing.xs),
                  Text(
                    'Provisioning Eye...',
                    style: TextStyle(
                      fontSize: 14.sp,
                      color: AppColors.textSecondaryOnLight,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const Spacer(),
                ],
                Semantics(
                  button: true,
                  label: 'Send WiFi credentials to Eye',
                  child: FilledButton.icon(
                    onPressed: trying ? null : _sendWifi,
                    icon: const Icon(Icons.wifi),
                    label: const Text('Send to Eye'),
                  ),
                ),
              ],
            ),
            if (failed && status.failureReason != null) ...[
              const SizedBox(height: AppSpacing.xs),
              Text(
                status.failureReason!,
                style: TextStyle(
                  fontSize: 14.sp,
                  color: AppColors.error,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _ReadyPill extends StatelessWidget {
  const _ReadyPill({required this.ip});

  final String ip;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: 'Eye on WiFi. IP address $ip.',
      child: ExcludeSemantics(
        child: Container(
          constraints: const BoxConstraints(minHeight: 56),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: BoxDecoration(
            color: AppColors.backgroundLight,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: AppColors.success, width: 2),
          ),
          child: Row(
            children: [
              const Icon(Icons.wifi, color: AppColors.success, size: 22),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Eye on WiFi — $ip',
                  style: TextStyle(
                    fontSize: 15.sp,
                    color: AppColors.success,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ───────────────────────── Live frame preview ─────────────────────────

class _LivePreview extends StatefulWidget {
  const _LivePreview();

  @override
  State<_LivePreview> createState() => _LivePreviewState();
}

class _LivePreviewState extends State<_LivePreview> {
  StreamSubscription<Uint8List>? _frameSub;
  Uint8List? _latestBytes;
  DateTime _lastUiUpdate = DateTime.fromMillisecondsSinceEpoch(0);

  static const Duration _throttle = Duration(milliseconds: 100);

  @override
  void initState() {
    super.initState();
    final vm = context.read<HomeViewModel>();
    _frameSub = vm.activeFrameStream.listen(_onFrame);
  }

  void _onFrame(Uint8List bytes) {
    final now = DateTime.now();
    if (now.difference(_lastUiUpdate) < _throttle) {
      // Still stash latest bytes so the next tick has the freshest frame.
      _latestBytes = bytes;
      return;
    }
    _lastUiUpdate = now;
    if (!mounted) return;
    setState(() {
      _latestBytes = bytes;
    });
  }

  @override
  void dispose() {
    _frameSub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final bytes = _latestBytes;
    return Semantics(
      label: 'Live Eye camera preview',
      image: true,
      child: Container(
        height: 160,
        decoration: BoxDecoration(
          color: AppColors.surfaceCardLight,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: AppColors.borderLight),
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: bytes == null
              ? Center(
                  child: Text(
                    'Waiting for live frames...',
                    style: TextStyle(
                      fontSize: 15.sp,
                      color: AppColors.textSecondaryOnLight,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                )
              : ExcludeSemantics(
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      Image.memory(
                        bytes,
                        gaplessPlayback: true,
                        fit: BoxFit.cover,
                        width: double.infinity,
                        height: 160,
                      ),
                      const Positioned(
                        top: 8,
                        right: 8,
                        child: _LiveCloudBudgetChip(),
                      ),
                    ],
                  ),
                ),
        ),
      ),
    );
  }
}

/// Tiny overlay that surfaces the Live-mode cloud-call budget. Hidden when
/// the user has picked localOnly — no need to display a counter for a feature
/// that won't fire. Updates as the HomeViewModel notifies listeners (the
/// controller forwards its notifications through `_liveController`).
class _LiveCloudBudgetChip extends StatelessWidget {
  const _LiveCloudBudgetChip();

  @override
  Widget build(BuildContext context) {
    final vm = context.watch<HomeViewModel>();
    final settings = context.watch<SettingsProvider>();
    if (settings.liveCloudPolicy == LiveCloudPolicy.localOnly) {
      return const SizedBox.shrink();
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: Colors.black.withAlpha(166),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Text(
        'Cloud ${vm.liveCloudCallsUsed}/${vm.liveCloudCallsMax}',
        style: TextStyle(
          color: Colors.white,
          fontSize: 12.sp,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

// ───────────────────────── Backend pill ─────────────────────────

class _BackendPill extends StatelessWidget {
  const _BackendPill({required this.backend});

  final VisionBackend? backend;

  @override
  Widget build(BuildContext context) {
    final b = backend;
    if (b == null) return const SizedBox.shrink();

    final name = switch (b) {
      VisionBackend.cloud => 'Gemini',
      VisionBackend.foundationModels => 'Foundation',
      VisionBackend.vlm => 'SmolVLM2',
      VisionBackend.visionOnly => 'Vision',
    };
    final isCloud = b == VisionBackend.cloud;
    final icon = isCloud ? Icons.cloud_outlined : Icons.phone_iphone;
    final color = isCloud
        ? AppColors.interactive
        : AppColors.textSecondaryOnLight;

    return Semantics(
      label: 'Last analyzed with $name',
      child: ExcludeSemantics(
        child: Container(
          constraints: const BoxConstraints(minHeight: 24),
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          decoration: BoxDecoration(
            color: AppColors.backgroundLight,
            borderRadius: BorderRadius.circular(6),
            border: Border.all(color: color),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, color: color, size: 14),
              const SizedBox(width: 4),
              Text(
                name,
                style: TextStyle(
                  fontSize: 12.sp,
                  color: color,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
