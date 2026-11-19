// Finds where a drawn paragraph breaks a line inside a word ("My consig /
// nments"), for the T9 rule that a tile label only wraps between words.

import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

/// The line ends of the text found by [finder] that fall inside a word, each
/// written as "My consig|nments". Empty when every line ends at a space or at
/// the end of the text.
///
/// RenderParagraph does not say where its lines end, so the same text is laid
/// out again in a TextPainter with everything the paragraph used, and the
/// copy is first checked to be as tall as the drawn paragraph (the same number
/// of lines), so the check reads the lines that are really on screen.
List<String> lineEndsInsideWords(WidgetTester tester, Finder finder) {
  final paragraph = tester.renderObject<RenderParagraph>(finder);
  final text = paragraph.text.toPlainText();
  final painter = TextPainter(
    text: paragraph.text,
    textAlign: paragraph.textAlign,
    textDirection: paragraph.textDirection,
    textScaler: paragraph.textScaler,
    maxLines: paragraph.maxLines,
    locale: paragraph.locale,
    strutStyle: paragraph.strutStyle,
    textWidthBasis: paragraph.textWidthBasis,
    textHeightBehavior: paragraph.textHeightBehavior,
  )..layout(maxWidth: paragraph.constraints.maxWidth);

  expect(
    painter.height,
    closeTo(paragraph.size.height, 0.01),
    reason: 'the copy must be laid out like the drawn "$text"',
  );

  final broken = <String>[];
  var start = 0;
  while (start < text.length) {
    final end = painter.getLineBoundary(TextPosition(offset: start)).end;
    if (end <= start) break;
    final insideWord =
        end < text.length && text[end - 1] != ' ' && text[end] != ' ';
    if (insideWord) {
      broken.add('${text.substring(0, end)}|${text.substring(end)}');
    }
    start = end;
  }
  painter.dispose();
  return broken;
}

/// The font size the text found by [finder] is drawn at, after the phone's
/// text size is applied.
double drawnFontSize(WidgetTester tester, Finder finder) {
  final paragraph = tester.renderObject<RenderParagraph>(finder);
  return paragraph.textScaler.scale(paragraph.text.style!.fontSize!);
}
