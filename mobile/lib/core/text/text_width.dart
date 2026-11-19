// Measuring text before it is drawn, for layouts that must choose by the real
// size of a word: the app bar's role pill, the home tiles' labels and the
// navigation bar's words.

import 'package:flutter/widgets.dart';

/// How wide [value] is drawn in [style] at [context], on one line, the same way
/// a Text widget there would draw it.
///
/// Text merges its style with the surrounding default style (an app bar or a
/// Material sets one) and applies the phone's text size and "bold text"
/// settings, so the measurement does the same; otherwise it could say "fits"
/// for a word that is then drawn wider.
///
/// [textScaler] replaces the phone's text size, for a label that is drawn at a
/// size worked out by hand ([TextScaler.noScaling] with its own font size).
double drawnTextWidth(
  BuildContext context,
  String value,
  TextStyle? style, {
  TextScaler? textScaler,
}) => drawnTextSize(context, value, style, textScaler: textScaler).width;

/// The width and height of [value] drawn on one line, measured like
/// [drawnTextWidth]. The height is one line's, for a layout that must grow
/// with the phone's text size (the navigation bar).
Size drawnTextSize(
  BuildContext context,
  String value,
  TextStyle? style, {
  TextScaler? textScaler,
}) {
  var effective = DefaultTextStyle.of(context).style.merge(style);
  if (MediaQuery.boldTextOf(context)) {
    effective = effective.merge(const TextStyle(fontWeight: FontWeight.bold));
  }
  final painter = TextPainter(
    text: TextSpan(text: value, style: effective),
    textDirection: Directionality.of(context),
    textScaler: textScaler ?? MediaQuery.textScalerOf(context),
    maxLines: 1,
  )..layout();
  final size = painter.size;
  // A TextPainter holds native resources until disposed.
  painter.dispose();
  return size;
}
