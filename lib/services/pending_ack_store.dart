import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/print_job.dart';

class PendingPrintAck {
  const PendingPrintAck({
    required this.jobId,
    required this.salesOrder,
    required this.printerName,
    required this.items,
  });

  final String jobId;
  final String salesOrder;
  final String printerName;
  final List<Map<String, dynamic>> items;

  factory PendingPrintAck.fromJob(PrintJob job) {
    return PendingPrintAck(
      jobId: job.jobId,
      salesOrder: job.salesOrder,
      printerName: job.printerName,
      items: job.items.map((item) => item.toAckJson()).toList(),
    );
  }

  Map<String, dynamic> toJson() => {
        'job_id': jobId,
        'sales_order': salesOrder,
        'printer_name': printerName,
        'items': items,
      };

  factory PendingPrintAck.fromJson(Map<String, dynamic> json) {
    final rawItems = (json['items'] as List<dynamic>?) ?? const [];

    return PendingPrintAck(
      jobId: (json['job_id'] ?? '').toString(),
      salesOrder: (json['sales_order'] ?? '').toString(),
      printerName: (json['printer_name'] ?? '').toString(),
      items: rawItems
          .map((item) => Map<String, dynamic>.from(item as Map))
          .toList(),
    );
  }
}

class PendingAckStore {
  static const _key = 'pending_print_acks_v1';

  Future<List<PendingPrintAck>> load() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.reload();
    final raw = prefs.getString(_key);

    if (raw == null || raw.trim().isEmpty) {
      return const [];
    }

    try {
      final decoded = jsonDecode(raw) as List<dynamic>;
      return decoded
          .map(
            (item) => PendingPrintAck.fromJson(
              Map<String, dynamic>.from(item as Map),
            ),
          )
          .where((ack) => ack.jobId.isNotEmpty)
          .toList();
    } catch (_) {
      return const [];
    }
  }

  Future<void> add(PendingPrintAck ack) async {
    final current = await load();

    if (current.any((item) => item.jobId == ack.jobId)) {
      return;
    }

    await _save([...current, ack]);
  }

  Future<void> remove(String jobId) async {
    final current = await load();
    await _save(
      current.where((item) => item.jobId != jobId).toList(),
    );
  }

  Future<Set<String>> jobIds() async {
    final current = await load();
    return current.map((item) => item.jobId).toSet();
  }

  Future<void> _save(List<PendingPrintAck> items) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _key,
      jsonEncode(items.map((item) => item.toJson()).toList()),
    );
  }
}
