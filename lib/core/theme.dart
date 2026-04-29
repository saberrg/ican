import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';

// ─────────────────────────────────────────────────────────────────────────────
// AppColors — named color constants for the iCan design system.
//
// WCAG AAA contrast ratios verified for all text/background pairings.
// Semantic status colors MUST always be paired with a text or icon label —
// never rely on color alone (WCAG 1.4.1).
// ─────────────────────────────────────────────────────────────────────────────

class AppColors {
  AppColors._();

  // ── Primary backgrounds ──
  static const Color backgroundLight = Color(0xFFFFFFFF);
  static const Color backgroundDark = Color(0xFF000000);

  // ── Primary text — 21:1 contrast on respective backgrounds ──
  static const Color textOnLight = Color(0xFF000000);
  static const Color textOnDark = Color(0xFFFFFFFF);

  // ── Secondary text — ≥7:1 (WCAG AAA) on respective backgrounds ──
  // SemanticLabel: use for supporting copy, timestamps, hints.
  static const Color textSecondaryOnLight = Color(0xFF595959); // 7.0:1 on white
  static const Color textSecondaryOnDark = Color(0xFFAAAAAA); // 9.0:1 on black

  // ── Interactive accent — ONLY for tappable/focusable elements ──
  // ACCESSIBILITY NOTE: #0057D9 achieves 6.5:1 on white — AAA at ≥18sp bold
  // (all interactive text in this system is labelLarge: 20sp w600).
  // On dark backgrounds, use interactiveOnDark for readable text links.
  static const Color interactive = Color(0xFF0057D9);
  static const Color interactiveOnDark = Color(0xFF6EB5FF); // 9.8:1 on black

  // ── Semantic status — never standalone; always pair with text/icon ──
  static const Color success = Color(0xFF2E7D32);
  static const Color error = Color(0xFFC62828);
  static const Color warning = Color(0xFFE65100);

  // ── Card surfaces — slight lift from pure background for sighted users ──
  // Scaffold backgrounds remain pure black/white; cards use these with a
  // visible border so structure is conveyed without relying on shade alone.
  static const Color surfaceCardLight = Color(0xFFF5F5F5);
  static const Color surfaceCardDark = Color(0xFF1A1A1A);

  // ── Borders — non-color-dependent card/group delineation ──
  static const Color borderLight = Color(0xFFCCCCCC);
  static const Color borderDark = Color(0xFF444444);

  // ── Disabled state ──
  static const Color disabledOnLight = Color(0xFF757575);
  static const Color disabledOnDark = Color(0xFF9E9E9E);

  // ── Focus indicator ──
  static const Color focusRing = interactive;
  static const Color focusRingOnDark = interactiveOnDark;

  // ── Derived ──
  static const Color interactiveTrack = Color(0x660057D9); // 40% interactive
}

// ─────────────────────────────────────────────────────────────────────────────
// AppSpacing — consistent spacing scale.
// ─────────────────────────────────────────────────────────────────────────────

class AppSpacing {
  AppSpacing._();

  static const double xs = 8;
  static const double sm = 16;
  static const double md = 24;
  static const double lg = 32;
  static const double xl = 48;
}

// ─────────────────────────────────────────────────────────────────────────────
// AppTextStyles — sp-scaled via flutter_screenutil.
//
// Call only after ScreenUtil.init(). Minimum body text: 18sp.
// These return unstyled-for-color TextStyles — the ThemeData TextTheme
// applies the correct foreground color per brightness mode.
// ─────────────────────────────────────────────────────────────────────────────

class AppTextStyles {
  AppTextStyles._();

  static TextStyle get displayLarge => TextStyle(
    fontSize: 36.sp,
    fontWeight: FontWeight.bold,
    letterSpacing: 0,
    height: 1.2,
  );

  static TextStyle get headlineMedium =>
      TextStyle(fontSize: 28.sp, fontWeight: FontWeight.w600, height: 1.3);

  static TextStyle get bodyLarge =>
      TextStyle(fontSize: 20.sp, fontWeight: FontWeight.normal, height: 1.5);

  static TextStyle get bodyMedium =>
      TextStyle(fontSize: 18.sp, fontWeight: FontWeight.normal, height: 1.5);

  static TextStyle get labelLarge =>
      TextStyle(fontSize: 20.sp, fontWeight: FontWeight.w600, height: 1.2);
}

