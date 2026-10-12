import 'package:flutter/material.dart';

class AppTheme {
  static const Color corporateBlue = Color(0xFF0D47A1);
  static const Color skyBlue = Color(0xFF1976D2);
  static const Color lightBlue = Color(0xFFBBDEFB);
  static const Color accentBlue = Color(0xFF42A5F5);
  static const Color cleanWhite = Color(0xFFFFFFFF);
  static const Color offWhite = Color(0xFFF5F8FF);
  static const Color cardBackground = Color(0xFFFFFFFF);

  static const Color statusOK = Color(0xFF2E7D32);
  static const Color statusWarning = Color(0xFFF57F17);
  static const Color statusCritical = Color(0xFFC62828);
  static const Color statusUnknown = Color(0xFF757575);

  static const Color darkBg = Color(0xFF0B1220);
  static const Color darkSurface = Color(0xFF121A2B);
  static const Color darkCard = Color(0xFF182338);

  static ThemeData get light => _build(Brightness.light);
  static ThemeData get dark => _build(Brightness.dark);

  // Backward-compatible alias used across existing screens
  static ThemeData get theme => light;

  static ThemeData _build(Brightness brightness) {
    final isDark = brightness == Brightness.dark;
    final scheme = ColorScheme.fromSeed(
      seedColor: corporateBlue,
      brightness: brightness,
      primary: isDark ? accentBlue : corporateBlue,
      secondary: skyBlue,
      surface: isDark ? darkSurface : offWhite,
      onPrimary: cleanWhite,
      onSurface: isDark ? const Color(0xFFE8EEF8) : const Color(0xFF1A237E),
    );

    return ThemeData(
      useMaterial3: true,
      brightness: brightness,
      colorScheme: scheme,
      scaffoldBackgroundColor: isDark ? darkBg : offWhite,
      appBarTheme: AppBarTheme(
        backgroundColor: isDark ? darkCard : corporateBlue,
        foregroundColor: cleanWhite,
        elevation: 0,
        centerTitle: false,
        titleTextStyle: const TextStyle(
          fontFamily: 'Roboto',
          fontSize: 20,
          fontWeight: FontWeight.w600,
          color: cleanWhite,
          letterSpacing: 0.2,
        ),
      ),
      cardTheme: CardThemeData(
        color: isDark ? darkCard : cardBackground,
        elevation: 2,
        shadowColor: corporateBlue.withValues(alpha: isDark ? 0.35 : 0.12),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      ),
      bottomNavigationBarTheme: BottomNavigationBarThemeData(
        backgroundColor: isDark ? darkCard : cleanWhite,
        selectedItemColor: isDark ? accentBlue : corporateBlue,
        unselectedItemColor: isDark ? const Color(0xFF90A4AE) : const Color(0xFF90A4AE),
        selectedLabelStyle: const TextStyle(fontWeight: FontWeight.w600, fontSize: 11),
        elevation: 16,
        type: BottomNavigationBarType.fixed,
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: isDark ? accentBlue : corporateBlue,
          foregroundColor: cleanWhite,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
          textStyle: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: isDark ? const Color(0xFF0F1726) : Colors.white,
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(14)),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide(color: scheme.outlineVariant),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide(color: scheme.primary, width: 1.6),
        ),
      ),
    );
  }
}
