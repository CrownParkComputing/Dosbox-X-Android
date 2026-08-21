import 'package:flutter/material.dart';

import '../data/emulator_ui_state.dart';
import '../theme/retrodosbox_theme.dart';

/// The in-game control strip: the rail toggle, the on-screen pad, keyboard,
/// trackpad mouse, and the ways out.
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

  /// Brings the sidebar back, leaving fullscreen. Null on the status row,
  /// where the rail's own toggle already sits a few pixels to the left and a
  /// second one would be a duplicate.
  ///
  /// Fullscreen has no status row for that toggle to live on, and dropping it
  /// left no way back to the rail at all -- so it joins the strip, appearing
  /// and hiding with the rest of the chrome on a touch.
  final VoidCallback? onShowSidebar;

  /// Snapshots and returns to the library, keeping your place.
  final VoidCallback? onPause;

  /// Terminates the session with no resume path. Null hides the button.
  final VoidCallback? onExit;

  /// Called before any button acts, so the shell can restart the countdown
  /// that hides this strip. Without it, using the toolbar would be the one
  /// interaction that did not keep the toolbar on screen -- pressing one
  /// button would be a race against the strip vanishing under your thumb.
  final VoidCallback? onInteract;

  const EmulatorControlStrip({
    super.key,
    required this.ui,
    this.onShowSidebar,
    this.onPause,
    this.onExit,
    this.onInteract,
  });

  /// Wraps a button's action so any press counts as interaction.
  VoidCallback _act(VoidCallback action) => () {
        onInteract?.call();
        action();
      };

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: ui,
      builder: (context, _) => Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Leftmost, the same end of the strip the rail toggle occupies on
          // the status row.
          if (onShowSidebar != null)
            _StripButton(
              icon: Icons.menu,
              active: false,
              tooltip: 'Show sidebar',
              onTap: _act(onShowSidebar!),
            ),
          _StripButton(
            icon: Icons.videogame_asset,
            active: ui.padVisible,
            tooltip: 'On-screen joypad',
            onTap: _act(ui.togglePad),
          ),
          _StripButton(
            icon: Icons.keyboard,
            active: ui.keyboardVisible,
            tooltip: 'On-screen keys',
            onTap: _act(ui.toggleKeyboard),
          ),
          _StripButton(
            icon: Icons.mouse,
            active: ui.mouseMode,
            tooltip: 'Trackpad mouse',
            onTap: _act(ui.toggleMouseMode),
          ),
          if (onPause != null)
            _StripButton(
              icon: Icons.pause,
              active: false,
              tooltip: 'Pause and return to library (snapshot saved)',
              onTap: _act(onPause!),
            ),
          if (onExit != null)
            _StripButton(
              icon: Icons.close,
              active: false,
              tooltip: 'Close game',
              onTap: _act(onExit!),
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
      // Spaced apart, not touching. These are hit targets for a thumb on a
      // handheld, and the pause and close buttons sit next to each other:
      // adjacent 38px squares with no gap is how you quit a game you meant to
      // pause. The padding used to be `only(bottom: 6)`, left over from when
      // this strip was a vertical column down the side of the picture.
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
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
