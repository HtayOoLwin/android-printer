import 'package:shared_preferences/shared_preferences.dart';

class PrinterSettingsStore {
  static const _connectionKey = 'connection_type';
  static const _ipKey = 'printer_ip';
  static const _portKey = 'printer_port';
  static const _paperWidthKey = 'paper_width';
  static const _bluetoothNameKey = 'bluetooth_name';
  static const _bluetoothMacKey = 'bluetooth_mac';

  Future<Map<String, Object?>> load() async {
    final prefs = await SharedPreferences.getInstance();

    return {
      'connection_type': prefs.getString(_connectionKey) ?? 'wifi',
      'printer_ip': prefs.getString(_ipKey) ?? '192.168.1.50',
      'printer_port': prefs.getInt(_portKey) ?? 9100,
      'paper_width': prefs.getInt(_paperWidthKey) ?? 80,
      'bluetooth_name': prefs.getString(_bluetoothNameKey) ?? '',
      'bluetooth_mac': prefs.getString(_bluetoothMacKey) ?? '',
    };
  }

  Future<void> save({
    required String connectionType,
    required String ip,
    required int port,
    required int paperWidth,
    required String bluetoothName,
    required String bluetoothMac,
  }) async {
    final prefs = await SharedPreferences.getInstance();

    await prefs.setString(_connectionKey, connectionType);
    await prefs.setString(_ipKey, ip);
    await prefs.setInt(_portKey, port);
    await prefs.setInt(_paperWidthKey, paperWidth);
    await prefs.setString(_bluetoothNameKey, bluetoothName);
    await prefs.setString(_bluetoothMacKey, bluetoothMac);
  }
}
