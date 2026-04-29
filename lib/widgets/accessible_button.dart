// Usage:
//
//   AccessibleButton(
//     label: 'Start Navigation',
//     hint: 'Begins turn-by-turn walking directions to your destination',
//     onPressed: () => _startNav(),
//   )
//
//   AccessibleButton(
//     label: 'Describe Scene',
//     subtitle: 'Uses camera to identify surroundings',
//     hint: 'Takes a photo and reads a description aloud',
//     onPressed: () => _describeScene(),
//     onLongPress: () => _describeSceneDetailed(),
//     longPressHint: 'Takes a photo and reads a detailed description aloud',
//   )
//
//   AccessibleButton(
//     label: 'Connect Cane',
//     hint: 'Scans for nearby iCan Cane device over Bluetooth',
//     onPressed: null, // renders disabled state
//   )

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';

import '../core/theme.dart';

class AccessibleButton extends StatefulWidget {
  final String label;
  final String hint;
  final String? subtitle;
  final VoidCallback? onPressed;
  final VoidCallback? onLongPress;
  final String? longPressHint;

  const AccessibleButton({
    super.key,
    required this.label,
    required this.hint,
    this.subtitle,
    this.onPressed,
    this.onLongPress,
    this.longPressHint,
  });

  @override
  State<AccessibleButton> createState() => _AccessibleButtonState();
}

class _AccessibleButtonState extends State<AccessibleButton> {
  bool _pressed = false;

  bool get _enabled => widget.onPressed != null;

  void _handleTapDown(TapDownDetails _) {
    if (!_enabled) return;
    setState(() => _pressed = true);
  }

  void _handleTapUp(TapUpDetails _) {
    if (!_enabled) return;
    setState(() => _pressed = false);
  }

  void _handleTapCancel() {
    if (!_enabled) return;
    setState(() => _pressed = false);
  }

  void _handleTap() {
    if (!_enabled) return;
    HapticFeedback.mediumImpact();
    widget.onPressed!();
  }

  void _handleLongPress() {
    if (!_enabled || widget.onLongPress == null) return;
    HapticFeedback.heavyImpact();
    widget.onLongPress!();
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    // ── Resolve colors per state ──
    final Color bgBase = _enabled ? AppColors.interactive : _disabledBg(isDark);
    final Color bg = (_pressed && _enabled) ? _darken(bgBase, 0.15) : bgBase;
    final Color fg = _enabled ? AppColors.textOnDark : _disabledFg(isDark);
    final Color focusRing = isDark
        ? AppColors.focusRingOnDark
        : AppColors.focusRing;

    // ── Build semantic hint ──
    // When both tap and long-press exist, concatenate both hints so
    // VoiceOver / TalkBack announces the full action set.
    String semanticHint = widget.hint;
    if (widget.onLongPress != null && widget.longPressHint != null) {
      semanticHint = '${widget.hint}. Long press: ${widget.longPressHint}';
    }

    // SemanticLabel: The label announces the button's name. The hint
    // tells the user what will happen on activation. Both are needed
    // because screen readers announce label, then hint, giving the
    // user a name ("Start Navigation") and an expectation ("Begins
    // turn-by-turn walking directions").
    return Semantics(
      button: true,
      enabled: _enabled,
      label: _enabled ? widget.label : '${widget.label}, unavailable',
      hint: semanticHint,
      child: Focus(
        child: Builder(
          builder: (context) {
            final focused = Focus.of(context).hasFocus;

            return GestureDetector(
              onTapDown: _handleTapDown,
              onTapUp: _handleTapUp,
              onTapCancel: _handleTapCancel,
              onTap: _handleTap,
              onLongPress: widget.onLongPress != null ? _handleLongPress : null,
              child: AnimatedContainer(
                duration: AppAccessibility.reduceMotion(context)
                    ? Duration.zero
                    : const Duration(milliseconds: 100),
                constraints: const BoxConstraints(
                  minHeight: 64,
                  minWidth: double.infinity,
                ),
                decoration: BoxDecoration(
                  color: bg,
                  borderRadius: BorderRadius.circular(12),
                  border: focused
                      ? Border.all(color: focusRing, width: 3)
                      : null,
                ),
                padding: const EdgeInsets.symmetric(
                  horizontal: AppSpacing.md,
                  vertical: AppSpacing.sm,
                ),
                child: Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      _buildLabel(fg),
                      if (widget.subtitle != null) ...[
                        const SizedBox(height: 4),
                        _buildSubtitle(fg, isDark),
                      ],
                    ],
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  Widget _buildLabel(Color fg) {
    // ACCESSIBILITY NOTE: disabled state uses a strikethrough decoration
    // plus the text "unavailable" in semantics — not just dimmed color —
    // so the state is perceivable through both vision and screen reader.
    return ExcludeSemantics(
      child: Text(
        widget.label,
        textAlign: TextAlign.center,
        style: TextStyle(
          fontSize: 20.sp,
          fontWeight: FontWeight.w600,
          color: fg,
          decoration: TextDecoration.none,
          decorationColor: fg,
          decorationThickness: 2,
        ),
      ),
    );
  }

  Widget _buildSubtitle(Color fg, bool isDark) {
    final Color subtitleColor = _enabled
        ? (isDark
              ? AppColors.textSecondaryOnDark
              : AppColors.textSecondaryOnLight)
        : fg;

    return ExcludeSemantics(
      child: Text(
        widget.subtitle!,
        textAlign: TextAlign.center,
        style: TextStyle(
          fontSize: 14.sp,
          fontWeight: FontWeight.normal,
          color: subtitleColor,
          decoration: TextDecoration.none,
          decorationColor: subtitleColor,
          decorationThickness: 2,
        ),
      ),
    );
  }

  static Color _disabledBg(bool isDark) =>
      isDark ? const Color(0xFF2A2A2A) : const Color(0xFFE0E0E0);

  static Color _disabledFg(bool isDark) =>
      isDark ? AppColors.textOnDark : AppColors.textOnLight;

  static Color _darken(Color color, double amount) {
    final hsl = HSLColor.fromColor(color);
    return hsl
        .withLightness((hsl.lightness - amount).clamp(0.0, 1.0))
        .toColor();
  }
}
