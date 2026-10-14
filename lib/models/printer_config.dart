enum PrinterConnectionType { wifi, bluetooth }

class PrinterConfig {
  const PrinterConfig({
    required this.connectionType,
    required this.paperWidth,
    this.name = 'Kitchen Printer',
    this.ip = '192.168.1.50',
    this.port = 9100,
    this.bluetoothName = '',
    this.bluetoothMac = '',
  });

  final PrinterConnectionType connectionType;
  final int paperWidth;
  final String name;
  final String ip;
  final int port;
  final String bluetoothName;
  final String bluetoothMac;

  PrinterConfig copyWith({
    PrinterConnectionType? connectionType,
    int? paperWidth,
    String? name,
    String? ip,
    int? port,
    String? bluetoothName,
    String? bluetoothMac,
  }) {
    return PrinterConfig(
      connectionType: connectionType ?? this.connectionType,
      paperWidth: paperWidth ?? this.paperWidth,
      name: name ?? this.name,
      ip: ip ?? this.ip,
      port: port ?? this.port,
      bluetoothName: bluetoothName ?? this.bluetoothName,
      bluetoothMac: bluetoothMac ?? this.bluetoothMac,
    );
  }
}
