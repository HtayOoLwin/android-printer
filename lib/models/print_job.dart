class PrintJobItem {
  const PrintJobItem({
    required this.rowName,
    required this.itemCode,
    required this.itemName,
    required this.qty,
    required this.kitchenNote,
  });

  final String rowName;
  final String itemCode;
  final String itemName;
  final num qty;
  final String kitchenNote;

  factory PrintJobItem.fromJson(Map<String, dynamic> json) {
    return PrintJobItem(
      rowName: (json['row_name'] ?? '').toString(),
      itemCode: (json['item_code'] ?? '').toString(),
      itemName: (json['item_name'] ?? '').toString(),
      qty: (json['qty'] as num?) ?? 0,
      kitchenNote: (json['kitchen_note'] ?? '').toString(),
    );
  }

  Map<String, dynamic> toAckJson() => {
        'row_name': rowName,
        'qty': qty,
      };
}

class PrintJob {
  const PrintJob({
    required this.jobId,
    required this.salesOrder,
    required this.tableNumber,
    required this.printerName,
    required this.items,
    required this.orderNote,
  });

  final String jobId;
  final String salesOrder;
  final String tableNumber;
  final String printerName;
  final List<PrintJobItem> items;
  final String orderNote;

  factory PrintJob.fromJson(Map<String, dynamic> json) {
    final rawItems = (json['items'] as List<dynamic>?) ?? const [];

    return PrintJob(
      jobId: (json['job_id'] ?? '').toString(),
      salesOrder: (json['sales_order'] ?? '').toString(),
      tableNumber: (json['table_number'] ?? '').toString(),
      printerName: (json['printer_name'] ?? '').toString(),
      items: rawItems
          .map(
            (item) => PrintJobItem.fromJson(
              Map<String, dynamic>.from(item as Map),
            ),
          )
          .toList(),
      orderNote: (json['order_note'] ?? '').toString(),
    );
  }
}
