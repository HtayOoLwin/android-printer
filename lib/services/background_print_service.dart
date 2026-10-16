import 'dart:async';
import 'dart:ui';

import 'package:flutter_background_service/flutter_background_service.dart';

import '../models/print_job.dart';
import '../models/cashier_bill_job.dart';
import '../models/printer_config.dart';
import 'bluetooth_printer_service.dart';
import 'cashier_bill_ticket_builder.dart';
import 'erpnext_print_service.dart';
import 'kitchen_ticket_builder.dart';
import 'kitchen_counter_sync_store.dart';
import 'pending_ack_store.dart';
import 'printer_settings_store.dart';
import 'server_settings_store.dart';
import 'wifi_printer_service.dart';

const _notificationId = 9017;

Future<void> initializePrinterBackgroundService() async {
  final service = FlutterBackgroundService();

  await service.configure(
    androidConfiguration: AndroidConfiguration(
      onStart: printerBackgroundOnStart,
      autoStart: false,
      isForegroundMode: true,
      initialNotificationTitle: 'BCN Printer Worker',
      initialNotificationContent: 'Ready for auto printing',
      foregroundServiceNotificationId: _notificationId,
      foregroundServiceTypes: const [
        AndroidForegroundType.connectedDevice,
      ],
    ),
    iosConfiguration: IosConfiguration(
      autoStart: false,
      onForeground: printerBackgroundOnStart,
    ),
  );
}

Future<bool> isPrinterBackgroundRunning() {
  return FlutterBackgroundService().isRunning();
}

Future<void> startPrinterBackgroundService() async {
  final service = FlutterBackgroundService();
  final running = await service.isRunning();

  if (!running) {
    await service.startService();
  }
}

void stopPrinterBackgroundService() {
  FlutterBackgroundService().invoke('stopService');
}

Stream<Map<String, dynamic>?> printerBackgroundStatusStream() {
  return FlutterBackgroundService().on('worker_status');
}

