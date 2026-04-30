import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:provider/provider.dart';

import 'package:go_router/go_router.dart';

import '../core/route_constants.dart';
import '../core/theme.dart';
import '../models/font_scale.dart';
import '../models/settings_provider.dart';
import '../services/ble_service.dart';
import '../services/tts_service.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  VoidCallback? _bleListener;

  @override
  void initState() {
    super.initState();
    _bleListener = () {
      if (mounted) setState(() {});
    };
    BleService.instance.addListener(_bleListener!);

    WidgetsBinding.instance.addPostFrameCallback((_) {
      SemanticsService.announce('Settings screen.', TextDirection.ltr);
    });
  }

  @override
  void dispose() {
    if (_bleListener != null) {
      BleService.instance.removeListener(_bleListener!);
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<SettingsProvider>();

    return Scaffold(
      backgroundColor: AppColors.backgroundLight,
      body: SafeArea(
        child: FocusTraversalGroup(
          policy: OrderedTraversalPolicy(),
          child: CustomScrollView(
            slivers: [
              // ── Title + back button ──
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(
                    AppSpacing.xs,
                    AppSpacing.xs,
                    AppSpacing.sm,
                    0,
                  ),
                  child: Row(
                    children: [
                      Semantics(
                        button: true,
                        label: 'Back',
                        child: IconButton(
                          icon: const Icon(Icons.arrow_back_rounded),
                          color: AppColors.textOnLight,
                          tooltip: 'Back',
                          onPressed: () {
                            if (context.canPop()) {
                              context.pop();
                            } else {
                              context.goNamed(Routes.homeName);
                            }
                          },
                        ),
                      ),
                      Expanded(
                        child: Semantics(
                          header: true,
                          child: Text(
                            'Settings',
                            style: TextStyle(
                              fontSize: 28.sp,
                              fontWeight: FontWeight.bold,
                              color: AppColors.textOnLight,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),

              SliverPadding(
                padding: const EdgeInsets.all(AppSpacing.sm),
                sliver: SliverList(
                  delegate: SliverChildListDelegate([
                    const SizedBox(height: AppSpacing.sm),
                    if (settings.lastChangeSummary.isNotEmpty) ...[
                      _SettingsFeedbackBanner(
                        summary: settings.lastChangeSummary,
                      ),
                      const SizedBox(height: AppSpacing.md),
                    ],

                    // ── 1. Audio ──
                    _buildAudioSection(settings),
                    const SizedBox(height: AppSpacing.lg),

                    // ── 2. Descriptions ──
                    _buildDescriptionsSection(settings),
                    const SizedBox(height: AppSpacing.lg),

                    // ── 3. Live Detection ──
                    // ── 4. Devices ──
                    _buildDevicesSection(),
                    const SizedBox(height: AppSpacing.lg),

                    // ── 5. Accessibility ──
                    _buildAccessibilitySection(settings),
                    const SizedBox(height: AppSpacing.lg),

                    // ── 6. About ──
                    _buildAboutSection(),
                    const SizedBox(height: AppSpacing.xl),
                  ]),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // 1. Audio
  // ═══════════════════════════════════════════════════════════════════════════

  Widget _buildAudioSection(SettingsProvider s) {
    return _Section(
      title: 'Audio',
      children: [
        // ── Speech speed ──
        _SettingTile(
          semanticLabel:
              'Description speed. ${s.wordsPerMinute} words per minute. Adjust with swipe up or down.',
          semanticSlider: true,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _SettingLabel('Description Speed'),
              const SizedBox(height: 4),
              _SettingValue('${s.wordsPerMinute} words per minute'),
              const SizedBox(height: AppSpacing.xs),
              _AccessibleSlider(
                value: s.speechRate,
                min: 0.0,
                max: 1.0,
                divisions: 10,
                onChanged: (v) {
                  HapticFeedback.selectionClick();
                  s.setSpeechRate(v);
                },
              ),
              _SliderLabels(left: 'Slower', right: 'Faster'),
            ],
          ),
        ),

        const _Divider(),

        // ── Volume ──
        _SettingTile(
          semanticLabel: 'Volume. ${(s.volume * 100).round()} percent.',
          semanticSlider: true,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _SettingLabel('Volume'),
              const SizedBox(height: 4),
              _SettingValue('${(s.volume * 100).round()}%'),
              const SizedBox(height: AppSpacing.xs),
              _AccessibleSlider(
                value: s.volume,
                min: 0.0,
                max: 1.0,
                divisions: 10,
                onChanged: (v) {
                  HapticFeedback.selectionClick();
                  s.setVolume(v);
                },
              ),
              _SliderLabels(left: 'Quiet', right: 'Loud'),
            ],
          ),
        ),

        const _Divider(),

        // ── Pitch ──
        _SettingTile(
          semanticLabel:
              'Speech engine. Currently ${s.speechEngine.label}. Auto uses cloud voices for full descriptions when available.',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _SettingLabel('Speech Engine'),
              const SizedBox(height: AppSpacing.xs),
              SizedBox(
                width: double.infinity,
                child: SegmentedButton<SpeechEngine>(
                  segments: SpeechEngine.values
                      .map(
                        (engine) => ButtonSegment<SpeechEngine>(
                          value: engine,
                          label: Text(engine.label),
                        ),
                      )
                      .toList(),
                  selected: {s.speechEngine},
                  onSelectionChanged: (sel) {
                    HapticFeedback.selectionClick();
                    s.setSpeechEngine(sel.first);
                  },
                  style: _segmentedStyle(),
                ),
              ),
              const SizedBox(height: AppSpacing.xs),
              Text(
                'Auto keeps short commands on native speech and uses cloud speech for full descriptions when the Worker is reachable.',
                style: TextStyle(
                  fontSize: 14.sp,
                  color: AppColors.textSecondaryOnLight,
                ),
              ),
            ],
          ),
        ),

        const _Divider(),

        _SettingTile(
          semanticLabel:
              'Voice pitch. Current value ${s.pitch.toStringAsFixed(1)}.',
          semanticSlider: true,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _SettingLabel('Voice Pitch'),
              const SizedBox(height: 4),
              _SettingValue(s.pitch.toStringAsFixed(1)),
              const SizedBox(height: AppSpacing.xs),
              _AccessibleSlider(
                value: s.pitch,
                min: 0.5,
                max: 2.0,
                divisions: 15,
                onChanged: (v) {
                  HapticFeedback.selectionClick();
                  s.setPitch(v);
                },
              ),
              _SliderLabels(left: 'Lower', right: 'Higher'),
            ],
          ),
        ),

        const _Divider(),

        // ── Voice type ──
        _SettingTile(
          semanticLabel: 'Voice selection.',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _SettingLabel('Voice'),
              const SizedBox(height: AppSpacing.xs),
              FutureBuilder<List<TtsVoiceOption>>(
                future: s.availableVoices(),
                builder: (context, snapshot) {
                  final voices = snapshot.data ?? const <TtsVoiceOption>[];
                  if (snapshot.connectionState != ConnectionState.done) {
                    return const Center(child: CircularProgressIndicator());
                  }
                  if (voices.isEmpty) {
                    return _SettingValue('System voice');
                  }
                  final visibleVoices = voices.take(12).toList();
                  final selectedId =
                      visibleVoices.any(
                        (voice) => voice.id == s.selectedVoiceId,
                      )
                      ? s.selectedVoiceId
                      : null;
                  return Column(
                    children: [
                      DropdownButtonFormField<String>(
                        initialValue: selectedId,
                        isExpanded: true,
                        items: visibleVoices
                            .map(
                              (voice) => DropdownMenuItem<String>(
                                value: voice.id,
                                child: Text(voice.label),
                              ),
                            )
                            .toList(),
                        onChanged: (id) {
                          if (id == null) return;
                          final match = voices.where((voice) => voice.id == id);
                          if (match.isEmpty) return;
                          HapticFeedback.selectionClick();
                          unawaited(s.setVoiceOption(match.first));
                        },
                      ),
                      const SizedBox(height: AppSpacing.xs),
                      Align(
                        alignment: Alignment.centerLeft,
                        child: TextButton(
                          onPressed: () => unawaited(s.previewVoice()),
                          child: const Text('Preview Voice'),
                        ),
                      ),
                    ],
                  );
                },
              ),
            ],
          ),
        ),

        const _Divider(),

        _TapTile(
          label: 'Restore Speech Defaults',
          hint: 'Restores safe audible speech settings',
          onTap: () {
            HapticFeedback.lightImpact();
            unawaited(s.restoreSafeSpeechDefaults());
          },
        ),
      ],
    );
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // 2. Descriptions
  // ═══════════════════════════════════════════════════════════════════════════

  Widget _buildDescriptionsSection(SettingsProvider s) {
    return _Section(
      title: 'Descriptions',
      children: [
        // ── Detail level ──
        _SettingTile(
          semanticLabel:
              'Detail level. Currently ${s.detailLevel.label}. '
              'Brief gives short summaries. Rich gives full scene descriptions.',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _SettingLabel('Detail Level'),
              const SizedBox(height: AppSpacing.xs),
              SizedBox(
                width: double.infinity,
                child: SegmentedButton<DetailLevel>(
                  segments: DetailLevel.values
                      .map(
                        (d) => ButtonSegment<DetailLevel>(
                          value: d,
                          label: Text(d.label),
                        ),
                      )
                      .toList(),
                  selected: {s.detailLevel},
                  onSelectionChanged: (sel) {
                    HapticFeedback.selectionClick();
                    s.setDetailLevel(sel.first);
                  },
                  style: _segmentedStyle(),
                ),
              ),
            ],
          ),
        ),

        const _Divider(),

        // ── Hazard sensitivity ──
        _SettingTile(
          semanticLabel:
              'Hazard alert sensitivity. Currently ${s.hazardSensitivity.label}. '
              'Low alerts for very close obstacles only. '
              'Medium alerts within arm\'s reach. '
              'High alerts for anything nearby.',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _SettingLabel('Hazard Alert Sensitivity'),
              const SizedBox(height: AppSpacing.xs),
              SizedBox(
                width: double.infinity,
                child: SegmentedButton<HazardSensitivity>(
                  segments: HazardSensitivity.values
                      .map(
                        (h) => ButtonSegment<HazardSensitivity>(
                          value: h,
                          label: Text(h.label),
                        ),
                      )
                      .toList(),
                  selected: {s.hazardSensitivity},
                  onSelectionChanged: (sel) {
                    HapticFeedback.selectionClick();
                    s.setHazardSensitivity(sel.first);
                  },
                  style: _segmentedStyle(),
                ),
              ),
            ],
          ),
        ),

        const _Divider(),

        // ── Live mode cloud policy ──
        _SettingTile(
          semanticLabel:
              'Live mode cloud policy. Currently ${s.liveCloudPolicy.label}. '
              'Local only keeps Live on-device. '
              'Hybrid on scene change allows up to ten cloud calls per session '
              'for richer descriptions when the scene changes.',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _SettingLabel('Live Mode Cloud Calls'),
              const SizedBox(height: AppSpacing.xs),
              SizedBox(
                width: double.infinity,
                child: SegmentedButton<LiveCloudPolicy>(
                  segments: LiveCloudPolicy.values
                      .map(
                        (p) => ButtonSegment<LiveCloudPolicy>(
                          value: p,
                          label: Text(
                            p == LiveCloudPolicy.localOnly ? 'Local' : 'Hybrid',
                          ),
                        ),
                      )
                      .toList(),
                  selected: {s.liveCloudPolicy},
                  onSelectionChanged: (sel) {
                    HapticFeedback.selectionClick();
                    s.setLiveCloudPolicy(sel.first);
                  },
                  style: _segmentedStyle(),
                ),
              ),
              const SizedBox(height: AppSpacing.xs),
              Text(
                s.liveCloudPolicy.description,
                style: TextStyle(
                  fontSize: 13.sp,
                  color: AppColors.textSecondaryOnLight,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // 3. Live Detection
  // ═══════════════════════════════════════════════════════════════════════════

  // ═══════════════════════════════════════════════════════════════════════════
  // 4. Devices
  // ═══════════════════════════════════════════════════════════════════════════

  Widget _buildDevicesSection() {
    final eyeConnected =
        BleService.instance.state == BleConnectionState.connected;
    final caneConnected =
        BleService.instance.caneState == BleConnectionState.connected;

    return _Section(
      title: 'Devices',
      children: [
        _DeviceRow(
          name: 'iCan Eye Camera',
          isConnected: eyeConnected,
          onReconnect: () {
            HapticFeedback.mediumImpact();
            BleService.instance.startScan();
          },
        ),
        const _Divider(),
        _DeviceRow(
          name: 'iCan Cane',
          isConnected: caneConnected,
          onReconnect: () {
            HapticFeedback.mediumImpact();
            BleService.instance.startScanForCane();
          },
        ),
      ],
    );
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // 4. Accessibility
  // ═══════════════════════════════════════════════════════════════════════════

  Widget _buildAccessibilitySection(SettingsProvider s) {
    return _Section(
      title: 'Accessibility',
      children: [
        // ── Font size ──
        _SettingTile(
          semanticLabel: 'Text size. Currently ${s.fontScale.label}.',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _SettingLabel('Text Size'),
              const SizedBox(height: AppSpacing.xs),
              SizedBox(
                width: double.infinity,
                child: SegmentedButton<FontScale>(
                  segments: FontScale.values
                      .map(
                        (f) => ButtonSegment<FontScale>(
                          value: f,
                          label: Text(f.label),
                        ),
                      )
                      .toList(),
                  selected: {s.fontScale},
                  onSelectionChanged: (sel) {
                    HapticFeedback.selectionClick();
                    s.setFontScale(sel.first);
                  },
                  style: _segmentedStyle(),
                ),
              ),
            ],
          ),
        ),

        const _Divider(),

        // ── High contrast ──
        _SwitchTile(
          label: 'High Contrast',
          semanticLabel:
              'High contrast mode. '
              'Currently ${s.highContrast ? "on" : "off"}. '
              '${s.highContrast ? "Using pure black and white for maximum readability." : "Using standard colors."}',
          value: s.highContrast,
          onChanged: (v) {
            HapticFeedback.selectionClick();
            s.setHighContrast(v);
          },
        ),

        const _Divider(),

        // ── Reduce motion ──
        _SwitchTile(
          label: 'Reduce Motion',
          semanticLabel:
              'Reduce motion. '
              'Currently ${s.reduceMotion ? "on" : "off"}. '
              '${s.reduceMotion ? "Animations are disabled." : "Animations are enabled."}',
          value: s.reduceMotion,
          onChanged: (v) {
            HapticFeedback.selectionClick();
            s.setReduceMotion(v);
          },
        ),
      ],
    );
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // 5. About
  // ═══════════════════════════════════════════════════════════════════════════

  Widget _buildAboutSection() {
    return _Section(
      title: 'About',
      children: [
        GestureDetector(
          onLongPress: () {
            HapticFeedback.heavyImpact();
            context.pushNamed('vision-diagnostic');
          },
          child: _SettingTile(
            semanticLabel: 'App version 1.0.0',
            child: Row(
              children: [
                Expanded(child: _SettingLabel('Version')),
                _SettingValue('1.0.0'),
              ],
            ),
          ),
        ),

        const _Divider(),

        _TapTile(
          label: 'Help & Instructions',
          hint: 'Opens help information for using the iCan app',
          onTap: () {
            HapticFeedback.lightImpact();
            context.goNamed('help');
          },
        ),
      ],
    );
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // Shared style
  // ═══════════════════════════════════════════════════════════════════════════

  ButtonStyle _segmentedStyle() {
    return ButtonStyle(
      minimumSize: const WidgetStatePropertyAll(Size(0, 48)),
      foregroundColor: WidgetStatePropertyAll(AppColors.textOnLight),
      textStyle: WidgetStatePropertyAll(
        TextStyle(fontSize: 16.sp, fontWeight: FontWeight.w600),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Section wrapper
// ─────────────────────────────────────────────────────────────────────────────

class _SettingsFeedbackBanner extends StatelessWidget {
  const _SettingsFeedbackBanner({required this.summary});

  final String summary;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      liveRegion: true,
      label: 'Settings feedback. $summary.',
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

class _Section extends StatelessWidget {
  final String title;
  final List<Widget> children;

  const _Section({required this.title, required this.children});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Semantics(
          header: true,
          child: Text(
            title,
            style: TextStyle(
              fontSize: 22.sp,
              fontWeight: FontWeight.bold,
              color: AppColors.textOnLight,
            ),
          ),
        ),
        const SizedBox(height: AppSpacing.xs),
        Container(
          width: double.infinity,
          decoration: BoxDecoration(
            color: AppColors.surfaceCardLight,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: AppColors.borderLight),
          ),
          padding: const EdgeInsets.all(AppSpacing.sm),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: children,
          ),
        ),
      ],
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Setting tile — generic wrapper with outer Semantics
// ─────────────────────────────────────────────────────────────────────────────

class _SettingTile extends StatelessWidget {
  final String semanticLabel;
  final bool semanticSlider;
  final Widget child;

  const _SettingTile({
    required this.semanticLabel,
    this.semanticSlider = false,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: semanticLabel,
      slider: semanticSlider,
      child: ExcludeSemantics(child: child),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Switch tile — toggle with full semantic state
// ─────────────────────────────────────────────────────────────────────────────

class _SwitchTile extends StatelessWidget {
  final String label;
  final String semanticLabel;
  final bool value;
  final ValueChanged<bool> onChanged;

  const _SwitchTile({
    required this.label,
    required this.semanticLabel,
    required this.value,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Semantics(
      toggled: value,
      label: semanticLabel,
      child: GestureDetector(
        onTap: () => onChanged(!value),
        child: Container(
          constraints: const BoxConstraints(minHeight: 56),
          child: Row(
            children: [
              Expanded(
                child: ExcludeSemantics(
                  child: Text(
                    label,
                    style: TextStyle(
                      fontSize: 18.sp,
                      fontWeight: FontWeight.w600,
                      color: AppColors.textOnLight,
                    ),
                  ),
                ),
              ),
              ExcludeSemantics(
                child: Switch(
                  value: value,
                  onChanged: onChanged,
                  activeColor: AppColors.interactive,
                  inactiveThumbColor: AppColors.disabledOnLight,
                  inactiveTrackColor: AppColors.borderLight,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Tap tile — simple row that navigates or triggers an action
// ─────────────────────────────────────────────────────────────────────────────

class _TapTile extends StatelessWidget {
  final String label;
  final String hint;
  final VoidCallback onTap;

  const _TapTile({
    required this.label,
    required this.hint,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: label,
      hint: hint,
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          constraints: const BoxConstraints(minHeight: 56),
          child: Row(
            children: [
              Expanded(
                child: ExcludeSemantics(
                  child: Text(
                    label,
                    style: TextStyle(
                      fontSize: 18.sp,
                      fontWeight: FontWeight.w600,
                      color: AppColors.interactive,
                    ),
                  ),
                ),
              ),
              ExcludeSemantics(
                child: Icon(
                  Icons.chevron_right,
                  color: AppColors.textSecondaryOnLight,
                  size: 24,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Device row
// ─────────────────────────────────────────────────────────────────────────────

class _DeviceRow extends StatelessWidget {
  final String name;
  final bool isConnected;
  final VoidCallback onReconnect;

  const _DeviceRow({
    required this.name,
    required this.isConnected,
    required this.onReconnect,
  });

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: '$name. ${isConnected ? "Connected" : "Not connected"}.',
      child: Container(
        constraints: const BoxConstraints(minHeight: 64),
        child: ExcludeSemantics(
          child: Row(
            children: [
              if (isConnected)
                Icon(Icons.check_circle, color: AppColors.success, size: 24)
              else
                Icon(
                  Icons.circle_outlined,
                  color: AppColors.disabledOnLight,
                  size: 24,
                ),
              const SizedBox(width: AppSpacing.xs),

              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      name,
                      style: TextStyle(
                        fontSize: 18.sp,
                        fontWeight: FontWeight.w600,
                        color: AppColors.textOnLight,
                      ),
                    ),
                    Text(
                      isConnected ? 'Connected' : 'Not connected',
                      style: TextStyle(
                        fontSize: 14.sp,
                        color: isConnected
                            ? AppColors.success
                            : AppColors.textSecondaryOnLight,
                      ),
                    ),
                  ],
                ),
              ),

              if (!isConnected)
                Semantics(
                  button: true,
                  label: 'Reconnect $name',
                  hint: 'Searches for this device to reconnect',
                  child: GestureDetector(
                    onTap: onReconnect,
                    child: Container(
                      constraints: const BoxConstraints(
                        minWidth: 88,
                        minHeight: 48,
                      ),
                      decoration: BoxDecoration(
                        color: AppColors.interactive,
                        borderRadius: BorderRadius.circular(10),
                      ),
                      alignment: Alignment.center,
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      child: Text(
                        'Reconnect',
                        style: TextStyle(
                          fontSize: 14.sp,
                          fontWeight: FontWeight.w600,
                          color: AppColors.textOnDark,
                        ),
                      ),
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

// ─────────────────────────────────────────────────────────────────────────────
// Shared small widgets
// ─────────────────────────────────────────────────────────────────────────────

class _SettingLabel extends StatelessWidget {
  final String text;
  const _SettingLabel(this.text);

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      style: TextStyle(
        fontSize: 18.sp,
        fontWeight: FontWeight.w600,
        color: AppColors.textOnLight,
      ),
    );
  }
}

class _SettingValue extends StatelessWidget {
  final String text;
  const _SettingValue(this.text);

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      style: TextStyle(fontSize: 16.sp, color: AppColors.textSecondaryOnLight),
    );
  }
}

class _Divider extends StatelessWidget {
  const _Divider();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: AppSpacing.xs),
      child: Divider(height: 1, color: AppColors.borderLight),
    );
  }
}

class _SliderLabels extends StatelessWidget {
  final String left;
  final String right;
  const _SliderLabels({required this.left, required this.right});

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(
          left,
          style: TextStyle(
            fontSize: 13.sp,
            color: AppColors.textSecondaryOnLight,
          ),
        ),
        Text(
          right,
          style: TextStyle(
            fontSize: 13.sp,
            color: AppColors.textSecondaryOnLight,
          ),
        ),
      ],
    );
  }
}

class _AccessibleSlider extends StatelessWidget {
  final double value;
  final double min;
  final double max;
  final int divisions;
  final ValueChanged<double> onChanged;

  const _AccessibleSlider({
    required this.value,
    required this.min,
    required this.max,
    required this.divisions,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return SliderTheme(
      data: SliderThemeData(
        activeTrackColor: AppColors.interactive,
        inactiveTrackColor: AppColors.borderLight,
        thumbColor: AppColors.interactive,
        overlayColor: AppColors.interactive.withAlpha(40),
        thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 14),
        trackHeight: 6,
      ),
      child: Slider(
        value: value,
        min: min,
        max: max,
        divisions: divisions,
        onChanged: onChanged,
      ),
    );
  }
}
