import 'dart:ui' as ui;

import 'package:esc_pos_utils_plus/esc_pos_utils_plus.dart';
import 'package:flutter/material.dart' show FontWeight, TextStyle;
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
  Future<List<int>> build({
    required int paperWidth,
    required String tableNumber,
    required List<KitchenTicketItem> items,
    String orderNote = '',
  }) async {
    final profile = await CapabilityProfile.load();
    final paperSize = paperWidth == 58 ? PaperSize.mm58 : PaperSize.mm80;
    final generator = Generator(paperSize, profile);

    final bytes = <int>[];

    // Slightly tighter ESC/POS line spacing.
    bytes.addAll([0x1B, 0x33, 18]);

    bytes.addAll(generator.hr(ch: '-'));

    await _appendText(
      bytes: bytes,
      generator: generator,
      text: tableNumber,
      paperWidth: paperWidth,
      bold: true,
    );

    bytes.addAll(generator.hr(ch: '-'));

    for (final item in items) {
      await _appendText(
        bytes: bytes,
        generator: generator,
        text: '${_formatQty(item.qty)} x ${item.itemName}',
        paperWidth: paperWidth,
        bold: true,
      );

      final note = item.kitchenNote.trim();
      if (note.isNotEmpty) {
        await _appendText(
          bytes: bytes,
          generator: generator,
          text: '  $note',
          paperWidth: paperWidth,
          bold: true,
        );
      }
    }

    final cleanOrderNote = orderNote.trim();
    if (cleanOrderNote.isNotEmpty) {
      bytes.addAll(generator.hr(ch: '-'));

      await _appendText(
        bytes: bytes,
        generator: generator,
        text: 'Order Note: $cleanOrderNote',
        paperWidth: paperWidth,
        bold: true,
      );
    }

    bytes.addAll(generator.hr(ch: '-'));
    bytes.addAll(generator.feed(1));

    // Restore printer default line spacing before cut.
    bytes.addAll([0x1B, 0x32]);
    bytes.addAll(generator.cut());

    return bytes;
  }

  Future<void> _appendText({
    required List<int> bytes,
    required Generator generator,
    required String text,
    required int paperWidth,
    required bool bold,
  }) async {
    if (_containsNonAscii(text)) {
      final image = await _renderUnicodeText(
        text: text,
        paperWidth: paperWidth,
        bold: bold,
      );

      bytes.addAll(
        generator.imageRaster(
          image,
          align: PosAlign.left,
        ),
      );

      return;
    }

    bytes.addAll(
      generator.text(
        text,
        styles: PosStyles(
          bold: bold,
        ),
      ),
    );
  }

  bool _containsNonAscii(String text) {
    for (final rune in text.runes) {
      if (rune > 0x7F) {
        return true;
      }
    }
    return false;
  }

  Future<img.Image> _renderUnicodeText({
    required String text,
    required int paperWidth,
    required bool bold,
  }) async {
    final maxWidth = paperWidth == 58 ? 360.0 : 540.0;

    final paragraphStyle = ui.ParagraphStyle(
      textAlign: ui.TextAlign.left,
      maxLines: null,
    );

    final paragraphBuilder = ui.ParagraphBuilder(paragraphStyle)
      ..pushStyle(
        ui.TextStyle(
          color: const ui.Color(0xFF000000),
          fontSize: 18,
          fontWeight: bold ? FontWeight.w700 : FontWeight.w400,
        ),
      )
      ..addText(text);

    final paragraph = paragraphBuilder.build();
    paragraph.layout(
      ui.ParagraphConstraints(width: maxWidth),
    );

    final height = paragraph.height.ceil() + 6;
    final width = maxWidth.ceil();

    final recorder = ui.PictureRecorder();
    final canvas = ui.Canvas(recorder);

    canvas.drawRect(
      ui.Rect.fromLTWH(
        0,
        0,
        width.toDouble(),
        height.toDouble(),
      ),
      ui.Paint()..color = const ui.Color(0xFFFFFFFF),
    );

    canvas.drawParagraph(
      paragraph,
      const ui.Offset(0, 2),
    );

    final picture = recorder.endRecording();
    final uiImage = await picture.toImage(width, height);
    final byteData = await uiImage.toByteData(
      format: ui.ImageByteFormat.png,
    );

    if (byteData == null) {
      throw Exception('Unable to render Unicode print text.');
    }

    final decoded = img.decodePng(
      byteData.buffer.asUint8List(),
    );

    if (decoded == null) {
      throw Exception('Unable to decode Unicode print image.');
    }

    return decoded;
  }

  String _formatQty(num qty) {
    if (qty == qty.roundToDouble()) {
      return qty.toInt().toString();
    }
    return qty.toString();
  }
}
