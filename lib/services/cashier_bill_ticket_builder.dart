
import 'dart:ui' as ui;

import 'package:esc_pos_utils_plus/esc_pos_utils_plus.dart';
import 'package:html/parser.dart' as html_parser;
import 'package:html/dom.dart' as dom;
import 'package:image/image.dart' as img;

/// Cashier Bill - Professional Thermal Receipt
/// Supports 58mm and 80mm printers.
/// All text is rendered as raster images for Unicode consistency.
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
      throw StateError('Expected a .receipt element in cashier HTML.');
    }

    final itemTable = receipt.querySelector('.item-table');
    final summaryTable = receipt.querySelector('.summary-table');

    if (itemTable == null || summaryTable == null) {
      throw StateError('Cashier HTML is missing item or summary table.');
    }

    final profile = await CapabilityProfile.load();
    final is58mm = paperWidth == 58;
    final width = is58mm ? 384 : 576;

    final generator = Generator(
      is58mm ? PaperSize.mm58 : PaperSize.mm80,
      profile,
    );

    // Font settings
    final companyFont = is58mm ? 22.0 : 26.0;
    final infoFont = is58mm ? 17.0 : 20.0;
    final headerFont = is58mm ? 18.0 : 22.0;
    final itemFont = is58mm ? 17.0 : 21.0;
    final summaryFont = is58mm ? 16.0 : 20.0;
    final grandTotalFont = is58mm ? 19.0 : 24.0;

    final bytes = <int>[];

    Future<void> addRow(
      List<String> cells,
      List<double> ratios, {
      List<ui.TextAlign>? aligns,
      bool bold = false,
      double fontSize = 20,
      double bottomGap = 4,
    }) async {
      final image = await _rasterRow(
        cells: cells,
        ratios: ratios,
        width: width,
        aligns: aligns,
        bold: bold,
        fontSize: fontSize,
        bottomGap: bottomGap,
      );

      bytes.addAll(
        generator.imageRaster(
          image,
          align: PosAlign.left,
        ),
      );
    }

    Future<void> addRule() async {
      final picture = ui.PictureRecorder();
      final canvas = ui.Canvas(picture);

      canvas.drawColor(
        const ui.Color(0xFFFFFFFF),
        ui.BlendMode.src,
      );

      final pen = ui.Paint()
        ..color = const ui.Color(0xFF000000)
        ..strokeWidth = 1.2;

      for (var x = 0.0; x < width.toDouble(); x += 14) {
        canvas.drawLine(
          ui.Offset(x, 8),
          ui.Offset(
            (x + 8).clamp(0.0, width.toDouble()),
            8,
          ),
          pen,
        );
      }

      final bitmap = await picture.endRecording().toImage(
        width,
        16,
      );

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
        fontSize: companyFont,
        bottomGap: 10,
      );
    }

    await addRule();

    // ========================================================
    // Invoice Information
    // ========================================================

    final infoRows = receipt.querySelectorAll('.info-table tr');

    for (final row in infoRows) {
      final cells = row.querySelectorAll('td').map(_text).toList();

      if (cells.isEmpty) continue;

      if (cells.length == 1) {
        await addRow(
          cells,
          [1],
          aligns: [ui.TextAlign.center],
          bold: true,
          fontSize: infoFont,
          bottomGap: 5,
        );
      } else {
        await addRow(
          [cells.first, cells.skip(1).join('  ')],
          [0.60, 0.40],
          aligns: [
            ui.TextAlign.left,
            ui.TextAlign.right,
          ],
          fontSize: infoFont,
          bottomGap: 5,
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
      fontSize: headerFont,
      bottomGap: 6,
    );

    await addRule();

    // ========================================================
    // Item Details
    // ========================================================

    for (final tr in itemTable.querySelectorAll('tbody tr')) {
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
        fontSize: itemFont,
        bottomGap: 8,
      );
    }

    await addRule();

    // ========================================================
    // Summary - Subtotal, VAT, Service Charges, Net Total
    // ========================================================

    for (final tr in summaryTable.querySelectorAll('tr')) {
      final cells = tr.querySelectorAll('td');

      if (cells.isEmpty) continue;

      final isNetTotal = tr.classes.contains('net-total-row');

      if (isNetTotal) {
        await addRule();
      }

      if (cells.length >= 3) {
        await addRow(
          [
            _text(cells[0]),
            _text(cells[1]),
            _text(cells[2]),
          ],
          is58mm
              ? [0.25, 0.47, 0.28]
              : [0.30, 0.43, 0.27],
          aligns: [
            ui.TextAlign.left,
            ui.TextAlign.right,
            ui.TextAlign.right,
          ],
          bold: isNetTotal,
          fontSize: isNetTotal
              ? grandTotalFont
              : summaryFont,
          bottomGap: isNetTotal ? 10 : 5,
        );
      } else if (cells.length == 2) {
        await addRow(
          [
            _text(cells[0]),
            _text(cells[1]),
          ],
          [0.70, 0.30],
          aligns: [
            ui.TextAlign.right,
            ui.TextAlign.right,
          ],
          bold: isNetTotal,
          fontSize: isNetTotal
              ? grandTotalFont
              : summaryFont,
          bottomGap: isNetTotal ? 10 : 5,
        );
      }
    }

    await addRule();

    bytes.addAll(generator.feed(2));
    bytes.addAll(generator.cut());

    return bytes;
  }

  // ==========================================================
  // Extract Clean Text
  // ==========================================================

  static String _text(dom.Element? element) {
    if (element == null) return '';

    return element.text
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
  }

  // ==========================================================
  // Render Receipt Row
  // ==========================================================

  Future<img.Image> _rasterRow({
    required List<String> cells,
    required List<double> ratios,
    required int width,
    List<ui.TextAlign>? aligns,
    required bool bold,
    required double fontSize,
    required double bottomGap,
  }) async {
    const horizontalPadding = 5.0;
    const verticalPadding = 5.0;

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
              fontWeight: bold
                  ? ui.FontWeight.w700
                  : ui.FontWeight.w400,
              height: 1.15,
            ),
          )
          ..addText(cells[i])
      ).build();

      paragraph.layout(
        ui.ParagraphConstraints(
          width: columnWidth > 8
              ? columnWidth - 8
              : columnWidth,
        ),
      );

      paragraphs.add(paragraph);

      if (paragraph.height > totalHeight) {
        totalHeight = paragraph.height;
      }
    }

    final rawHeight = (
      totalHeight + bottomGap + verticalPadding * 2
    ).ceil();

    final height = rawHeight.clamp(20, 3000).toInt();

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
        ui.Offset(x, verticalPadding),
      );

      x += columnWidths[i];
    }

    return _convert(
      await recorder.endRecording().toImage(
        width,
        height,
      ),
    );
  }

  // ==========================================================
  // Convert Flutter Image to ESC/POS Image
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

    final result = img.decodePng(
      png.buffer.asUint8List(),
    );

    if (result == null) {
      throw StateError(
        'Unable to decode cashier receipt.',
      );
    }

    return result;
  }
}
