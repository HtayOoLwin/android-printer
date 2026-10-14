import 'package:esc_pos_utils_plus/esc_pos_utils_plus.dart';

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
    required String waiter,
    required List<KitchenTicketItem> items,
    String orderNote = '',
  }) async {
    final profile = await CapabilityProfile.load();
    final paperSize = paperWidth == 58 ? PaperSize.mm58 : PaperSize.mm80;
    final generator = Generator(paperSize, profile);

    final bytes = <int>[];

    bytes.addAll(
      generator.text(
        'KITCHEN ORDER',
        styles: const PosStyles(
          align: PosAlign.center,
          bold: true,
          height: PosTextSize.size2,
          width: PosTextSize.size2,
        ),
      ),
    );
    bytes.addAll(generator.hr());
    bytes.addAll(generator.text('Table No : $tableNumber'));
    bytes.addAll(generator.text('Waiter   : $waiter'));
    bytes.addAll(generator.hr());

    bytes.addAll(
      generator.row([
        PosColumn(
          text: 'QTY',
          width: 2,
          styles: const PosStyles(bold: true),
        ),
        PosColumn(
          text: 'ITEM',
          width: 10,
          styles: const PosStyles(bold: true),
        ),
      ]),
    );
    bytes.addAll(generator.hr());

    for (final item in items) {
      bytes.addAll(
        generator.row([
          PosColumn(
            text: _formatQty(item.qty),
            width: 2,
            styles: const PosStyles(
              bold: true,
              height: PosTextSize.size2,
            ),
          ),
          PosColumn(
            text: item.itemName,
            width: 10,
            styles: const PosStyles(
              bold: true,
              height: PosTextSize.size2,
            ),
          ),
        ]),
      );

      final note = item.kitchenNote.trim();
      if (note.isNotEmpty) {
        bytes.addAll(
          generator.text(
            'Note: $note',
            styles: const PosStyles(align: PosAlign.left),
          ),
        );
      }

      bytes.addAll(generator.feed(1));
    }

    final cleanOrderNote = orderNote.trim();
    if (cleanOrderNote.isNotEmpty) {
      bytes.addAll(generator.hr());
      bytes.addAll(
        generator.text(
          'Order Note:',
          styles: const PosStyles(bold: true),
        ),
      );
      bytes.addAll(generator.text(cleanOrderNote));
    }

    bytes.addAll(generator.hr());
    bytes.addAll(generator.feed(2));
    bytes.addAll(generator.cut());

    return bytes;
  }

  String _formatQty(num qty) {
    if (qty == qty.roundToDouble()) {
      return qty.toInt().toString();
    }
    return qty.toString();
  }
}
