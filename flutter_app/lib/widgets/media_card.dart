import 'package:flutter/material.dart';

import '../theme/retrodosbox_theme.dart';

/// Port of MainActivity.createMediaCard (grid mode only -- the carousel
/// mode is used by a "list view" toggle deferred in this pass).
///
/// Plain strings in, no data model. The sibling app's card takes a
/// MediaEntry and pulls a filename and an extension off it, which works there
/// because a C64 title IS one file. A DOS title usually is not: it is a
/// folder containing an .exe (often several, plus a setup program), or a CD
/// image, or an archive that gets extracted before it can be mounted. There
/// is no single extension to show, and the shape of the library entry is
/// still being settled -- so the card takes what it draws and nothing more,
/// and cannot break when the data layer lands.
///
/// Box art (IGDB) is deferred; the cover slot shows [kindLabel], the same
/// fallback the Android card uses while art hasn't loaded.
class MediaCard extends StatelessWidget {
  /// Display name, e.g. "Doom". Wraps to two lines, then ellipsises.
  final String title;

  /// Very short description of what the entry is -- "DIR", "CD", "ZIP",
  /// "EXE". Drawn large in the cover slot, so keep it to a few characters.
  final String kindLabel;

  /// Optional second line under the title: a version, a folder name, a
  /// mounted drive letter. Omitted entirely when null, so the card does not
  /// reserve a blank strip for entries that have nothing to say.
  final String? subtitle;

  final VoidCallback onTap;

  const MediaCard({
    super.key,
    required this.title,
    required this.kindLabel,
    required this.onTap,
    this.subtitle,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: RetroDosboxMetrics.mediaCardWidth,
      height: RetroDosboxMetrics.mediaCardHeight,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(8),
          child: Container(
            padding: const EdgeInsets.all(4),
            decoration: BoxDecoration(
              color: RetroDosboxColors.cardFill,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: RetroDosboxColors.cardStroke),
            ),
            child: Column(
              children: [
                Container(
                  height: RetroDosboxMetrics.mediaCoverHeight,
                  width: double.infinity,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: RetroDosboxColors.coverFill,
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(color: RetroDosboxColors.coverStroke),
                  ),
                  child: Text(
                    kindLabel,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: Color(0xFFB9C2CE),
                      fontSize: 12,
                    ),
                  ),
                ),
                SizedBox(
                  height: 28,
                  child: Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text(
                      title,
                      textAlign: TextAlign.center,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(color: Colors.white, fontSize: 10),
                    ),
                  ),
                ),
                if (subtitle != null)
                  SizedBox(
                    height: 16,
                    child: Text(
                      subtitle!,
                      textAlign: TextAlign.center,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          color: RetroDosboxColors.textMuted, fontSize: 8),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
