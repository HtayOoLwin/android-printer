import 'dart:ui' as ui;

import 'package:esc_pos_utils_plus/esc_pos_utils_plus.dart';
import 'package:flutter/material.dart' show FontWeight;
import 'package:html/parser.dart' as html_parser;
import 'package:html/dom.dart' as dom;
import 'package:image/image.dart' as img;

/// Text-only fallback for server-rendered HTML bills.
/// This does not preserve the DMT print format's CSS, fonts or columns.
/// Keep on a review branch until the receipt is checked on real hardware.
class CashierBillTicketBuilder {
  Future<List<int>> build({
    required String htmlContent,
    required int paperWidth,
  }) async {
    if (htmlContent.trim().isEmpty) {
      throw StateError('Cashier bill HTML is empty.');
    }
    final document = html_parser.parse(htmlContent);
    for (final element in document.querySelectorAll(
      'style, script, head, noscript, svg',
    )) {
      element.remove();
    }
    final lines = <String>[];
    final buffer = StringBuffer();
    void flush() {
      final value = buffer.toString().replaceAll(RegExp(r'\s+'), ' ').trim();
      buffer.clear();
      if (value.isNotEmpty && (lines.isEmpty || lines.last != value)) {
        lines.add(value);
      }
    }
    void walk(dom.Node node) {
      if (node is dom.Text) {
        buffer.write(node.text);
        buffer.write(' ');
      } else if (node is dom.Element) {
        final tag = node.localName ?? '';
        if (tag == 'br') {
          flush();
          return;
        }
        final block = {
          'div', 'p', 'tr', 'td', 'th', 'li', 'h1', 'h2', 'h3',
          'h4', 'h5', 'h6', 'section', 'article', 'header', 'footer',
        }.contains(tag);
        if (block && buffer.isNotEmpty) flush();
        for (final child in node.nodes) {
          walk(child);
        }
        if (block) flush();
      }
    }
    walk(document.body ?? document.documentElement!);
    flush();
    if (lines.isEmpty) {
      throw StateError('No printable bill text was found in HTML.');
    }
    final profile = await CapabilityProfile.load();
    final generator = Generator(
      paperWidth == 58 ? PaperSize.mm58 : PaperSize.mm80,
      profile,
    );
    final bytes = <int>[];
    bytes.addAll(generator.hr(ch: '-'));
    // Raster lines support Myanmar Unicode shaping.
    for (final line in lines) {
      final image = await _renderText(line, paperWidth);
      bytes.addAll(generator.imageRaster(image, align: PosAlign.left));
    }
    bytes.addAll(generator.hr(ch: '-'));
    bytes.addAll(generator.feed(2));
    bytes.addAll(generator.cut());
    return bytes;
  }

  Future<img.Image> _renderText(String text, int paperWidth) async {
    final width = paperWidth == 58 ? 384 : 576;
    final builder = ui.ParagraphBuilder(
      ui.ParagraphStyle(textAlign: ui.TextAlign.left),
    )
      ..pushStyle(ui.TextStyle(
        fontSize: 22,
        color: const ui.Color(0xFF000000),
        fontWeight: FontWeight.w500,
      ))
      ..addText(text);
    final paragraph = builder.build();
    paragraph.layout(ui.ParagraphConstraints(width: width.toDouble()));
    final height = paragraph.height.ceil() + 8;
    final recorder = ui.PictureRecorder();
    final canvas = ui.Canvas(recorder);
    canvas.drawColor(const ui.Color(0xFFFFFFFF), ui.BlendMode.src);
    canvas.drawParagraph(paragraph, const ui.Offset(0, 4));
    final picture = recorder.endRecording();
    final bitmap = await picture.toImage(width, height);
    final png = await bitmap.toByteData(format: ui.ImageByteFormat.png);
    if (png == null) throw StateError('Unable to rasterize bill line.');
    final result = img.decodePng(png.buffer.asUint8List());
    if (result == null) throw StateError('Unable to decode bill raster.');
    return result;
  }
}
