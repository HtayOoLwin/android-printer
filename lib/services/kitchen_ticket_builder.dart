
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
  static const double itemFontSize = 22;
  static const double noteFontSize = 22;

  static const double lineHeight = 1.15;

  Future<List<int>> build({
    required int paperWidth,
    required String tableNumber,
    required List<KitchenTicketItem> items,
    String salesOrder = '',
    String waiterName = '',
    String orderDateTime = '',
    String orderNote = '',
  }) async {
    final profile = await CapabilityProfile.load();

    final paperSize =
        paperWidth == 58 ? PaperSize.mm58 : PaperSize.mm80;

    final generator = Generator(paperSize, profile);

    final bytes = <int>[];

    // Keep line spacing consistent.
    bytes.addAll([0x1B, 0x33, 18]);

    // Two compact rows: Sales Order / Waiter and Table / Order Date-Time.
    // Keep old payloads printable while the ERPNext API is being updated.
    if (salesOrder.trim().isNotEmpty || waiterName.trim().isNotEmpty) {
      await _appendHeaderRow(
        bytes: bytes,
        generator: generator,
        left: salesOrder.trim(),
        right: waiterName.trim(),
        paperWidth: paperWidth,
      );
    }

    await _appendHeaderRow(
      bytes: bytes,
      generator: generator,
      left: tableNumber.trim().toUpperCase(),
      right: _formatOrderDateTime(orderDateTime),
      paperWidth: paperWidth,
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

  // Render both columns in ONE raster row to keep left/right alignment.
  Future<void> _appendHeaderRow({
    required List<int> bytes,
    required Generator generator,
    required String left,
    required String right,
    required int paperWidth,
  }) async {
    final width = paperWidth == 58 ? 384 : 576;
    final columnWidth = (width - 12) / 2;
    final fontSize = paperWidth == 58 ? 16.0 : 20.0;
    final leftParagraph = _headerParagraph(
      left, columnWidth, fontSize, ui.TextAlign.left,
    );
    final rightParagraph = _headerParagraph(
      right, columnWidth, fontSize, ui.TextAlign.right,
    );
    final height =
        (leftParagraph.height > rightParagraph.height
                ? leftParagraph.height
                : rightParagraph.height)
            .ceil() +
        12;

    final recorder = ui.PictureRecorder();
    final canvas = ui.Canvas(recorder);
    canvas.drawRect(
      ui.Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
      ui.Paint()..color = const ui.Color(0xFFFFFFFF),
    );
    canvas.drawParagraph(leftParagraph, const ui.Offset(0, 5));
    canvas.drawParagraph(
      rightParagraph,
      ui.Offset(width - columnWidth, 5),
    );
    final picture = recorder.endRecording();
    final image = await picture.toImage(width, height);
    final imageData = await image.toByteData(format: ui.ImageByteFormat.png);
    if (imageData == null) {
      throw StateError('Unable to render kitchen ticket header.');
    }
    final decoded = img.decodePng(imageData.buffer.asUint8List());
    if (decoded == null) {
      throw StateError('Unable to decode kitchen ticket header.');
    }
    bytes.addAll(generator.imageRaster(decoded, align: PosAlign.left));
  }

  ui.Paragraph _headerParagraph(
    String text,
    double width,
    double baseSize,
    ui.TextAlign alignment,
  ) {
    ui.Paragraph paragraphFor(double size) {
      final builder = ui.ParagraphBuilder(
        ui.ParagraphStyle(
          textAlign: alignment,
          maxLines: 1,
          ellipsis: '…',
        ),
      )
        ..pushStyle(
          ui.TextStyle(
            color: const ui.Color(0xFF000000),
            fontSize: size,
            fontWeight: FontWeight.w700,
          ),
        )
        ..addText(text);
      final paragraph = builder.build();
      paragraph.layout(ui.ParagraphConstraints(width: width));
      return paragraph;
    }

    var size = baseSize;
    var paragraph = paragraphFor(size);
    while (paragraph.didExceedMaxLines && size > 10) {
      size -= 1;
      paragraph = paragraphFor(size);
    }
    return paragraph;
  }

  String _formatOrderDateTime(String value) {
    final raw = value.trim();
    if (raw.isEmpty) return '';
    final parsed = DateTime.tryParse(raw);
    if (parsed == null) return raw;
    final date = parsed.isUtc ? parsed.toLocal() : parsed;
    String two(int number) => number.toString().padLeft(2, '0');
    final hour = date.hour % 12 == 0 ? 12 : date.hour % 12;
    final period = date.hour >= 12 ? 'PM' : 'AM';
    return '${two(date.day)}/${two(date.month)}/${date.year} '
        '${two(hour)}:${two(date.minute)} $period';
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
