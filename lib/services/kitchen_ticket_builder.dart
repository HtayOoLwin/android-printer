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

    // Compact kitchen-ticket layout based on the user's sample print:
    // no title, only table, waiter, item/qty, kitchen note and order note.
    bytes.addAll(generator.hr(ch: '-'));
    bytes.addAll(
      generator.text(
        tableNumber,
        styles: const PosStyles(
          bold: true,
          height: PosTextSize.size2,
          width: PosTextSize.size2,
        ),
      ),
    );
    bytes.addAll(
      generator.text(
        'Waiter: $waiter',
        styles: const PosStyles(bold: true),
      ),
    );
    bytes.addAll(generator.hr(ch: '-'));

    for (final item in items) {
      bytes.addAll(
        generator.text(
          '${_formatQty(item.qty)} x ${item.itemName}',
          styles: const PosStyles(
            bold: true,
            height: PosTextSize.size2,
          ),
        ),
      );

      final note = item.kitchenNote.trim();
      if (note.isNotEmpty) {
        bytes.addAll(
          generator.text(
            '  $note',
            styles: const PosStyles(bold: true),
          ),
        );
      }

      bytes.addAll(generator.feed(1));
    }

    final cleanOrderNote = orderNote.trim();
    if (cleanOrderNote.isNotEmpty) {
      bytes.addAll(generator.hr(ch: '-'));
      bytes.addAll(
        generator.text(
          'Order Note: $cleanOrderNote',
          styles: const PosStyles(bold: true),
        ),
      );
    }

    bytes.addAll(generator.hr(ch: '-'));
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
