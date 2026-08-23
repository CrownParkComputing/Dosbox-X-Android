// Colors and sizing shared with ViceMultiplatform's workbench, so the two
// front ends read as siblings rather than unrelated apps.
//
// Flutter's logical pixels are the same concept as Android's dp, so every dp
// value carried over from the Java sources is used here unconverted.
import 'package:flutter/material.dart';

class RetroDosboxColors {
  RetroDosboxColors._();

  static const Color rootBackground = Color(0xFF050607);

  static const Color panelFill = Color(0xCC0B0D10);
  static const Color panelStroke = Color(0x44FFFFFF);

  static const Color selectedFill = Color(0xFF24292E);
  static const Color selectedStroke = Color(0xFF444D56);

  static const Color sidebarLabelIdle = Color(0xFF8C939D);
  static const Color sidebarLabelSelected = Colors.white;

  static const Color accentTeal = Color(0xFF00FFCC);
  static const Color accentBlue = Color(0xFF2D8CFF);

  /// DOS-flavoured accent, distinct from the VICE app's C64 blue: the amber of
  /// a monochrome PC monitor. Used for the shell/terminal chrome.
  static const Color accentAmber = Color(0xFFFFB000);

  static const Color cardFill = Color(0xFF191D22);
  static const Color cardStroke = Color(0xFF353B44);
  static const Color coverFill = Color(0xFF262C34);
  static const Color coverStroke = Color(0xFF404853);

  static const Color textMuted = Color(0xFF9AA3AF);
  static const Color textMuted2 = Color(0xFFBAC2CC);

  static const Color warning = Color(0xFFE5A00D);
  static const Color danger = Color(0xFFE53935);
}

class RetroDosboxMetrics {
  RetroDosboxMetrics._();

  /// Clamp bounds for the sidebar, whose width is measured from its widest
  /// label rather than fixed -- a flat value left a dead strip beside every
  /// label on wide devices.
  /// 128, not 118: the floor has to clear the widest label the rail actually
  /// carries. "Compliance" needs about 122pt once the icon column and side
  /// padding are counted, so at 118 the longest entry rendered as "Compl..."
  /// on every screen of every phone -- and so in every store screenshot --
  /// while looking like a deliberate width rather than a fault.
  static const double sidebarMinWidth = 128.0;

  /// Never below [sidebarMinWidth], because this is a clamp's upper bound.
  ///
  /// A quarter of a narrow screen is less than the minimum - under about
  /// 472dp - and clamp(min, max) throws outright when max < min. That threw
  /// inside Sidebar.build, which takes the whole workbench subtree with it:
  /// the symptom was a panel that never drew while the emulator ran perfectly,
  /// sound and all, because the failure was in the launcher's UI rather than
  /// anywhere near the emulator.
  static double sidebarMaxWidth(double screenWidth) {
    // A third, not a quarter. The rail sizes itself to its widest label, and a
    // quarter of any iPhone is below what "Compliance" needs, so the cap was
    // binding on all of them. A third still leaves two thirds for content, and
    // the 190 ceiling keeps a wide tablet from growing a needlessly fat rail.
    final share = screenWidth / 3;
    final capped = share < 190.0 ? share : 190.0;
    return capped < sidebarMinWidth ? sidebarMinWidth : capped;
  }

  /// A floor, not a fixed height: the row grows with the platform text scale,
  /// which is what stops labels looking cramped on handheld devices that
  /// default to 1.35x.
  static const double sidebarButtonHeight = 36.0;
  static const double sidebarButtonTextSize = 13.0;
  static const double sidebarButtonBottomMargin = 4.0;
  static const double sidebarButtonSidePadding = 10.0;
  static const double sidebarButtonVerticalPadding = 8.0;

  static const double rootPadding = 12.0;
  static const double sideNavPadding = 6.0;
  static const double contentLeftMargin = 12.0;

  static const double mediaCardWidth = 120.0;
  static const double mediaCardHeight = 178.0;
  static const double mediaCoverHeight = 120.0;

  /// Card plus margins, for column math in the library grid.
  static const double mediaCardCell = 126.0;

  static double quickSettingsPanelWidth(double screenWidth) {
    final pct = screenWidth * 0.45;
    return pct < 340.0 ? pct : 340.0;
  }
}

/// Monospace styling for the places this app deliberately looks like a DOS
/// prompt (setup wizard, status lines, config help text).
class RetroDosboxTextStyles {
  RetroDosboxTextStyles._();

  static const TextStyle terminal = TextStyle(
    fontFamily: 'monospace',
    fontFamilyFallback: ['Courier New', 'DejaVu Sans Mono'],
    fontSize: 13,
    height: 1.35,
    color: RetroDosboxColors.accentAmber,
  );

  static const TextStyle statusLine = TextStyle(
    fontFamily: 'monospace',
    fontFamilyFallback: ['Courier New', 'DejaVu Sans Mono'],
    fontSize: 11,
    color: RetroDosboxColors.textMuted,
  );
}
