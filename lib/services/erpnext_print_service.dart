import 'dart:convert';
import 'dart:io';

import '../models/print_job.dart';

class ErpNextPrintService {
  ErpNextPrintService({
    required String baseUrl,
  }) : baseUrl = baseUrl.replaceAll(RegExp(r'/+$'), '');

  final String baseUrl;
  String? _sid;

  bool get isLoggedIn => _sid != null && _sid!.isNotEmpty;

  Future<void> login({
    required String username,
    required String password,
  }) async {
    final client = HttpClient();
    try {
      final request = await client.postUrl(
        Uri.parse('$baseUrl/api/method/login'),
      );
      request.headers.contentType =
          ContentType('application', 'x-www-form-urlencoded', charset: 'utf-8');
      request.write(
        'usr=${Uri.encodeQueryComponent(username)}'
        '&pwd=${Uri.encodeQueryComponent(password)}',
      );

      final response = await request.close();
      final body = await response.transform(utf8.decoder).join();

      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw Exception(
          'ERPNext login failed (${response.statusCode}): ${_extractError(body)}',
        );
      }

      String? sid;
      for (final cookie in response.cookies) {
        if (cookie.name == 'sid') {
          sid = cookie.value;
          break;
        }
      }

      if (sid == null || sid.isEmpty) {
        throw Exception('ERPNext login succeeded but session ID was not returned.');
      }

      _sid = sid;
    } finally {
      client.close(force: true);
    }
  }

  Future<List<PrintJob>> getPendingJobs() async {
    final response = await _requestJson(
      method: 'GET',
      path: '/api/method/bcn_get_pending_print_jobs',
    );

    final message = response['message'];
    if (message is! Map) {
      return const [];
    }

    final rawJobs = message['jobs'];
    if (rawJobs is! List) {
      return const [];
    }

    return rawJobs
        .map(
          (job) => PrintJob.fromJson(
            Map<String, dynamic>.from(job as Map),
          ),
        )
        .toList();
  }

  Future<void> markPrinted(PrintJob job) async {
    await _requestJson(
      method: 'POST',
      path: '/api/method/bcn_update_print_job',
      form: {
        'sales_order': job.salesOrder,
        'printer_name': job.printerName,
        'success': '1',
        'items': jsonEncode(
          job.items.map((item) => item.toAckJson()).toList(),
        ),
      },
    );
  }

  Future<Map<String, dynamic>> _requestJson({
    required String method,
    required String path,
    Map<String, String>? form,
  }) async {
    if (!isLoggedIn) {
      throw Exception('ERPNext is not logged in.');
    }

    final client = HttpClient();
    try {
      final uri = Uri.parse('$baseUrl$path');
      final HttpClientRequest request;

      if (method == 'POST') {
        request = await client.postUrl(uri);
      } else {
        request = await client.getUrl(uri);
      }

      request.cookies.add(Cookie('sid', _sid!));

      if (form != null) {
        request.headers.contentType =
            ContentType('application', 'x-www-form-urlencoded', charset: 'utf-8');

        request.write(
          form.entries
              .map(
                (entry) =>
                    '${Uri.encodeQueryComponent(entry.key)}='
                    '${Uri.encodeQueryComponent(entry.value)}',
              )
              .join('&'),
        );
      }

      final response = await request.close();
      final body = await response.transform(utf8.decoder).join();

      if (response.statusCode == 401 || response.statusCode == 403) {
        _sid = null;
        throw Exception('ERPNext session expired. Please login again.');
      }

      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw Exception(
          'ERPNext API error (${response.statusCode}): ${_extractError(body)}',
        );
      }

      if (body.trim().isEmpty) {
        return <String, dynamic>{};
      }

      return Map<String, dynamic>.from(jsonDecode(body) as Map);
    } finally {
      client.close(force: true);
    }
  }

  String _extractError(String body) {
    try {
      final data = jsonDecode(body);
      if (data is Map) {
        final message = data['message'] ??
            data['exception'] ??
            data['_server_messages'];
        if (message != null) {
          return message.toString();
        }
      }
    } catch (_) {
      // Fall back to raw text below.
    }

    final clean = body.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (clean.isEmpty) {
      return 'Unknown server error';
    }

    return clean.length > 300 ? clean.substring(0, 300) : clean;
  }
}
