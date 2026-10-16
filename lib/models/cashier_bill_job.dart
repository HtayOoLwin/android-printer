class CashierBillJob {
  const CashierBillJob({
    required this.name,
    required this.printerName,
    required this.renderMode,
    required this.htmlContent,
  });

  final String name;
  final String printerName;
  final String renderMode;
  final String htmlContent;

  factory CashierBillJob.fromJson(Map<String, dynamic> json) {
    return CashierBillJob(
      name: (json['name'] ?? '').toString(),
      printerName: (json['printer_name'] ?? '').toString(),
      renderMode: (json['render_mode'] ?? '').toString().toUpperCase(),
      htmlContent: (json['html_content'] ?? '').toString(),
    );
  }
}
