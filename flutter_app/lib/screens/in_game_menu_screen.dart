import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../data/conf_overrides.dart';
import 'advanced_config_screen.dart';

/// Our replacement for the DOSBox-X menu bar.
///
/// The core draws no menus at all (patch 0007 selects the NULL backend) -
/// this is where a player goes mid-game instead. It runs in the launcher
/// process, over the emulator, and speaks to the running core through the
/// emuAction channel. Geek mode adds the full configuration surface; both
/// modes get the things you actually need with a game on screen.
class InGameMenuScreen extends StatelessWidget {
  const InGameMenuScreen({
    super.key,
    required this.geek,
    required this.overrides,
    required this.filesDir,
    this.gameName,
    this.onGameConfig,
    this.onGlobalConfig,
  });

  final bool geek;
  final ConfOverrides overrides;
  final String filesDir;

  /// The game on screen, when the launcher knows it.
  final String? gameName;

  /// Settings for this game alone, and for every game.
  final VoidCallback? onGameConfig;
  final VoidCallback? onGlobalConfig;

  static const MethodChannel _channel = MethodChannel('dosboxx/emulator');
  static const Color _amber = Color(0xFFFFB000);
  static const Color _cyan = Color(0xFF55FFFF);

  static Future<void> _action(String action) =>
      _channel.invokeMethod<bool>('emuAction', <String, String>{
        'action': action,
      }).then((_) {});

  Future<void> _resume(BuildContext context) async {
    Navigator.pop(context);
    await _channel.invokeMethod<bool>('resumeGame');
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      // Back is "resume", never "drop the player somewhere else".
      canPop: false,
      onPopInvokedWithResult: (bool didPop, Object? _) {
        if (!didPop) _resume(context);
      },
      child: Scaffold(
        appBar: AppBar(
          title: const Text('PAUSED',
              style: TextStyle(letterSpacing: 3, fontSize: 16)),
          leading: IconButton(
            icon: const Icon(Icons.close),
            onPressed: () => _resume(context),
          ),
        ),
        body: ListView(
          padding: const EdgeInsets.symmetric(vertical: 8),
          children: <Widget>[
            _Row(
              icon: Icons.play_arrow,
              color: _amber,
              title: 'Resume',
              subtitle: 'Back to the game',
              onTap: () => _resume(context),
            ),
            _Row(
              icon: Icons.keyboard,
              color: _cyan,
              title: 'Keyboard',
              subtitle: 'Show or hide the on-screen keys',
              onTap: () async {
                await _action('keyboard');
                if (context.mounted) await _resume(context);
              },
            ),
            _Row(
              icon: Icons.gamepad,
              color: _cyan,
              title: 'Controls',
              subtitle: 'Map the pad and touch buttons',
              onTap: () async {
                await _action('controls');
                if (context.mounted) await _resume(context);
              },
            ),
            if (geek) ...<Widget>[
              const _Heading('GEEK'),
              _Row(
                icon: Icons.speed,
                color: _cyan,
                title: 'Speed up',
                subtitle: 'More cycles, right now',
                onTap: () => _action('speed_up'),
              ),
              _Row(
                icon: Icons.slow_motion_video,
                color: _cyan,
                title: 'Slow down',
                subtitle: 'Fewer cycles, for games that run too fast',
                onTap: () => _action('speed_down'),
              ),
              if (onGameConfig != null)
                _Row(
                  icon: Icons.tune,
                  color: _amber,
                  title: gameName == null
                      ? 'Settings for this game'
                      : 'Settings for ${gameName!}',
                  subtitle: 'Only this game - applies next launch',
                  onTap: onGameConfig!,
                ),
              _Row(
                icon: Icons.settings,
                color: _cyan,
                title: 'Settings for every game',
                subtitle: 'The global defaults - a game can still override',
                onTap: onGlobalConfig ??
                    () => Navigator.push(
                          context,
                          MaterialPageRoute<void>(
                            builder: (BuildContext context) =>
                                AdvancedConfigScreen(
                              overrides: overrides,
                              onChanged: () => overrides.save(filesDir),
                            ),
                          ),
                        ),
              ),
            ],
            const _Heading('LEAVE'),
            _Row(
              icon: Icons.exit_to_app,
              color: Color(0xFFFF6060),
              title: 'Quit to the shelf',
              subtitle: 'Ends this game',
              onTap: () async {
                final bool ok = await showDialog<bool>(
                      context: context,
                      builder: (BuildContext context) => AlertDialog(
                        content: const Text('Quit the game?'),
                        actions: <Widget>[
                          TextButton(
                            onPressed: () => Navigator.pop(context, false),
                            child: const Text('Cancel'),
                          ),
                          TextButton(
                            onPressed: () => Navigator.pop(context, true),
                            child: const Text('Quit'),
                          ),
                        ],
                      ),
                    ) ??
                    false;
                if (!ok) return;
                await _action('quit');
                if (context.mounted) Navigator.pop(context);
              },
            ),
          ],
        ),
      ),
    );
  }
}

class _Heading extends StatelessWidget {
  const _Heading(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 18, 16, 6),
        child: Text(
          text,
          style: const TextStyle(
            fontSize: 11,
            letterSpacing: 2,
            color: Color(0xFF8888BB),
          ),
        ),
      );
}

class _Row extends StatelessWidget {
  const _Row({
    required this.icon,
    required this.color,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  final IconData icon;
  final Color color;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => ListTile(
        leading: Icon(icon, color: color),
        title: Text(title, style: const TextStyle(fontSize: 16)),
        subtitle: Text(subtitle, style: const TextStyle(fontSize: 12)),
        onTap: onTap,
      );
}
