import 'package:flutter/material.dart';

import '../data/emulator_ui_state.dart';
import '../theme/retrodosbox_theme.dart';

/// The in-game control strip: the on-screen pad, keyboard, trackpad mouse,
/// and the ways out.
///
/// It sits OUTSIDE the content panel, on the right-hand end of the status row
/// that already carries the rail toggle and the loaded title -- the same place
/// the Amiga and C64 front ends put theirs.
///
/// Sharing that row rather than taking a band of its own is the point: the row
/// is already on screen, and a second band comes straight out of the picture's
/// height, which a 4:3 machine on a wide handheld has none of to spare. Drawn
/// ON the picture, as these buttons used to be, they cover the top-right of the
/// frame -- which is exactly where DOS titles put their own status panels, and
/// a tool button over a menu item is a tap you cannot make.
///
/// Laid out from the right-hand edge, so the strip grows leftwards from the
/// side nearest the hand already holding the device.
class EmulatorControlStrip extends StatelessWidget {
  final EmulatorUiState ui;

  /// Snapshots and returns to the library, keeping your place.
  final VoidCallback? onPause;

  /// Terminates the session with no resume path. Null hides the button.
  final VoidCallback? onExit;

  const EmulatorControlStrip({
    super.key,
    required this.ui,
    this.onPause,
    this.onExit,
  });

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: ui,
      builder: (context, _) => Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _StripButton(
            icon: Icons.videogame_asset,
            active: ui.padVisible,
            tooltip: 'On-screen joypad',
            onTap: ui.togglePad,
          ),
          _StripButton(
            icon: Icons.keyboard,
            active: ui.keyboardVisible,
            tooltip: 'On-screen keys',
            onTap: ui.toggleKeyboard,
          ),
          _StripButton(
            icon: Icons.mouse,
            active: ui.mouseMode,
            tooltip: 'Trackpad mouse',
            onTap: ui.toggleMouseMode,
          ),
          if (onPause != null)
            _StripButton(
              icon: Icons.pause,
              active: false,
              tooltip: 'Pause and return to library (snapshot saved)',
              onTap: onPause!,
            ),
          if (onExit != null)
            _StripButton(
              icon: Icons.close,
              active: false,
              tooltip: 'Close game',
              onTap: onExit!,
            ),
        ],
      ),
    );
  }
}

class _StripButton extends StatelessWidget {
  const _StripButton({
    required this.icon,
    required this.active,
    required this.tooltip,
    required this.onTap,
  });

  final IconData icon;
  final bool active;
  final String tooltip;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Tooltip(
        message: tooltip,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(6),
          child: Container(
            width: 38,
            height: 38,
            decoration: BoxDecoration(
              color: active
                  ? RetroDosboxColors.selectedFill
                  : Colors.black.withValues(alpha: 0.5),
              borderRadius: BorderRadius.circular(6),
              border: Border.all(
                color: active ? RetroDosboxColors.accentAmber : RetroDosboxColors.panelStroke,
              ),
            ),
            child: Icon(
              icon,
              size: 19,
              color: active ? RetroDosboxColors.accentAmber : Colors.white70,
            ),
          ),
        ),
      ),
    );
  }
}
