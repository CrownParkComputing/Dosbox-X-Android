// Where input goes.
//
// The core does not always live in this process. On Android it runs in
// :dosbox, because DOSBox-X is a one-shot core and only a process boundary
// gives the next game a genuinely fresh engine; on desktop it runs right here
// behind FFI. Both are real, and every input surface -- the on-screen pad, the
// on-screen keyboard, the trackpad, a physical controller -- has to reach
// whichever one is actually running.
//
// This is that seam. Without it each surface reached for the launcher's own
// core object, which on Android is an idle library handle that starts nothing:
// the game rendered, played sound, and ignored every button pressed at it.
import '../ffi/retrodosbox_core.dart';
import 'app_restart_service.dart';

/// The input half of a running session, wherever it is running.
abstract class EmulatorInput {
  /// Routes to the process holding the live core.
  factory EmulatorInput.forSession({required RetroDosboxCore core}) =>
      EmulatorProcess.isSupported
          ? const _ProcessInput()
          : _CoreInput(core);

  void keyEvent(int sdlScancode, bool pressed);
  void mouseMotion(int dx, int dy);
  void mouseButton(int button, bool pressed);
  void joystick(int port, int mask, {double axisX = 0, double axisY = 0});
}

/// Desktop: the core is in this process, so the call is the FFI call.
class _CoreInput implements EmulatorInput {
  const _CoreInput(this.core);

  final RetroDosboxCore core;

  @override
  void keyEvent(int sdlScancode, bool pressed) =>
      core.keyEvent(sdlScancode, pressed);

  @override
  void mouseMotion(int dx, int dy) => core.mouseMotion(dx, dy);

  @override
  void mouseButton(int button, bool pressed) =>
      core.mouseButton(button, pressed);

  @override
  void joystick(int port, int mask, {double axisX = 0, double axisY = 0}) =>
      core.joystick(port, mask, axisX: axisX, axisY: axisY);
}

/// Android: across the boundary to :dosbox.
class _ProcessInput implements EmulatorInput {
  const _ProcessInput();

  @override
  void keyEvent(int sdlScancode, bool pressed) =>
      EmulatorProcess.sendInput('key', a: sdlScancode, down: pressed);

  @override
  void mouseMotion(int dx, int dy) =>
      EmulatorProcess.sendInput('mouseMotion', a: dx, b: dy);

  @override
  void mouseButton(int button, bool pressed) =>
      EmulatorProcess.sendInput('mouseButton', a: button, down: pressed);

  @override
  void joystick(int port, int mask, {double axisX = 0, double axisY = 0}) =>
      EmulatorProcess.sendInput('joystick',
          a: port, b: mask, x: axisX, y: axisY);
}
