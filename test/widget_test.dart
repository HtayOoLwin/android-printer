import 'package:flutter_test/flutter_test.dart';
import 'package:android_printer/models/print_job.dart';

void main() {
  test('Kitchen print job parses the server queue contract', () {
    final job = PrintJob.fromJson({
      'job_id': 'SAL-ORD-TEST::Kitchen',
      'sales_order': 'SAL-ORD-TEST',
      'table_number': 'Table 01',
      'printer_name': 'Kitchen',
      'items': [
        {
          'row_name': 'SOITEM-001',
          'item_code': 'K00043',
          'item_name': 'Fried Rice',
          'qty': 2,
          'kitchen_note': '',
        }
      ],
      'order_note': '',
    });

    expect(job.printerName, 'Kitchen');
    expect(job.items.single.qty, 2);
    expect(job.items.single.toAckJson(), {
      'row_name': 'SOITEM-001',
      'qty': 2,
    });
  });
}
