// Why a Windows 95/98 disk image will not run here.
//
// This screen exists because the honest answer is not obvious and the
// dishonest answer is expensive. DOSBox-X CAN boot Windows 98 -- it did, on
// this very device -- so an app that simply refused would look broken, and an
// app that tried would hand the user a machine that boots and then cannot run
// anything they wanted it for. Saying why, once, in the place they arrive
// carrying the image, is cheaper than either.
import 'package:flutter/material.dart';

import '../theme/retrodosbox_theme.dart';

class WhyNotWindowsScreen extends StatelessWidget {
  const WhyNotWindowsScreen({super.key});

  /// Shown from the library when a title is a big bootable disk image, and
  /// from About.
  static Future<void> show(BuildContext context) => showModalBottomSheet<void>(
        context: context,
        backgroundColor: RetroDosboxColors.rootBackground,
        isScrollControlled: true,
        showDragHandle: true,
        builder: (_) => const FractionallySizedBox(
          heightFactor: 0.9,
          child: WhyNotWindowsScreen(),
        ),
      );

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 4, 20, 32),
      children: const [
        Text(
          'This app runs DOS, not Windows',
          style: TextStyle(
            color: Colors.white,
            fontSize: 19,
            fontWeight: FontWeight.w600,
          ),
        ),
        SizedBox(height: 16),
        _Para(
          'A Windows 95 or 98 hard-disk image will not be booted here. That '
          'is a deliberate limit, not a missing feature, and it comes from '
          'the processor in this device rather than from anything in the '
          'app.',
        ),
        _Heading('The emulator has two CPU cores'),
        _Para(
          'The fast one recompiles the emulated processor’s code into '
          'code this device can run directly. The slow one interprets it '
          'instruction by instruction, perhaps a hundred times slower.',
        ),
        _Para(
          'On an ARM device — phones, tablets and handhelds — the '
          'only fast core available is the one DOSBox-X documents as '
          'incompatible with Windows 95 and other preemptive multitasking '
          'systems. The fast core that does work with Windows is written for '
          'Intel hosts and is not compiled here at all.',
        ),
        _Heading('So Windows leaves nothing worth running'),
        _Para(
          'Windows can be booted on the slow core, and it does reach a '
          'desktop. But a 3D game of that era then renders through a '
          'software graphics card driven by an interpreted processor, which '
          'is roughly two orders of magnitude short of playable. What you get '
          'is a black screen with perfectly healthy sound — the emulated '
          'sound card keeps time while a single frame takes minutes. It looks '
          'broken. It is merely far too slow.',
        ),
        _Para(
          'Shipping that would mean an app that appears to support Windows '
          'and disappoints every time it is used for it.',
        ),
        _Heading('DOS is a different matter'),
        _Para(
          'DOS is not a preemptive multitasking system, so the fast core’s '
          'limitation does not apply to it. DOS titles run on the fast core, '
          'including 3D ones, and that is what this app is for.',
        ),
        _Heading('If you want Windows'),
        _Para(
          'Use an emulator built for it. DOSBox-X emulates a DOS machine that '
          'can host Windows; a PC emulator such as 86Box emulates the '
          'hardware itself and is the right tool for a Windows 98 install.',
        ),
        SizedBox(height: 20),
        _Para(
          'Your disk images are untouched. Nothing here deletes or converts '
          'them, so they remain ready for an emulator that can use them.',
        ),
      ],
    );
  }
}

class _Heading extends StatelessWidget {
  const _Heading(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(top: 22, bottom: 8),
        child: Text(
          text,
          style: const TextStyle(
            color: RetroDosboxColors.textMuted2,
            fontSize: 13,
            fontWeight: FontWeight.w600,
            letterSpacing: 0.4,
          ),
        ),
      );
}

class _Para extends StatelessWidget {
  const _Para(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: Text(
          text,
          style: const TextStyle(
            color: Colors.white70,
            fontSize: 14,
            height: 1.45,
          ),
        ),
      );
}