// ─────────────────────────────────────────────────────────────────────────────
// AppAccessibility
// ─────────────────────────────────────────────────────────────────────────────

class AppAccessibility {
  AppAccessibility._();

  /// Returns true when the user has enabled "Reduce Motion" in system settings.
  /// Wrap ALL animations in a check:
  /// ```dart
  /// if (!AppAccessibility.reduceMotion(context)) { /* animate */ }
  /// ```
  static bool reduceMotion(BuildContext context) =>
      MediaQuery.of(context).disableAnimations;
}

// ─────────────────────────────────────────────────────────────────────────────
// ICanTheme — light and dark ThemeData.
//
// Requires flutter_screenutil: wrap MaterialApp in ScreenUtilInit so that
// .sp text sizing resolves before theme construction.
//
// Usage in main.dart:
//   ScreenUtilInit(
//     designSize: const Size(375, 812),
//     builder: (_, __) => MaterialApp(
//       theme: ICanTheme.lightTheme,
//       darkTheme: ICanTheme.darkTheme,
//       ...
//     ),
//   )
// ─────────────────────────────────────────────────────────────────────────────

class ICanTheme {
  ICanTheme._();

  // ── Legacy color aliases ──
  // Keeps caretaker_dashboard_screen.dart compiling unchanged.
  // New code should reference AppColors directly.
  static const Color primaryBlue = AppColors.interactive;
  static const Color accentOrange = Color(0xFFFF8F00);
  static const Color surfaceDark = AppColors.surfaceCardDark;
  static const Color surfaceCard = AppColors.surfaceCardDark;
  static const Color textPrimary = AppColors.textOnDark;
  static const Color textSecondary = Color(0xFFB0BEC5);
  static const Color success = Color(0xFF66BB6A);
  static const Color error = Color(0xFFEF5350);

  // ── Shared layout constants ──
  static const _radius = 12.0;
  static const _buttonHeight = 56.0;
  static const _focusWidth = 3.0;
  static const _minTouch = 48.0; // WCAG 2.5.5 minimum target size

  // ═══════════════════════════════════════════════════════════════════════════
  // LIGHT THEME — white background (#FFFFFF), black text (#000000)
  // ═══════════════════════════════════════════════════════════════════════════

