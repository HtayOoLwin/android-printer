
// ignore_for_file: unnecessary_brace_in_string_interps

import 'dart:ui' as ui;

import 'package:esc_pos_utils_plus/esc_pos_utils_plus.dart';
import 'package:html/parser.dart' as html_parser;
import 'package:html/dom.dart' as dom;
import 'package:image/image.dart' as img;

/// Render the DMT cashier receipt as full-width raster rows.
/// Supports Myanmar Unicode rendering.
///
/// Print darkness improvements:
/// 1. Stronger font weight.
/// 2. Pure black/white image conversion.
///
/// Summary font sizes:
/// Subtotal / Tax / Service Charges = 24
/// Net Total = 27 (Bold)
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
      throw StateError(
        'Expected a .receipt element in cashier HTML.',
      );
    }

    final itemTable = receipt.querySelector('.item-table');
    final summaryTable = receipt.querySelector('.summary-table');

    if (itemTable == null || summaryTable == null) {
      throw StateError(
        'Cashier HTML is missing item or summary table.',
      );
    }

    final profile = await CapabilityProfile.load();

    final generator = Generator(
      paperWidth == 58
          ? PaperSize.mm58
          : PaperSize.mm80,
      profile,
    );

    final width = paperWidth == 58 ? 384 : 576;

    final bytes = <int>[];

    // ========================================================
    // Add a raster text row
    // ========================================================

    Future<void> addRow(
      List<String> cells,
      List<double> ratios, {
      List<ui.TextAlign>? aligns,
      bool bold = false,
      double fontSize = 21,
      double bottomGap = 3,
      double minRowHeight = 0,
    }) async {
      final image = await _rasterRow(
        cells: cells,
        ratios: ratios,
        width: width,
        aligns: aligns,
        bold: bold,
        fontSize: fontSize,
        bottomGap: bottomGap,
        minRowHeight: minRowHeight,
      );

      bytes.addAll(
        generator.imageRaster(
          image,
          align: PosAlign.left,
        ),
      );
    }

    // ========================================================
    // Dashed horizontal line
    // ========================================================

    Future<void> addRule() async {
      final picture = ui.PictureRecorder();

      final canvas = ui.Canvas(picture);

      canvas.drawColor(
        const ui.Color(0xFFFFFFFF),
        ui.BlendMode.src,
      );

      final pen = ui.Paint()
        ..color = const ui.Color(0xFF000000)
        ..strokeWidth = 1;

      for (var x = 0.0; x < width.toDouble(); x += 14) {
        canvas.drawLine(
          ui.Offset(x, 8),
          ui.Offset(x + 8, 8),
          pen,
        );
      }

      final bitmap = await picture
          .endRecording()
          .toImage(width, 16);

      bytes.addAll(
        generator.imageRaster(
          await _convert(bitmap),
        ),
      );
    }

    // ========================================================
    // Company Name
    // ========================================================

    final company = _text(
      receipt.querySelector('.company-name'),
    );

    if (company.isNotEmpty) {
      await addRow(
        [company],
        [1],
        aligns: [ui.TextAlign.center],
        bold: true,
        fontSize: 23,
        bottomGap: 6,
      );
    }

    await addRule();

    // ========================================================
    // Invoice Information
    // ========================================================

    final infoRows = receipt.querySelectorAll(
      '.info-table tr',
    );

    for (final row in infoRows) {
      final cells = row
          .querySelectorAll('td')
          .map(_text)
          .toList();

      if (cells.isEmpty) continue;

      if (cells.length == 1) {
        await addRow(
          cells,
          [1],
          aligns: [ui.TextAlign.center],
          bold: true,
          fontSize: 21,
        );
      } else {
        await addRow(
          [
            cells.first,
            cells.skip(1).join('  '),
          ],
          [0.60, 0.40],
          aligns: [
            ui.TextAlign.left,
            ui.TextAlign.right,
          ],
          fontSize: 19,
        );
      }
    }

    await addRule();

    // ========================================================
    // Item Table Header
    // ========================================================

    await addRow(
      ['Qty', 'Item', 'Amount'],
      [0.12, 0.58, 0.30],
      aligns: [
        ui.TextAlign.left,
        ui.TextAlign.left,
        ui.TextAlign.right,
      ],
      bold: true,
      fontSize: 21,
    );

    await addRule();

    // ========================================================
    // Item Details
    // ========================================================

    for (final tr in itemTable.querySelectorAll(
      'tbody tr',
    )) {
      final cells = tr.querySelectorAll('td');

      if (cells.length < 3) continue;

      await addRow(
        [
          _text(cells[0]),
          _text(cells[1]),
          _text(cells[2]),
        ],
        [0.12, 0.58, 0.30],
        aligns: [
          ui.TextAlign.left,
          ui.TextAlign.left,
          ui.TextAlign.right,
        ],
        fontSize: 20,
        bottomGap: 7,
        // Uniform single-line spacing; wrapped rows can grow.
        minRowHeight: 48,
      );
    }

    await addRule();

    // ========================================================
    // Summary
    // Subtotal / Commercial Tax / Service Charges / Net Total
    // ========================================================

    for (final tr in summaryTable.querySelectorAll('tr')) {
      final cells = tr.querySelectorAll('td');

      if (cells.isEmpty) continue;

      final isNetTotal = tr.classes.contains('net-total-row');
      final summaryFontSize = isNetTotal ? 27.0 : 24.0;

      if (cells.length >= 3) {
        await addRow(
          [
            _text(cells[0]),
            _text(cells[1]),
            _text(cells[2]),
          ],
          [0.34, 0.39, 0.27],
          aligns: [
            ui.TextAlign.left,
            ui.TextAlign.right,
            ui.TextAlign.right,
          ],
          bold: isNetTotal,
          fontSize: summaryFontSize,
        );
      } else if (cells.length == 2) {
        await addRow(
          [
            _text(cells[0]),
            _text(cells[1]),
          ],
          [0.7, 0.3],
          aligns: [
            ui.TextAlign.right,
            ui.TextAlign.right,
          ],
          bold: isNetTotal,
          fontSize: summaryFontSize,
        );
      }
    }

    await addRule();

    // ========================================================
    // Feed and Cut
    // ========================================================

    bytes.addAll(generator.feed(2));
    bytes.addAll(generator.cut());

    return bytes;
  }

  // ==========================================================
  // Clean HTML Text
  // ==========================================================

  static String _text(dom.Element? element) {
    if (element == null) return '';

    return element.text
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
  }

  // ==========================================================
  // Raster Text Renderer
  // ==========================================================

  Future<img.Image> _rasterRow({
    required List<String> cells,
    required List<double> ratios,
    required int width,
    List<ui.TextAlign>? aligns,
    required bool bold,
    required double fontSize,
    required double bottomGap,
    required double minRowHeight,
  }) async {
    const horizontalPadding = 4.0;

    final usableWidth = width - horizontalPadding * 2;

    final paragraphs = <ui.Paragraph>[];
    final columnWidths = <double>[];

    var totalHeight = 0.0;

    for (var i = 0; i < cells.length; i++) {
      final columnWidth = usableWidth * ratios[i];

      columnWidths.add(columnWidth);

      final paragraph = (
        ui.ParagraphBuilder(
          ui.ParagraphStyle(
            textAlign: aligns != null && i < aligns.length
                ? aligns[i]
                : ui.TextAlign.left,
          ),
        )
          ..pushStyle(
            ui.TextStyle(
              fontSize: fontSize,
              color: const ui.Color(0xFF000000),

              // Increase font weight without
              // increasing the font size.
              fontWeight: bold
                  ? ui.FontWeight.w900
                  : ui.FontWeight.w600,
            ),
          )
          ..addText(cells[i])
      ).build();

      paragraph.layout(
        ui.ParagraphConstraints(
          width: columnWidth > 4
              ? columnWidth - 4
              : columnWidth,
        ),
      );

      paragraphs.add(paragraph);

      if (paragraph.height > totalHeight) {
        totalHeight = paragraph.height;
      }
    }

    final rawHeight = (
      totalHeight + bottomGap + 8
    ).ceil();

    // Avoid uneven spacing caused by mixed Myanmar/Latin font metrics.
    // Keep wrapped text fully visible rather than clipping it.
    final balancedHeight = rawHeight < minRowHeight
        ? minRowHeight.ceil()
        : rawHeight;

    final int height = balancedHeight < 20
        ? 20
        : (balancedHeight > 3000 ? 3000 : balancedHeight);

    final recorder = ui.PictureRecorder();

    final canvas = ui.Canvas(recorder);

    canvas.drawColor(
      const ui.Color(0xFFFFFFFF),
      ui.BlendMode.src,
    );

    var x = horizontalPadding;

    for (var i = 0; i < paragraphs.length; i++) {
      canvas.drawParagraph(
        paragraphs[i],
        ui.Offset(x, 4),
      );

      x += columnWidths[i];
    }

    final bitmap = await recorder
        .endRecording()
        .toImage(width, height);

    return _convert(bitmap);
  }

  // ==========================================================
  // Image Conversion
  // ==========================================================

  Future<img.Image> _convert(ui.Image bitmap) async {
    final png = await bitmap.toByteData(
      format: ui.ImageByteFormat.png,
    );

    if (png == null) {
      throw StateError(
        'Unable to rasterize cashier receipt.',
      );
    }

    final decoded = img.decodePng(
      png.buffer.asUint8List(),
    );

    if (decoded == null) {
      throw StateError(
        'Unable to decode cashier receipt.',
      );
    }

    // Higher values make more gray pixels black.
    const int blackThreshold = 180;

    for (final pixel in decoded) {
      final r = pixel.r.toInt();
      final g = pixel.g.toInt();
      final b = pixel.b.toInt();

      final gray = (
        0.299 * r +
        0.587 * g +
        0.114 * b
      ).round();

      final color = gray < blackThreshold
          ? 0
          : 255;

      pixel
        ..r = color
        ..g = color
        ..b = color;
    }

    return decoded;
  }
}
