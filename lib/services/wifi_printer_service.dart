import 'dart:io';

class WifiPrinterService {
  Future<void> testConnection({
    required String ip,
    required int port,
  }) async {
    final socket = await Socket.connect(
      ip,
      port,
      timeout: const Duration(seconds: 5),
    );

    await socket.close();
  }

  Future<void> printBytes({
    required String ip,
    required int port,
    required List<int> bytes,
  }) async {
    final socket = await Socket.connect(
      ip,
      port,
      timeout: const Duration(seconds: 5),
    );

    try {
      socket.add(bytes);
      await socket.flush();
    } finally {
      await socket.close();
    }
  }
}
