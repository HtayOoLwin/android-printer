import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/printer_config.dart';

class PrinterSettingsStore {
  static const _printersKey = 'saved_printers_v1';

  Future<List<PrinterConfig>> loadPrinters() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.reload();
    final raw = prefs.getString(_printersKey);

    if (raw == null || raw.trim().isEmpty) {
      return const [];
    }

    try {
      final decoded = jsonDecode(raw) as List<dynamic>;
      return decoded
          .map(
            (item) => PrinterConfig.fromJson(
              Map<String, dynamic>.from(item as Map),
            ),
          )
          .toList();
    } catch (_) {
      return const [];
    }
  }

  Future<void> savePrinters(List<PrinterConfig> printers) async {
    final prefs = await SharedPreferences.getInstance();
    final encoded = jsonEncode(
      printers.map((printer) => printer.toJson()).toList(),
    );
    await prefs.setString(_printersKey, encoded);
  }
}
