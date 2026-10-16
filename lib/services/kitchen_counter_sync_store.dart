import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/printer_config.dart';
import 'erpnext_print_service.dart';
import 'printer_settings_store.dart';

class KitchenCounterPrinter {
  const KitchenCounterPrinter(this.counter, this.printerName, this.backup);
  final String counter;
  final String printerName;
  final PrinterConfig? backup;

  factory KitchenCounterPrinter.fromJson(Map<String, dynamic> data) {
    final counter = (data['counter'] ?? '').toString().trim();
    final name = (data['printer_name'] ?? '').toString().trim();
    final type = (data['connection_type'] ?? '').toString();
    final ip = (data['printer_ip'] ?? '').toString();
    final mac = (data['bluetooth_mac'] ?? '').toString();
    final hasBackup = (type == 'Wi-Fi' && ip.isNotEmpty) ||
        (type == 'Bluetooth' && mac.isNotEmpty);
    final widthString = (data['paper_width'] ?? '80mm').toString();
    final width = widthString.startsWith('58') ? 58 : 80;
    final port = int.tryParse((data['printer_port'] ?? 9100).toString()) ?? 9100;
    return KitchenCounterPrinter(
      counter, name,
      hasBackup ? PrinterConfig(
        name: name,
        connectionType: type == 'Bluetooth'
            ? PrinterConnectionType.bluetooth : PrinterConnectionType.wifi,
        paperWidth: width, ip: ip, port: port,
        bluetoothName: (data['bluetooth_name'] ?? '').toString(),
        bluetoothMac: mac,
      ) : null,
    );
  }
}

class KitchenCounterSyncStore {
  static const _cacheKey = 'kitchen_counters_cache_v1';
  static const _queueKey = 'kitchen_printer_sync_queue_v1';

  Future<List<KitchenCounterPrinter>> loadCached() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.reload();
    try {
      final raw = jsonDecode(prefs.getString(_cacheKey) ?? '[]') as List;
      return raw.map((e) => KitchenCounterPrinter.fromJson(
        Map<String, dynamic>.from(e as Map))).toList();
    } catch (_) { return []; }
  }

  Future<void> cache(List<Map<String, dynamic>> counters) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_cacheKey, jsonEncode(counters));
  }

  Future<List<Map<String, String>>> pending() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.reload();
    try {
      return (jsonDecode(prefs.getString(_queueKey) ?? '[]') as List)
          .map((e) => Map<String, String>.from(e as Map)).toList();
    } catch (_) { return []; }
  }

  Future<void> _store(List<Map<String, String>> queue) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_queueKey, jsonEncode(queue));
  }

  Future<void> enqueue(String counter, PrinterConfig? printer) async {
    final queue = await pending();
    queue.removeWhere((job) => job['counter'] == counter);
    queue.add({
      'counter': counter,
      'action': printer == null ? 'delete' : 'save',
      if (printer != null) ...{
        'connection_type': printer.connectionType == PrinterConnectionType.wifi
            ? 'Wi-Fi' : 'Bluetooth',
        'paper_width': '${printer.paperWidth}mm',
        'printer_ip': printer.ip,
        'printer_port': printer.port.toString(),
        'bluetooth_name': printer.bluetoothName,
        'bluetooth_mac': printer.bluetoothMac,
      },
    });
    await _store(queue);
  }

  Future<int> flush(ErpNextPrintService service) async {
    final queue = await pending();
    var done = 0;
    for (final job in List<Map<String, String>>.from(queue)) {
      try {
        await service.syncKitchenCounterPrinter(job);
        queue.removeWhere((q) => q['counter'] == job['counter'] &&
            q['action'] == job['action'] &&
            jsonEncode(q) == jsonEncode(job));
        await _store(queue);
        done++;
      } catch (_) {
        // Keep failed operations for the next login/page refresh.
      }
    }
    return done;
  }

  Future<List<PrinterConfig>> restoreIfEmpty(
    List<KitchenCounterPrinter> counters,
  ) async {
    final settings = PrinterSettingsStore();
    final local = await settings.loadPrinters();
    if (local.isNotEmpty || (await pending()).isNotEmpty) return local;
    final restored = counters
        .where((c) => c.backup != null)
        .map((c) => c.backup!).toList();
    if (restored.isNotEmpty) await settings.savePrinters(restored);
    return restored;
  }
}
