import 'package:flutter_test/flutter_test.dart';
import 'package:android_printer/models/print_job.dart';
import 'package:android_printer/services/kitchen_ticket_builder.dart';

void main() {
  test('UOM is parsed without changing numeric acknowledgement quantity', () {
    final item = PrintJobItem.fromJson({
      'row_name': 'row-1', 'qty': 2.0, 'uom': ' Glass ',
      'item_name': 'Draft Beer', 'custom_foc': 1, 'custom_parcel': 1,
    });
    expect(item.uom, 'Glass');
    expect(item.toAckJson(), {'row_name': 'row-1', 'qty': 2.0});
    expect(KitchenTicketItem(
      itemName: item.itemName, qty: item.qty, uom: item.uom,
      isFoc: item.isFoc, isParcel: item.isParcel,
    ).printLine, '2 Glass x Draft Beer [FOC / PC]');
  });
  test('legacy payload and fractional quantities remain printable', () {
    final item = PrintJobItem.fromJson({'qty': 1, 'item_name': 'Rice'});
    expect(item.uom, '');
    expect(KitchenTicketItem(itemName: item.itemName, qty: item.qty,
      uom: item.uom).printLine, '1 x Rice');
    expect(const KitchenTicketItem(itemName: 'Meat', qty: 1.5,
      uom: ' Kg ', isParcel: true).printLine, '1.5 Kg x Meat [PC]');
    expect(const KitchenTicketItem(itemName: 'Beer', qty: 2,
      uom: 'Bottle', isFoc: true).printLine, '2 Bottle x Beer [FOC]');
  });
}
