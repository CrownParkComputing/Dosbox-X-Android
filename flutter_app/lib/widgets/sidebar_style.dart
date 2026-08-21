import 'sidebar.dart';
import '../theme/retrodosbox_theme.dart';

/// The DOSBox front end's rail palette. This adapter is the only per-app part
/// of the side nav -- widgets/sidebar.dart itself is identical in every
/// Retro-* app, so a fix there lands everywhere instead of once.
const SidebarStyle retroDosboxSidebarStyle = SidebarStyle(
  panelFill: RetroDosboxColors.panelFill,
  panelStroke: RetroDosboxColors.panelStroke,
  selectedFill: RetroDosboxColors.selectedFill,
  selectedStroke: RetroDosboxColors.selectedStroke,
  labelIdle: RetroDosboxColors.sidebarLabelIdle,
  labelSelected: RetroDosboxColors.sidebarLabelSelected,
  minWidth: RetroDosboxMetrics.sidebarMinWidth,
  buttonHeight: RetroDosboxMetrics.sidebarButtonHeight,
  buttonTextSize: RetroDosboxMetrics.sidebarButtonTextSize,
  buttonBottomMargin: RetroDosboxMetrics.sidebarButtonBottomMargin,
  buttonSidePadding: RetroDosboxMetrics.sidebarButtonSidePadding,
  buttonVerticalPadding: RetroDosboxMetrics.sidebarButtonVerticalPadding,
  navPadding: RetroDosboxMetrics.sideNavPadding,
  maxWidth: RetroDosboxMetrics.sidebarMaxWidth,
);
