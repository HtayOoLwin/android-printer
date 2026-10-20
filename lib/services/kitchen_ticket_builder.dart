
import 'dart:ui' as ui;

import 'package:esc_pos_utils_plus/esc_pos_utils_plus.dart';
import 'package:flutter/material.dart' show FontWeight;
import 'package:image/image.dart' as img;

class KitchenTicketItem {
  const KitchenTicketItem({
    required this.itemName,
    required this.qty,
    this.kitchenNote = '',
  });

  final String itemName;
  final num qty;
  final String kitchenNote;
}

class KitchenTicketBuilder {
  // ==========================================================
  // Font Settings
  // ==========================================================

  static const double tableFontSize = 22;
  static const double itemFontSize = 20;
  static const double noteFontSize = 17;

  static const double lineHeight = 1.15;

  Future<List<int>> build({
    required int paperWidth,
    required String tableNumber,
    required List<KitchenTicketItem> items,
    String orderNote = '',
  }) async {
    final profile = await CapabilityProfile.load();

    final paperSize =
        paperWidth == 58 ? PaperSize.mm58 : PaperSize.mm80;

    final generator = Generator(paperSize, profile);

    final bytes = <int>[];

    // Keep line spacing consistent.
    bytes.addAll([0x1B, 0x33, 18]);

    bytes.addAll(generator.hr(ch: '-'));

    // ========================================================
    // Table Number
    // ========================================================

    await _appendText(
      bytes: bytes,
      generator: generator,
      text: tableNumber,
      paperWidth: paperWidth,
      bold: true,
      fontSize: tableFontSize,
    );

    bytes.addAll(generator.hr(ch: '-'));

    // ========================================================
    // Item Lines
    // ========================================================

    for (final item in items) {
      await _appendText(
        bytes: bytes,
        generator: generator,
        text: '${_formatQty(item.qty)} x ${item.itemName}',
        paperWidth: paperWidth,
        bold: true,
        fontSize: itemFontSize,
      );

      // Kitchen Note
      final note = item.kitchenNote.trim();

      if (note.isNotEmpty) {
        await _appendText(
          bytes: bytes,
          generator: generator,
          text: '  $note',
          paperWidth: paperWidth,
          bold: false,
          fontSize: noteFontSize,
        );
      }
    }

    // ========================================================
    // Order Note
    // ========================================================

    final cleanOrderNote = orderNote.trim();

    if (cleanOrderNote.isNotEmpty) {
      bytes.addAll(generator.hr(ch: '-'));

      await _appendText(
        bytes: bytes,
        generator: generator,
        text: 'Order Note: $cleanOrderNote',
        paperWidth: paperWidth,
        bold: false,
        fontSize: noteFontSize,
      );
    }

    bytes.addAll(generator.hr(ch: '-'));
    bytes.addAll(generator.feed(1));

    // Restore printer default line spacing.
    bytes.addAll([0x1B, 0x32]);

    bytes.addAll(generator.cut());

    return bytes;
  }

  // ==========================================================
  // Render Every Text Line as Image
  // ==========================================================

  Future<void> _appendText({
    required List<int> bytes,
    required Generator generator,
    required String text,
    required int paperWidth,
    required bool bold,
    required double fontSize,
  }) async {
    final image = await _renderTextImage(
      text: text,
      paperWidth: paperWidth,
      bold: bold,
      fontSize: fontSize,
    );

    bytes.addAll(
      generator.imageRaster(
        image,
        align: PosAlign.left,
      ),
    );
  }

  // ==========================================================
  // Unicode Raster Text
  // ==========================================================

  Future<img.Image> _renderTextImage({
    required String text,
    required int paperWidth,
    required bool bold,
    required double fontSize,
  }) async {
    // Width must be divisible by 8 for ESC/POS raster.
    final maxWidth = paperWidth == 58 ? 384.0 : 576.0;

    final paragraphStyle = ui.ParagraphStyle(
      textAlign: ui.TextAlign.left,
      maxLines: null,
    );

    final paragraphBuilder = ui.ParagraphBuilder(
      paragraphStyle,
    )
      ..pushStyle(
        ui.TextStyle(
          color: const ui.Color(0xFF000000),
          fontSize: fontSize,
          fontWeight:
              bold ? FontWeight.w700 : FontWeight.w400,
          height: lineHeight,
        ),
      )
      ..addText(text);

    final paragraph = paragraphBuilder.build();

    paragraph.layout(
      ui.ParagraphConstraints(
        width: maxWidth,
      ),
    );

    // Additional vertical padding prevents Myanmar
    // upper/lower marks from being clipped.
    final height = paragraph.height.ceil() + 12;
    final width = maxWidth.ceil();

    final recorder = ui.PictureRecorder();
    final canvas = ui.Canvas(recorder);

    // White background
    canvas.drawRect(
      ui.Rect.fromLTWH(
        0,
        0,
        width.toDouble(),
        height.toDouble(),
      ),
      ui.Paint()
        ..color = const ui.Color(0xFFFFFFFF),
    );

    canvas.drawParagraph(
      paragraph,
      const ui.Offset(0, 5),
    );

    final picture = recorder.endRecording();

    final uiImage = await picture.toImage(
      width,
      height,
    );

    final byteData = await uiImage.toByteData(
      format: ui.ImageByteFormat.png,
    );

    if (byteData == null) {
      throw Exception(
        'Unable to render kitchen ticket text.',
      );
    }

    final decoded = img.decodePng(
      byteData.buffer.asUint8List(),
    );

    if (decoded == null) {
      throw Exception(
        'Unable to decode kitchen ticket image.',
      );
    }

    return decoded;
  }

  // ==========================================================
  // Quantity Formatter
  // ==========================================================

  String _formatQty(num qty) {
    if (qty == qty.roundToDouble()) {
      return qty.toInt().toString();
    }

    return qty.toString();
  }
}
