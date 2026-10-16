import 'dart:ui' as ui;

import 'package:esc_pos_utils_plus/esc_pos_utils_plus.dart';
import 'package:flutter/material.dart' show FontWeight;
import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html_parser;
import 'package:image/image.dart' as img;

/// Renders the specific DMT Cashier Invoice HTML structure to 80mm ESC/POS
/// raster rows. Unlike generic HTML-to-text, this keeps the receipt's
/// company header, two-column invoice details, 12/58/30 item grid, and
/// 34/39/27 totals grid, including dashed separators.
///
/// Note: this is a purpose-built renderer, not a complete CSS/WebView engine.
/// It operates in the background isolate and needs physical device testing.
class CashierBillTicketBuilder {
  Future<List<int>> build({
    required String htmlContent,
    required int paperWidth,
  }) async {
    if (htmlContent.trim().isEmpty) {
      throw StateError('Cashier bill HTML is empty.');
    }

    final document = html_parser.parse(htmlContent);
    final receipt = document.querySelector('.receipt');
    if (receipt == null) {
      throw StateError('DMT Cashier Invoice .receipt element not found.');
    }

    final profile = await CapabilityProfile.load();
    final generator = Generator(
      paperWidth == 58 ? PaperSize.mm58 : PaperSize.mm80,
      profile,
    );
    final width = paperWidth == 58 ? 384 : 576;
    final bytes = <int>[];

    Future<void> raster(List<_Cell> cells, {int minHeight = 0}) async {
      if (cells.isEmpty) return;
      final bitmap = await _renderRow(cells, width, minHeight: minHeight);
      bytes.addAll(generator.imageRaster(bitmap, align: PosAlign.left));
    }

    Future<void> divider() async {
      final bitmap = img.Image(width: width, height: 10);
      img.fill(bitmap, color: img.ColorRgb8(255, 255, 255));
      // A single-pixel dashed line at the middle of the row.
      for (var x = 0; x < width; x += 13) {
        for (var dx = 0; dx < 8 && x + dx < width; dx++) {
          img.setPixel(bitmap, x + dx, 5, img.ColorRgb8(0, 0, 0));
        }
      }
      bytes.addAll(generator.imageRaster(bitmap, align: PosAlign.left));
    }

    final company = _text(receipt.querySelector('.company-name'));
    if (company.isNotEmpty) {
      await raster([
        _Cell(company, 0, 1, fontSize: 26, bold: true, center: true),
      ]);
    }
    await divider();

    final infoRows = receipt.querySelectorAll('.info-table tr');
    for (final tr in infoRows) {
      final cells = tr.querySelectorAll('td');
      if (cells.length >= 2) {
        await raster([
          _Cell(_text(cells[0]), 0, .56, fontSize: 21),
          _Cell(_text(cells[1]), .56, .44, fontSize: 21, right: true),
        ]);
      } else if (cells.length == 1) {
        await raster([
          _Cell(_text(cells.first), 0, 1,
              fontSize: 24, bold: true, center: true),
        ]);
      }
    }
    await divider();

    final header = receipt.querySelector('.item-table thead tr');
    if (header != null) {
      final cells = header.querySelectorAll('th');
      if (cells.length >= 3) {
        await raster(_itemCells(cells, header: true));
        await divider();
      }
    }

    final itemRows = receipt.querySelectorAll('.item-table tbody tr');
    for (final tr in itemRows) {
      final cells = tr.querySelectorAll('td');
      if (cells.length >= 3) {
        await raster(_itemCells(cells));
      }
    }
    await divider();

    final summaryRows = receipt.querySelectorAll('.summary-table tr');
    for (final tr in summaryRows) {
      final cells = tr.querySelectorAll('td');
      if (cells.length < 3) continue;
      final isNet = tr.classes.contains('net-total-row');
      await raster([
        _Cell(_text(cells[0]), 0, .34,
            fontSize: isNet ? 23 : 21, bold: isNet),
        _Cell(_text(cells[1]), .34, .39,
            fontSize: isNet ? 23 : 21, bold: isNet, right: true),
        _Cell(_text(cells[2]), .73, .27,
            fontSize: isNet ? 23 : 21, bold: isNet, right: true),
      ]);
    }
    await divider();
    bytes.addAll(generator.feed(2));
    bytes.addAll(generator.cut());
    return bytes;
  }

  List<_Cell> _itemCells(List<dom.Element> cells, {bool header = false}) {
    return [
      _Cell(_text(cells[0]), 0, .12,
          fontSize: header ? 23 : 22, bold: header),
      _Cell(_text(cells[1]), .12, .58,
          fontSize: header ? 23 : 22, bold: header),
      _Cell(_text(cells[2]), .70, .30,
          fontSize: header ? 23 : 22, bold: header, right: true),
    ];
  }

  String _text(dom.Element? element) =>
      (element?.text ?? '').replaceAll(RegExp(r'\s+'), ' ').trim();

  Future<img.Image> _renderRow(
    List<_Cell> cells,
    int width, {
    int minHeight = 0,
  }) async {
    final laidOut = <_PlacedText>[];
    var maxHeight = minHeight.toDouble();

    for (final cell in cells) {
      if (cell.text.isEmpty) continue;
      final x = (width * cell.start).round();
      final cellWidth = (width * cell.fraction).floor();
      final available = (cellWidth - 8).clamp(1, width).toDouble();
      final builder = ui.ParagraphBuilder(
        ui.ParagraphStyle(
          textAlign: cell.center
              ? ui.TextAlign.center
              : cell.right
                  ? ui.TextAlign.right
                  : ui.TextAlign.left,
        ),
      )
        ..pushStyle(ui.TextStyle(
          color: const ui.Color(0xFF000000),
          fontSize: cell.fontSize,
          fontWeight: cell.bold ? FontWeight.w700 : FontWeight.w400,
        ))
        ..addText(cell.text);
      final paragraph = builder.build()
        ..layout(ui.ParagraphConstraints(width: available));
      laidOut.add(_PlacedText(paragraph, x + 4));
      if (paragraph.height > maxHeight) maxHeight = paragraph.height;
    }

    final height = maxHeight.ceil() + 10;
    final recorder = ui.PictureRecorder();
    final canvas = ui.Canvas(recorder);
    canvas.drawColor(const ui.Color(0xFFFFFFFF), ui.BlendMode.src);
    for (final placed in laidOut) {
      canvas.drawParagraph(
        placed.paragraph,
        ui.Offset(placed.x.toDouble(), 5),
      );
    }
    final picture = recorder.endRecording();
    final bitmap = await picture.toImage(width, height);
    final png = await bitmap.toByteData(format: ui.ImageByteFormat.png);
    if (png == null) throw StateError('Unable to rasterize cashier bill.');
    final decoded = img.decodePng(png.buffer.asUint8List());
    if (decoded == null) throw StateError('Unable to decode bill raster.');
    return decoded;
  }
}

class _Cell {
  const _Cell(
    this.text,
    this.start,
    this.fraction, {
    required this.fontSize,
    this.bold = false,
    this.center = false,
    this.right = false,
  });

  final String text;
  final double start;
  final double fraction;
  final double fontSize;
  final bool bold;
  final bool center;
  final bool right;
}

class _PlacedText {
  const _PlacedText(this.paragraph, this.x);

  final ui.Paragraph paragraph;
  final int x;
}