  static ThemeData get lightTheme {
    final textTheme = TextTheme(
      displayLarge: AppTextStyles.displayLarge.copyWith(
        color: AppColors.textOnLight,
      ),
      headlineMedium: AppTextStyles.headlineMedium.copyWith(
        color: AppColors.textOnLight,
      ),
      bodyLarge: AppTextStyles.bodyLarge.copyWith(color: AppColors.textOnLight),
      bodyMedium: AppTextStyles.bodyMedium.copyWith(
        color: AppColors.textSecondaryOnLight,
      ),
      labelLarge: AppTextStyles.labelLarge.copyWith(
        color: AppColors.textOnLight,
      ),
    );

    return ThemeData(
      useMaterial3: true,
      brightness: Brightness.light,
      scaffoldBackgroundColor: AppColors.backgroundLight,
      colorScheme: const ColorScheme.light(
        primary: AppColors.interactive,
        onPrimary: AppColors.textOnDark,
        secondary: AppColors.interactive,
        onSecondary: AppColors.textOnDark,
        surface: AppColors.backgroundLight,
        onSurface: AppColors.textOnLight,
        error: AppColors.error,
        onError: AppColors.textOnDark,
      ),
      textTheme: textTheme,

      // ── Elevated Button ──
      // SemanticLabel: callers MUST wrap in Semantics(button: true, label: ...)
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ButtonStyle(
          backgroundColor: WidgetStateProperty.resolveWith((states) {
            if (states.contains(WidgetState.disabled)) {
              return AppColors.disabledOnLight;
            }
            return AppColors.interactive;
          }),
          foregroundColor: const WidgetStatePropertyAll(AppColors.textOnDark),
          minimumSize: const WidgetStatePropertyAll(
            Size(double.infinity, _buttonHeight),
          ),
          textStyle: WidgetStatePropertyAll(AppTextStyles.labelLarge),
          shape: WidgetStateProperty.resolveWith((states) {
            if (states.contains(WidgetState.focused)) {
              return RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(_radius),
                side: const BorderSide(
                  color: AppColors.focusRing,
                  width: _focusWidth,
                ),
              );
            }
            return RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(_radius),
            );
          }),
          padding: const WidgetStatePropertyAll(
            EdgeInsets.symmetric(
              horizontal: AppSpacing.md,
              vertical: AppSpacing.sm,
            ),
          ),
        ),
      ),

      // ── Outlined Button ──
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: ButtonStyle(
          foregroundColor: const WidgetStatePropertyAll(AppColors.interactive),
          minimumSize: const WidgetStatePropertyAll(
            Size(double.infinity, _buttonHeight),
          ),
          textStyle: WidgetStatePropertyAll(AppTextStyles.labelLarge),
          side: WidgetStateProperty.resolveWith((states) {
            if (states.contains(WidgetState.focused)) {
              return const BorderSide(
                color: AppColors.focusRing,
                width: _focusWidth,
              );
            }
            return const BorderSide(color: AppColors.interactive, width: 2);
          }),
          shape: WidgetStatePropertyAll(
            RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(_radius),
            ),
          ),
          padding: const WidgetStatePropertyAll(
            EdgeInsets.symmetric(
              horizontal: AppSpacing.md,
              vertical: AppSpacing.sm,
            ),
          ),
        ),
      ),

      // ── Text Button ──
      textButtonTheme: TextButtonThemeData(
        style: ButtonStyle(
          foregroundColor: const WidgetStatePropertyAll(AppColors.interactive),
          minimumSize: const WidgetStatePropertyAll(Size(_minTouch, _minTouch)),
          textStyle: WidgetStatePropertyAll(AppTextStyles.labelLarge),
          shape: WidgetStateProperty.resolveWith((states) {
            if (states.contains(WidgetState.focused)) {
              return RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(_radius),
                side: const BorderSide(
                  color: AppColors.focusRing,
                  width: _focusWidth,
                ),
              );
            }
            return RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(_radius),
            );
          }),
        ),
      ),

      // ── Icon Button ──
      iconButtonTheme: IconButtonThemeData(
        style: ButtonStyle(
          minimumSize: const WidgetStatePropertyAll(Size(_minTouch, _minTouch)),
          foregroundColor: const WidgetStatePropertyAll(AppColors.interactive),
          shape: WidgetStateProperty.resolveWith((states) {
            if (states.contains(WidgetState.focused)) {
              return RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(_radius),
                side: const BorderSide(
                  color: AppColors.focusRing,
                  width: _focusWidth,
                ),
              );
            }
            return RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(_radius),
            );
          }),
        ),
      ),

      // ── AppBar ──
      appBarTheme: AppBarTheme(
        backgroundColor: AppColors.backgroundLight,
        foregroundColor: AppColors.textOnLight,
        elevation: 0,
        scrolledUnderElevation: 0,
        systemOverlayStyle: SystemUiOverlayStyle.dark,
        titleTextStyle: AppTextStyles.headlineMedium.copyWith(
          color: AppColors.textOnLight,
        ),
      ),

      // ── Card ──
      cardTheme: CardThemeData(
        color: AppColors.surfaceCardLight,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(_radius),
          side: const BorderSide(color: AppColors.borderLight),
        ),
        margin: const EdgeInsets.symmetric(vertical: AppSpacing.xs),
      ),

      // ── Divider ──
      dividerTheme: const DividerThemeData(
        color: AppColors.borderLight,
        thickness: 1,
        space: AppSpacing.md,
      ),

      // ── Input fields ──
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: AppColors.backgroundLight,
        contentPadding: const EdgeInsets.all(AppSpacing.sm),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(_radius),
          borderSide: const BorderSide(color: AppColors.borderLight, width: 2),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(_radius),
          borderSide: const BorderSide(
            color: AppColors.focusRing,
            width: _focusWidth,
          ),
        ),
        errorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(_radius),
          borderSide: const BorderSide(color: AppColors.error, width: 2),
        ),
        labelStyle: AppTextStyles.bodyMedium.copyWith(
          color: AppColors.textSecondaryOnLight,
        ),
        hintStyle: AppTextStyles.bodyMedium.copyWith(
          color: AppColors.disabledOnLight,
        ),
      ),

      // ── Switch ──
      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) {
            return AppColors.interactive;
          }
          return AppColors.disabledOnLight;
        }),
        trackColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) {
            return AppColors.interactiveTrack;
          }
          return AppColors.borderLight;
        }),
      ),

      // ── Checkbox ──
      checkboxTheme: CheckboxThemeData(
        fillColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) {
            return AppColors.interactive;
          }
          return AppColors.backgroundLight;
        }),
        checkColor: const WidgetStatePropertyAll(AppColors.textOnDark),
        side: const BorderSide(color: AppColors.textOnLight, width: 2),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
      ),

      // ── Tooltip ──
      tooltipTheme: TooltipThemeData(
        textStyle: AppTextStyles.bodyMedium.copyWith(
          color: AppColors.textOnDark,
        ),
        decoration: BoxDecoration(
          color: AppColors.backgroundDark,
          borderRadius: BorderRadius.circular(8),
        ),
      ),

      // ── SnackBar ──
      snackBarTheme: SnackBarThemeData(
        backgroundColor: AppColors.backgroundDark,
        contentTextStyle: AppTextStyles.bodyMedium.copyWith(
          color: AppColors.textOnDark,
        ),
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(_radius),
        ),
      ),
    );
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // DARK THEME — black background (#000000), white text (#FFFFFF)
  // ═══════════════════════════════════════════════════════════════════════════

  static ThemeData get darkTheme {
    final textTheme = TextTheme(
      displayLarge: AppTextStyles.displayLarge.copyWith(
        color: AppColors.textOnDark,
      ),
      headlineMedium: AppTextStyles.headlineMedium.copyWith(
        color: AppColors.textOnDark,
      ),
      bodyLarge: AppTextStyles.bodyLarge.copyWith(color: AppColors.textOnDark),
      bodyMedium: AppTextStyles.bodyMedium.copyWith(
        color: AppColors.textSecondaryOnDark,
      ),
      labelLarge: AppTextStyles.labelLarge.copyWith(
        color: AppColors.textOnDark,
      ),
    );

    return ThemeData(
      useMaterial3: true,
      brightness: Brightness.dark,
      scaffoldBackgroundColor: AppColors.backgroundDark,
      colorScheme: const ColorScheme.dark(
        primary: AppColors.interactive,
        onPrimary: AppColors.textOnDark,
        secondary: AppColors.interactiveOnDark,
        onSecondary: AppColors.backgroundDark,
        surface: AppColors.backgroundDark,
        onSurface: AppColors.textOnDark,
        error: AppColors.error,
        onError: AppColors.textOnDark,
      ),
      textTheme: textTheme,

      // ── Elevated Button ──
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ButtonStyle(
          backgroundColor: WidgetStateProperty.resolveWith((states) {
            if (states.contains(WidgetState.disabled)) {
              return AppColors.disabledOnDark;
            }
            return AppColors.interactive;
          }),
          foregroundColor: const WidgetStatePropertyAll(AppColors.textOnDark),
          minimumSize: const WidgetStatePropertyAll(
            Size(double.infinity, _buttonHeight),
          ),
          textStyle: WidgetStatePropertyAll(AppTextStyles.labelLarge),
          shape: WidgetStateProperty.resolveWith((states) {
            if (states.contains(WidgetState.focused)) {
              return RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(_radius),
                side: const BorderSide(
                  color: AppColors.focusRingOnDark,
                  width: _focusWidth,
                ),
              );
            }
            return RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(_radius),
            );
          }),
          padding: const WidgetStatePropertyAll(
            EdgeInsets.symmetric(
              horizontal: AppSpacing.md,
              vertical: AppSpacing.sm,
            ),
          ),
        ),
      ),

      // ── Outlined Button ──
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: ButtonStyle(
          foregroundColor: const WidgetStatePropertyAll(
            AppColors.interactiveOnDark,
          ),
          minimumSize: const WidgetStatePropertyAll(
            Size(double.infinity, _buttonHeight),
          ),
          textStyle: WidgetStatePropertyAll(AppTextStyles.labelLarge),
          side: WidgetStateProperty.resolveWith((states) {
            if (states.contains(WidgetState.focused)) {
              return const BorderSide(
                color: AppColors.focusRingOnDark,
                width: _focusWidth,
              );
            }
            return const BorderSide(
              color: AppColors.interactiveOnDark,
              width: 2,
            );
          }),
          shape: WidgetStatePropertyAll(
            RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(_radius),
            ),
          ),
          padding: const WidgetStatePropertyAll(
            EdgeInsets.symmetric(
              horizontal: AppSpacing.md,
              vertical: AppSpacing.sm,
            ),
          ),
        ),
      ),

      // ── Text Button ──
      textButtonTheme: TextButtonThemeData(
        style: ButtonStyle(
          foregroundColor: const WidgetStatePropertyAll(
            AppColors.interactiveOnDark,
          ),
          minimumSize: const WidgetStatePropertyAll(Size(_minTouch, _minTouch)),
          textStyle: WidgetStatePropertyAll(AppTextStyles.labelLarge),
          shape: WidgetStateProperty.resolveWith((states) {
            if (states.contains(WidgetState.focused)) {
              return RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(_radius),
                side: const BorderSide(
                  color: AppColors.focusRingOnDark,
                  width: _focusWidth,
                ),
              );
            }
            return RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(_radius),
            );
          }),
        ),
      ),

      // ── Icon Button ──
      iconButtonTheme: IconButtonThemeData(
        style: ButtonStyle(
          minimumSize: const WidgetStatePropertyAll(Size(_minTouch, _minTouch)),
          foregroundColor: const WidgetStatePropertyAll(
            AppColors.interactiveOnDark,
          ),
          shape: WidgetStateProperty.resolveWith((states) {
            if (states.contains(WidgetState.focused)) {
              return RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(_radius),
                side: const BorderSide(
                  color: AppColors.focusRingOnDark,
                  width: _focusWidth,
                ),
              );
            }
            return RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(_radius),
            );
          }),
        ),
      ),

      // ── AppBar ──
      appBarTheme: AppBarTheme(
        backgroundColor: AppColors.backgroundDark,
        foregroundColor: AppColors.textOnDark,
        elevation: 0,
        scrolledUnderElevation: 0,
        systemOverlayStyle: SystemUiOverlayStyle.light,
        titleTextStyle: AppTextStyles.headlineMedium.copyWith(
          color: AppColors.textOnDark,
        ),
      ),

      // ── Card ──
      cardTheme: CardThemeData(
        color: AppColors.surfaceCardDark,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(_radius),
          side: const BorderSide(color: AppColors.borderDark),
        ),
        margin: const EdgeInsets.symmetric(vertical: AppSpacing.xs),
      ),

      // ── Divider ──
      dividerTheme: const DividerThemeData(
        color: AppColors.borderDark,
        thickness: 1,
        space: AppSpacing.md,
      ),

      // ── Input fields ──
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: AppColors.backgroundDark,
        contentPadding: const EdgeInsets.all(AppSpacing.sm),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(_radius),
          borderSide: const BorderSide(color: AppColors.borderDark, width: 2),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(_radius),
          borderSide: const BorderSide(
            color: AppColors.focusRingOnDark,
            width: _focusWidth,
          ),
        ),
        errorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(_radius),
          borderSide: const BorderSide(color: AppColors.error, width: 2),
        ),
        labelStyle: AppTextStyles.bodyMedium.copyWith(
          color: AppColors.textSecondaryOnDark,
        ),
        hintStyle: AppTextStyles.bodyMedium.copyWith(
          color: AppColors.disabledOnDark,
        ),
      ),

      // ── Switch ──
      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) {
            return AppColors.interactiveOnDark;
          }
          return AppColors.disabledOnDark;
        }),
        trackColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) {
            return AppColors.interactiveTrack;
          }
          return AppColors.borderDark;
        }),
      ),

      // ── Checkbox ──
      checkboxTheme: CheckboxThemeData(
        fillColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) {
            return AppColors.interactiveOnDark;
          }
          return AppColors.backgroundDark;
        }),
        checkColor: const WidgetStatePropertyAll(AppColors.backgroundDark),
        side: const BorderSide(color: AppColors.textOnDark, width: 2),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
      ),

      // ── Tooltip ──
      tooltipTheme: TooltipThemeData(
        textStyle: AppTextStyles.bodyMedium.copyWith(
          color: AppColors.textOnLight,
        ),
        decoration: BoxDecoration(
          color: AppColors.backgroundLight,
          borderRadius: BorderRadius.circular(8),
        ),
      ),

      // ── SnackBar ──
      snackBarTheme: SnackBarThemeData(
        backgroundColor: AppColors.backgroundLight,
        contentTextStyle: AppTextStyles.bodyMedium.copyWith(
          color: AppColors.textOnLight,
        ),
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(_radius),
        ),
      ),
    );
  }
}
