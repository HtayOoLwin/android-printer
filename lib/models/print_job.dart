class PrintJobItem {
  const PrintJobItem({
    required this.rowName,
    required this.itemCode,
    required this.itemName,
    required this.qty,
    required this.kitchenNote,
    this.isFoc = false,
    this.isParcel = false,
  });

  final String rowName;
  final String itemCode;
  final String itemName;
  final num qty;
  final String kitchenNote;
  final bool isFoc;
  final bool isParcel;

  static bool _flag(dynamic value) =>
      value == true || value == 1 ||
      (value is String && ['1', 'true', 'yes'].contains(value.trim().toLowerCase()));

  factory PrintJobItem.fromJson(Map<String, dynamic> json) {
    return PrintJobItem(
      rowName: (json['row_name'] ?? '').toString(),
      itemCode: (json['item_code'] ?? '').toString(),
      itemName: (json['item_name'] ?? '').toString(),
      qty: (json['qty'] as num?) ?? 0,
      kitchenNote: (json['kitchen_note'] ?? '').toString(),
      isFoc: _flag(json['custom_foc'] ?? json['foc']),
      isParcel: _flag(json['custom_parcel'] ?? json['parcel']),
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
    this.waiterName = '',
    this.orderDateTime = '',
    required this.printerName,
    required this.items,
    required this.orderNote,
  });

  final String jobId;
  final String salesOrder;
  final String tableNumber;
  final String waiterName;
  final String orderDateTime;
  final String printerName;
  final List<PrintJobItem> items;
  final String orderNote;

  factory PrintJob.fromJson(Map<String, dynamic> json) {
    final rawItems = (json['items'] as List<dynamic>?) ?? const [];

    return PrintJob(
      jobId: (json['job_id'] ?? '').toString(),
      salesOrder: (json['sales_order'] ?? '').toString(),
      tableNumber: (json['table_number'] ?? '').toString(),
      // New API fields; keep older payloads backward-compatible.
      waiterName: (json['waiter_name'] ?? json['waiter'] ?? '').toString(),
      orderDateTime: (json['order_datetime'] ?? json['ordered_at'] ?? '').toString(),
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
