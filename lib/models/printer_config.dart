enum PrinterConnectionType { wifi, bluetooth }

class PrinterConfig {
  const PrinterConfig({
    required this.name,
    required this.connectionType,
    required this.paperWidth,
    this.ip = '',
    this.port = 9100,
    this.bluetoothName = '',
    this.bluetoothMac = '',
  });

  final String name;
  final PrinterConnectionType connectionType;
  final int paperWidth;
  final String ip;
  final int port;
  final String bluetoothName;
  final String bluetoothMac;

  PrinterConfig copyWith({
    String? name,
    PrinterConnectionType? connectionType,
    int? paperWidth,
    String? ip,
    int? port,
    String? bluetoothName,
    String? bluetoothMac,
  }) {
    return PrinterConfig(
      name: name ?? this.name,
      connectionType: connectionType ?? this.connectionType,
      paperWidth: paperWidth ?? this.paperWidth,
      ip: ip ?? this.ip,
      port: port ?? this.port,
      bluetoothName: bluetoothName ?? this.bluetoothName,
      bluetoothMac: bluetoothMac ?? this.bluetoothMac,
    );
  }

  Map<String, dynamic> toJson() => {
        'name': name,
        'connection_type': connectionType.name,
        'paper_width': paperWidth,
        'ip': ip,
        'port': port,
        'bluetooth_name': bluetoothName,
        'bluetooth_mac': bluetoothMac,
      };

  factory PrinterConfig.fromJson(Map<String, dynamic> json) {
    return PrinterConfig(
      name: (json['name'] ?? 'Printer').toString(),
      connectionType: json['connection_type'] == 'bluetooth'
          ? PrinterConnectionType.bluetooth
          : PrinterConnectionType.wifi,
      paperWidth: (json['paper_width'] as num?)?.toInt() ?? 80,
      ip: (json['ip'] ?? '').toString(),
      port: (json['port'] as num?)?.toInt() ?? 9100,
      bluetoothName: (json['bluetooth_name'] ?? '').toString(),
      bluetoothMac: (json['bluetooth_mac'] ?? '').toString(),
    );
  }
}
