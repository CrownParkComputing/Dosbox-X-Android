import 'package:flutter/material.dart';

import '../theme/dosbox_theme.dart';

/// One entry in the side nav.
class SidebarDestination {
  final String title;

  const SidebarDestination(this.title);
}

/// The side nav: a vertical rail of destination buttons with an optional
/// widget pinned to the bottom of the rail.
///
/// The destinations are passed in rather than read from a screen-level enum.
/// The VICE app's rail imports its category enum from workbench_screen.dart,
/// which makes the widget unusable until that screen exists and impossible to
/// reuse for a second rail; here the caller owns the list and the selection,
/// so this file depends on nothing but the theme.
///
/// Sizing is measured, not hardcoded. LauncherLayoutHelper.createLauncher in
/// the Android original also sizes this rail from its content (widest
/// measured label, floored at dp(88), capped at dp(150)/a quarter of the
/// screen); an earlier pass of the sibling port pinned it at a flat 160dp
/// instead, which left a wide dead strip to the right of every label on a
/// 853dp-wide device -- and, worse, ignored the platform text scale entirely,
/// so at the Retroid's 1.35x font scale the labels were far too big for the
/// fixed 36dp rows. Both are computed here now:
///   - width  = widest measured title + paddings, clamped
///   - height = text height + vertical padding, floored at a touch target
class Sidebar extends StatelessWidget {
  final List<SidebarDestination> destinations;

  /// Index into [destinations]. Out-of-range values simply mean "nothing
  /// highlighted", which is the right behaviour while a screen is still
  /// deciding what it is showing rather than an error worth asserting on.
  final int selectedIndex;

  final ValueChanged<int> onSelected;

  /// Optional content pinned to the bottom of the rail, below the scrolling
  /// destination list. The VICE app hardcodes a music-player status line in
  /// this slot; this front end has no music player, but the slot itself is
  /// worth keeping -- a mount/cycles status line lives just as naturally
  /// there. Null means the rail ends after the last button.
  final Widget? footer;

  const Sidebar({
    super.key,
    required this.destinations,
    required this.selectedIndex,
    required this.onSelected,
    this.footer,
  });


  TextStyle _titleStyle(double scaledSize) => TextStyle(
        fontSize: scaledSize,
        height: 1.15,
        color: DosColors.sidebarLabelIdle,
      );

  @override
  Widget build(BuildContext context) {
    final scaler = MediaQuery.textScalerOf(context);
    final titleSize = scaler.scale(DosMetrics.sidebarButtonTextSize);
    final style = _titleStyle(titleSize);

    // Widest title decides the rail width, so no label is ever clipped and
    // there's no dead space beyond one consistent right margin.
    double widest = 0;
    for (final dest in destinations) {
      final painter = TextPainter(
        text: TextSpan(text: dest.title, style: style),
        textDirection: Directionality.of(context),
        maxLines: 1,
      )..layout();
      if (painter.width > widest) widest = painter.width;
    }

    final horizontalPadding = DosMetrics.sidebarButtonSidePadding * 2;
    final rowContentWidth = widest;
    final screenWidth = MediaQuery.sizeOf(context).width;
    final railWidth =
        (rowContentWidth + horizontalPadding + DosMetrics.sideNavPadding * 2)
            .clamp(DosMetrics.sidebarMinWidth,
                DosMetrics.sidebarMaxWidth(screenWidth));

    // Rows grow with the text rather than clipping it, but never get
    // smaller than a comfortable touch target.
    final rowHeight =
        (titleSize * 1.15 + DosMetrics.sidebarButtonVerticalPadding * 2)
            .clamp(DosMetrics.sidebarButtonHeight, 72.0);

    return Container(
      width: railWidth,
      padding: const EdgeInsets.all(DosMetrics.sideNavPadding),
      decoration: BoxDecoration(
        color: DosColors.panelFill,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: DosColors.panelStroke),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // The rail must never overflow, however short the window is (the
          // Retroid Flip2 is only 456dp tall in landscape, which a fixed
          // 12-entry Column overran by 32px). Expanded + a scroll view gives
          // the buttons all the room there is and scrolls any remainder;
          // Expanded (not Flexible) also keeps the footer pinned to the
          // bottom of the rail rather than letting it float up under the
          // last button.
          Expanded(
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (var i = 0; i < destinations.length; i++)
                    _SidebarButton(
                      destination: destinations[i],
                      selected: i == selectedIndex,
                      onTap: () => onSelected(i),
                      height: rowHeight,
                      titleStyle: style,
                    ),
                ],
              ),
            ),
          ),
          if (footer != null)
            Padding(
              padding: const EdgeInsets.only(
                left: DosMetrics.sidebarButtonSidePadding,
                top: 6,
                bottom: 2,
              ),
              child: footer,
            ),
        ],
      ),
    );
  }
}

class _SidebarButton extends StatelessWidget {
  final SidebarDestination destination;
  final bool selected;
  final VoidCallback onTap;
  final double height;
  final TextStyle titleStyle;

  const _SidebarButton({
    required this.destination,
    required this.selected,
    required this.onTap,
    required this.height,
    required this.titleStyle,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding:
          const EdgeInsets.only(bottom: DosMetrics.sidebarButtonBottomMargin),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(8),
          child: Container(
            height: height,
            padding: const EdgeInsets.symmetric(
                horizontal: DosMetrics.sidebarButtonSidePadding),
            decoration: selected
                ? BoxDecoration(
                    color: DosColors.selectedFill,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: DosColors.selectedStroke),
                  )
                : null,
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    destination.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: titleStyle.copyWith(
                      color: selected
                          ? DosColors.sidebarLabelSelected
                          : DosColors.sidebarLabelIdle,
                      fontWeight:
                          selected ? FontWeight.w600 : FontWeight.normal,
                    ),
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