@pragma('vm:entry-point')
void printerBackgroundOnStart(ServiceInstance service) async {
  DartPluginRegistrant.ensureInitialized();

  final printerSettingsStore = PrinterSettingsStore();
  final counterSyncStore = KitchenCounterSyncStore();
  final serverSettingsStore = ServerSettingsStore();
  final pendingAckStore = PendingAckStore();
  final wifiService = WifiPrinterService();
  final bluetoothService = BluetoothPrinterService();
  final ticketBuilder = KitchenTicketBuilder();
  final billBuilder = CashierBillTicketBuilder();

  ErpNextPrintService? erpNextService;
  bool processing = false;
  Timer? timer;

  Future<void> emitStatus(
    String message, {
    int? pending,
    bool error = false,
  }) async {
    if (service is AndroidServiceInstance) {
      await service.setForegroundNotificationInfo(
        title: error ? 'BCN Printer Worker - Error' : 'BCN Printer Worker',
        content: message,
      );
    }

    service.invoke(
      'worker_status',
      {
        'message': message,
        'pending': pending,
        'error': error,
        'time': DateTime.now().toIso8601String(),
      },
    );
  }

  Future<ErpNextPrintService> getConnectedService() async {
    if (erpNextService != null && erpNextService!.isLoggedIn) {
      return erpNextService!;
    }

    final settings = await serverSettingsStore.load();

    if (settings.baseUrl.trim().isEmpty ||
        settings.username.trim().isEmpty ||
        settings.password.isEmpty) {
      throw Exception('ERPNext login settings are incomplete.');
    }

    final client = ErpNextPrintService(
      baseUrl: settings.baseUrl,
    );

    await client.login(
      username: settings.username,
      password: settings.password,
    );

    erpNextService = client;
    return client;
  }

  PrinterConfig? findPrinter(
    List<PrinterConfig> printers,
    String printerName,
  ) {
    final target = printerName.trim().toLowerCase();

    for (final printer in printers) {
      if (printer.name.trim().toLowerCase() == target) {
        return printer;
      }
    }

    return null;
  }

  Future<void> printJob(
    PrintJob job,
    PrinterConfig printer,
  ) async {
    final bytes = await ticketBuilder.build(
      paperWidth: printer.paperWidth,
      tableNumber: job.tableNumber,
      items: job.items
          .map(
            (item) => KitchenTicketItem(
              itemName: item.itemName,
              qty: item.qty,
              kitchenNote: item.kitchenNote,
            ),
          )
          .toList(),
      orderNote: job.orderNote,
    );

    if (printer.connectionType == PrinterConnectionType.wifi) {
      await wifiService.printBytes(
        ip: printer.ip,
        port: printer.port,
        bytes: bytes,
      );
      return;
    }

    if (printer.bluetoothMac.isEmpty) {
      throw Exception(
        'Bluetooth MAC address is missing for ${printer.name}.',
      );
    }

    await bluetoothService.printBytes(
      macAddress: printer.bluetoothMac,
      bytes: bytes,
    );
  }

  Future<void> printCashierBill(
    CashierBillJob job,
    PrinterConfig printer,
  ) async {
    if (job.renderMode != 'HTML') {
      throw StateError('Unsupported cashier bill mode: ${job.renderMode}');
    }
    final bytes = await billBuilder.build(
      htmlContent: job.htmlContent,
      paperWidth: printer.paperWidth,
    );
    if (printer.connectionType == PrinterConnectionType.wifi) {
      await wifiService.printBytes(
        ip: printer.ip,
        port: printer.port,
        bytes: bytes,
      );
    } else {
      if (printer.bluetoothMac.isEmpty) {
        throw StateError('Missing Bluetooth MAC for cashier printer.');
      }
      await bluetoothService.printBytes(
        macAddress: printer.bluetoothMac,
        bytes: bytes,
      );
    }
  }

  Future<void> runCashierCycle(
    ErpNextPrintService client,
    List<PrinterConfig> printers,
  ) async {
    // Only claim bills when an explicitly saved Cashier printer exists.
    final cashier = findPrinter(printers, 'Cashier');
    if (cashier == null) return;
    final job = await client.claimCashierBill([cashier.name]);
    if (job == null) return;
    try {
      await emitStatus('Printing cashier bill ${job.name}');
      await printCashierBill(job, cashier);
    } catch (error) {
      await client.reportCashierBillResult(
        jobName: job.name,
        status: 'Failed',
        errorMessage: error.toString(),
      );
      rethrow;
    }
    // Never send a failure report if printing succeeded but ACK failed:
    // the physical paper may have printed. Server timeout needs manual review.
    await client.reportCashierBillResult(
      jobName: job.name,
      status: 'Printed',
    );
  }

  Future<void> flushPendingAcks(
    ErpNextPrintService client,
  ) async {
    final pendingAcks = await pendingAckStore.load();

    for (final ack in pendingAcks) {
      await client.markPrintedValues(
        salesOrder: ack.salesOrder,
        printerName: ack.printerName,
        items: ack.items,
      );

      await pendingAckStore.remove(ack.jobId);
    }
  }

  Future<void> runCycle() async {
    if (processing) {
      return;
    }

    processing = true;

    try {
      final client = await getConnectedService();
      // Retry queued printer settings independently of print jobs.
      await counterSyncStore.flush(client);

      // Important: ACK first. If a ticket already reached the printer but the
      // previous server acknowledgement failed, retry the ACK instead of
      // printing the same ticket again.
      await flushPendingAcks(client);

      final printers = await printerSettingsStore.loadPrinters();
      final jobs = await client.getPendingJobs();
      final waitingAckIds = await pendingAckStore.jobIds();

      var printed = 0;
      var failed = 0;
      String? lastError;

      for (final job in jobs) {
        if (waitingAckIds.contains(job.jobId)) {
          continue;
        }

        final printer = findPrinter(
          printers,
          job.printerName,
        );

        if (printer == null) {
          failed += 1;
          lastError =
              '${job.jobId}: saved printer "${job.printerName}" not found';
          continue;
        }

        try {
          await emitStatus(
            'Printing ${job.tableNumber} → ${printer.name}',
            pending: jobs.length,
          );

          await printJob(job, printer);

          // Persist the successful printer write before calling ERPNext.
          // If the network drops during ACK, the next cycle retries only ACK.
          final ack = PendingPrintAck.fromJob(job);
          await pendingAckStore.add(ack);

          await client.markPrintedValues(
            salesOrder: ack.salesOrder,
            printerName: ack.printerName,
            items: ack.items,
          );

          await pendingAckStore.remove(job.jobId);
          printed += 1;
        } catch (error) {
          failed += 1;
          lastError =
              '${job.jobId}: ${error.toString().replaceFirst('Exception: ', '')}';
        }
      }

      try {
        await runCashierCycle(client, printers);
      } catch (error) {
        failed += 1;
        lastError = 'Cashier bill: $error';
      }

      final remaining = await client.getPendingJobs();

      if (failed > 0) {
        await emitStatus(
          'Printed $printed, failed $failed, pending ${remaining.length}. '
          '${lastError ?? ''}',
          pending: remaining.length,
          error: true,
        );
      } else {
        await emitStatus(
          'Running • Printed $printed • Pending ${remaining.length}',
          pending: remaining.length,
        );
      }
    } catch (error) {
      final message = error.toString().replaceFirst('Exception: ', '');

      if (message.contains('session expired') ||
          message.contains('not logged in')) {
        erpNextService = null;
      }

      await emitStatus(
        message,
        error: true,
      );
    } finally {
      processing = false;
    }
  }

  service.on('stopService').listen((event) async {
    timer?.cancel();
    await bluetoothService.disconnect();
    service.stopSelf();
  });

  if (service is AndroidServiceInstance) {
    await service.setAsForegroundService();
  }

  await emitStatus('Auto Print started.');

  timer = Timer.periodic(
    const Duration(seconds: 5),
    (_) => runCycle(),
  );

  await runCycle();
}
