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
    required List<KitchenTicketItem> items,
    String orderNote = '',
  }) async {
    final profile = await CapabilityProfile.load();
    final paperSize = paperWidth == 58 ? PaperSize.mm58 : PaperSize.mm80;
    final generator = Generator(paperSize, profile);

    final bytes = <int>[];

    // Slightly tighter ESC/POS line spacing.
    // ESC 3 n = set line spacing to n dots.
    bytes.addAll([0x1B, 0x33, 18]);

    // Compact kitchen-ticket layout:
    // table, item/qty, kitchen note and order note.
    bytes.addAll(generator.hr(ch: '-'));
    bytes.addAll(
      generator.text(
        tableNumber,
        styles: const PosStyles(
          bold: true,
        ),
      ),
    );
    bytes.addAll(generator.hr(ch: '-'));

    for (final item in items) {
      bytes.addAll(
        generator.text(
          '${_formatQty(item.qty)} x ${item.itemName}',
          styles: const PosStyles(
            bold: true,
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
    bytes.addAll(generator.feed(1));
    // ESC 2 = restore printer default line spacing before cut.
    bytes.addAll([0x1B, 0x32]);
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
