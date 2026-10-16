import 'dart:async';

import 'package:flutter/material.dart';

import 'models/print_job.dart';
import 'models/printer_config.dart';
import 'services/background_print_service.dart';
import 'services/bluetooth_printer_service.dart';
import 'services/erpnext_print_service.dart';
import 'services/kitchen_ticket_builder.dart';
import 'services/kitchen_counter_sync_store.dart';
import 'services/pending_ack_store.dart';
import 'services/printer_settings_store.dart';
import 'services/server_settings_store.dart';
import 'services/wifi_printer_service.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await initializePrinterBackgroundService();
  runApp(const BcnPrinterApp());
}

class BcnPrinterApp extends StatelessWidget {
  const BcnPrinterApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'BCN Printer Worker',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF1565C0)),
        useMaterial3: true,
      ),
      home: const PrinterWorkerScreen(),
    );
  }
}

class PrinterWorkerScreen extends StatefulWidget {
  const PrinterWorkerScreen({super.key});

  @override
  State<PrinterWorkerScreen> createState() => _PrinterWorkerScreenState();
}

class _PrinterWorkerScreenState extends State<PrinterWorkerScreen> {
  final _wifiService = WifiPrinterService();
  final _bluetoothService = BluetoothPrinterService();
  final _ticketBuilder = KitchenTicketBuilder();
  final _printerSettingsStore = PrinterSettingsStore();
  final _counterSyncStore = KitchenCounterSyncStore();
  final _serverSettingsStore = ServerSettingsStore();
  final _pendingAckStore = PendingAckStore();

  final _nameController = TextEditingController(text: 'Kitchen');
  final _ipController = TextEditingController(text: '192.168.0.90');
  final _portController = TextEditingController(text: '9100');

  final _serverUrlController = TextEditingController(
    text: 'https://ourcity.s.frappe.cloud',
  );
  final _usernameController = TextEditingController();
  final _passwordController = TextEditingController();

  List<KitchenCounterPrinter> _kitchenCounters = const [];

  List<String> get _printerNameOptions {
    // Names always come from ERPNext (or its last successfully fetched cache).
    return _kitchenCounters.map((c) => c.printerName)
        .where((name) => name.isNotEmpty).toSet().toList();
  }

  String? _counterForName(String name) {
    for (final counter in _kitchenCounters) {
      if (counter.printerName == name) return counter.counter;
    }
    return null;
  }

  Future<void> _refreshKitchenCounters({bool restore = false}) async {
    final service = _erpNextService;
    var counters = await _counterSyncStore.loadCached();
    if (service != null && service.isLoggedIn) {
      try {
        // Retry local changes before reading server backups.
        await _counterSyncStore.flush(service);
        final rows = await service.getKitchenCounters();
        await _counterSyncStore.cache(rows);
        counters = rows.map(KitchenCounterPrinter.fromJson)
            .where((c) => c.counter.isNotEmpty && c.printerName.isNotEmpty)
            .toList();
      } catch (error) {
        _setStatus('Kitchen Counters: offline cache in use. $error');
      }
    }
    if (restore && service != null && service.isLoggedIn) {
      final restored = await _counterSyncStore.restoreIfEmpty(counters);
      if (mounted) _savedPrinters = restored;
    }
    if (!mounted) return;
    setState(() {
      _kitchenCounters = counters;
      if (_printerNameOptions.isNotEmpty &&
          !_printerNameOptions.contains(_nameController.text.trim())) {
        _nameController.text = _printerNameOptions.first;
      }
    });
  }

  PrinterConnectionType _connectionType = PrinterConnectionType.wifi;
  int _paperWidth = 80;
  List<BluetoothPrinterDevice> _bluetoothDevices = const [];
  BluetoothPrinterDevice? _selectedBluetoothDevice;
  List<PrinterConfig> _savedPrinters = const [];
  int? _editingIndex;

  ErpNextPrintService? _erpNextService;
  StreamSubscription<Map<String, dynamic>?>? _backgroundStatusSubscription;

  bool _busy = false;
  bool _initializing = true;
  int _pageIndex = 0;
  bool _serverLoggedIn = false;
  bool _rememberMe = true;
  bool _autoPrint = false;
  int _pendingCount = 0;
  Timer? _printerStatusTimer;
  bool _checkingPrinterStatus = false;
  Map<String, String> _printerStates = {};
  String _status = 'Ready';

  @override
  void initState() {
    super.initState();
    _loadInitialSettings();
    _printerStatusTimer = Timer.periodic(const Duration(seconds: 30), (_) {
      if (_serverLoggedIn && _pageIndex == 0) _checkPrinterStatuses();
    });
  }

  @override
  void dispose() {
    _backgroundStatusSubscription?.cancel();
    _printerStatusTimer?.cancel();
    _nameController.dispose();
    _ipController.dispose();
    _portController.dispose();
    _serverUrlController.dispose();
    _usernameController.dispose();
    _passwordController.dispose();
    _bluetoothService.disconnect();
    super.dispose();
  }

  Future<void> _loadInitialSettings() async {
    final printers = await _printerSettingsStore.loadPrinters();
    final cachedCounters = await _counterSyncStore.loadCached();
    final server = await _serverSettingsStore.load();
    final backgroundRunning = await isPrinterBackgroundRunning();

    _backgroundStatusSubscription?.cancel();
    _backgroundStatusSubscription =
        printerBackgroundStatusStream().listen((event) {
      if (!mounted || event == null) return;

      final message = (event['message'] ?? '').toString();
      final pending = event['pending'];

      setState(() {
        if (message.isNotEmpty) {
          _status = message;
        }

        if (pending is num) {
          _pendingCount = pending.toInt();
        }

        _autoPrint = true;
      });
    });

    if (!mounted) return;

    setState(() {
      _savedPrinters = printers;
      _kitchenCounters = cachedCounters;
      _serverUrlController.text = server.baseUrl;
      _usernameController.text = server.username;
      _passwordController.text = server.password;
      _autoPrint = backgroundRunning;
      _rememberMe = server.rememberMe;
    });

    if (server.rememberMe && server.username.isNotEmpty &&
        server.password.isNotEmpty && server.baseUrl.isNotEmpty) {
      await _loginServer(silent: true);
    }
    if (mounted) setState(() => _initializing = false);
  }

  Future<void> _loginServer({bool silent = false}) async {
    await _runAction(() async {
      final baseUrl = _serverUrlController.text.trim();
      final username = _usernameController.text.trim();
      final password = _passwordController.text;

      if (baseUrl.isEmpty || username.isEmpty || password.isEmpty) {
        throw Exception('Server URL, username and password are required.');
      }

      final service = ErpNextPrintService(baseUrl: baseUrl);
      _setStatus('Logging in to ERPNext ...');

      await service.login(
        username: username,
        password: password,
      );

      _erpNextService = service;

      await _serverSettingsStore.save(ServerSettings(
        baseUrl: baseUrl,
        username: username,
        password: password,
        rememberMe: _rememberMe,
      ));

      if (!mounted) return;
      setState(() {
        _serverLoggedIn = true;
        _pageIndex = 0;
      });

      _setStatus(silent ? 'Auto login successful.' : 'ERPNext login successful.');
      await _refreshKitchenCounters(restore: true);
      await _checkPrinterStatuses();
      await _refreshPendingCount();
    });
  }

  Future<void> _checkPrinterStatuses() async {
    if (_checkingPrinterStatus || !mounted) {
      return;
    }
    _checkingPrinterStatus = true;
    final printers = List<PrinterConfig>.from(_savedPrinters);
    final results = <String, String>{};
    if (mounted) {
      setState(() {
        _printerStates = {for (final p in printers) p.name: 'Checking'};
      });
    }
    try {
      // Do not connect/disconnect Bluetooth devices here. The background
      // printing isolate may be using the connection.
      bool btEnabled = false;
      try { btEnabled = await _bluetoothService.isBluetoothEnabled(); }
      catch (_) {}
      for (final printer in printers) {
        if (printer.connectionType == PrinterConnectionType.wifi) {
          try {
            await _wifiService.testConnection(ip: printer.ip, port: printer.port);
            results[printer.name] = 'Connected';
          } catch (_) {
            results[printer.name] = 'Offline';
          }
        } else {
          results[printer.name] = printer.bluetoothMac.isEmpty
              ? 'Not Configured'
              : (btEnabled ? 'Bluetooth - not verified' : 'Bluetooth Off');
        }
      }
      if (mounted) {
        setState(() => _printerStates = results);
      }
    } finally {
      _checkingPrinterStatus = false;
    }
  }

  Future<void> _refreshPendingCount() async {
    final service = _erpNextService;
    if (service == null || !service.isLoggedIn) {
      throw Exception('Login to ERPNext first.');
    }

    final jobs = await service.getPendingJobs();

    if (!mounted) return;
    setState(() {
      _pendingCount = jobs.length;
    });

    _setStatus('Pending print jobs: ${jobs.length}');
  }

  Future<void> _printPendingJobs() async {
    final service = _erpNextService;
    if (service == null || !service.isLoggedIn) {
      throw Exception('Login to ERPNext first.');
    }

    final jobs = await service.getPendingJobs();

    if (!mounted) return;
    setState(() {
      _pendingCount = jobs.length;
    });

    if (jobs.isEmpty) {
      _setStatus('No pending print jobs.');
      return;
    }

    var successCount = 0;
    final errors = <String>[];

    for (final job in jobs) {
      try {
        final printer = _findPrinter(job.printerName);

        if (printer == null) {
          errors.add(
            '${job.jobId}: saved printer "${job.printerName}" not found',
          );
          continue;
        }

        _setStatus(
          'Printing ${job.tableNumber} → ${printer.name} ...',
        );

        await _printJob(job, printer);

        // Persist ACK before calling ERPNext. If the printer succeeds but the
        // network drops during ACK, background retry will send only the ACK
        // instead of printing the same ticket again.
        final ack = PendingPrintAck.fromJob(job);
        await _pendingAckStore.add(ack);

        await service.markPrintedValues(
          salesOrder: ack.salesOrder,
          printerName: ack.printerName,
          items: ack.items,
        );

        await _pendingAckStore.remove(job.jobId);
        successCount += 1;
      } catch (error) {
        errors.add(
          '${job.jobId}: ${error.toString().replaceFirst('Exception: ', '')}',
        );
      }
    }

    final remaining = await service.getPendingJobs();

    if (!mounted) return;
    setState(() {
      _pendingCount = remaining.length;
    });

    if (errors.isEmpty) {
      _setStatus(
        'Printed $successCount job(s). Pending: ${remaining.length}',
      );
    } else {
      _setStatus(
        'Printed $successCount job(s). '
        '${errors.length} failed. '
        'Pending: ${remaining.length}. '
        'Last error: ${errors.last}',
      );
    }
  }

  PrinterConfig? _findPrinter(String printerName) {
    final target = printerName.trim().toLowerCase();

    for (final printer in _savedPrinters) {
      if (printer.name.trim().toLowerCase() == target) {
        return printer;
      }
    }

    return null;
  }

  Future<void> _printJob(
    PrintJob job,
    PrinterConfig printer,
  ) async {
    final bytes = await _ticketBuilder.build(
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
      await _wifiService.printBytes(
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

    await _bluetoothService.printBytes(
      macAddress: printer.bluetoothMac,
      bytes: bytes,
    );
  }

  Future<void> _setAutoPrint(bool enabled) async {
    if (!enabled) {
      stopPrinterBackgroundService();

      if (!mounted) return;
      setState(() {
        _autoPrint = false;
      });
      _setStatus('Background Auto Print stopped.');
      return;
    }

    if (!_serverLoggedIn) {
      setState(() {
        _autoPrint = false;
      });
      _setStatus('Login to ERPNext before enabling Auto Print.');
      return;
    }

    try {
      await startPrinterBackgroundService();

      if (!mounted) return;
      setState(() {
        _autoPrint = true;
      });

      _setStatus(
        'Background Auto Print started. You can minimize the app.',
      );
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _autoPrint = false;
      });

      _setStatus(
        'Auto Print error: ${error.toString().replaceFirst('Exception: ', '')}',
      );
    }
  }

  Future<void> _loadPairedBluetoothDevices() async {
    await _runAction(() async {
      final enabled = await _bluetoothService.isBluetoothEnabled();
      if (!enabled) {
        throw Exception('Bluetooth is turned off.');
      }

      final devices = await _bluetoothService.pairedDevices();

      if (!mounted) return;

      setState(() {
        _bluetoothDevices = devices;

        if (_selectedBluetoothDevice != null) {
          final matches = devices.where(
            (device) => device.mac == _selectedBluetoothDevice!.mac,
          );

          if (matches.isNotEmpty) {
            _selectedBluetoothDevice = matches.first;
          }
        }
      });

      _setStatus(
        devices.isEmpty
            ? 'No paired Bluetooth printers found.'
            : 'Found ${devices.length} paired Bluetooth device(s).',
      );
    });
  }

  PrinterConfig _currentConfig() {
    final name = _nameController.text.trim();

    if (name.isEmpty || _counterForName(name) == null) {
      throw Exception('Select an ERPNext Kitchen Counter.');
    }

    final port = int.tryParse(_portController.text.trim()) ?? 9100;

    if (_connectionType == PrinterConnectionType.wifi) {
      final ip = _ipController.text.trim();

      if (ip.isEmpty) {
        throw Exception('Enter printer IP.');
      }

      return PrinterConfig(
        name: name,
        connectionType: _connectionType,
        paperWidth: _paperWidth,
        ip: ip,
        port: port,
      );
    }

    final device = _selectedBluetoothDevice;

    if (device == null) {
      throw Exception('Select a paired Bluetooth printer.');
    }

    return PrinterConfig(
      name: name,
      connectionType: _connectionType,
      paperWidth: _paperWidth,
      bluetoothName: device.name,
      bluetoothMac: device.mac,
    );
  }

  Future<void> _savePrinter() async {
    await _runAction(() async {
      final config = _currentConfig();
      final counter = _counterForName(config.name);
      if (counter == null) throw Exception('Kitchen Counter not found.');
      final updated = List<PrinterConfig>.from(_savedPrinters);
      final duplicate = updated.indexWhere((p) => p.name == config.name);
      if (duplicate != -1 && duplicate != _editingIndex) {
        throw Exception('This Kitchen Counter already has a saved printer.');
      }
      String? previousCounter;
      if (_editingIndex != null) {
        previousCounter = _counterForName(updated[_editingIndex!].name);
        updated[_editingIndex!] = config;
      } else {
        updated.add(config);
      }
      // Durable local write and sync queue first; network failure never loses setup.
      await _printerSettingsStore.savePrinters(updated);
      if (previousCounter != null && previousCounter != counter) {
        await _counterSyncStore.enqueue(previousCounter, null);
      }
      await _counterSyncStore.enqueue(counter, config);
      if (!mounted) return;
      setState(() {
        _savedPrinters = updated;
        _editingIndex = null;
      });
      if (_erpNextService?.isLoggedIn == true) {
        await _counterSyncStore.flush(_erpNextService!);
      }
      final queued = await _counterSyncStore.pending();
      await _checkPrinterStatuses();
      _setStatus(queued.isEmpty ? 'Printer saved and synced to ERPNext.'
          : 'Printer saved locally; ERPNext sync pending.');
    });
  }

  void _editPrinter(int index) {
    final printer = _savedPrinters[index];

    setState(() {
      _editingIndex = index;
      _nameController.text = printer.name;
      _connectionType = printer.connectionType;
      _paperWidth = printer.paperWidth;
      _ipController.text = printer.ip;
      _portController.text = printer.port.toString();

      _selectedBluetoothDevice = printer.bluetoothMac.isEmpty
          ? null
          : BluetoothPrinterDevice(
              name: printer.bluetoothName,
              mac: printer.bluetoothMac,
            );
    });
  }

  Future<void> _deletePrinter(int index) async {
    final name = _savedPrinters[index].name;
    final counter = _counterForName(name);
    if (counter == null) {
      _setStatus('Cannot delete: Kitchen Counter mapping unavailable.');
      return;
    }
    final updated = List<PrinterConfig>.from(_savedPrinters)
      ..removeAt(index);
    await _printerSettingsStore.savePrinters(updated);
    await _counterSyncStore.enqueue(counter, null);
    if (!mounted) return;
    setState(() {
      _savedPrinters = updated;
      _editingIndex = null;
    });
    if (_erpNextService?.isLoggedIn == true) {
      await _counterSyncStore.flush(_erpNextService!);
    }
    final queued = await _counterSyncStore.pending();
    await _checkPrinterStatuses();
    _setStatus(queued.isEmpty ? 'Printer removed and ERPNext cleared.'
        : 'Printer removed locally; server deletion queued.');
  }

  Future<void> _testCurrentConnection() async {
    await _runAction(() async {
      final config = _currentConfig();
      await _testConnectionFor(config);
    });
  }

  Future<void> _testCurrentPrint() async {
    await _runAction(() async {
      final config = _currentConfig();
      await _printTestTicket(config);
    });
  }

  Future<void> _testConnectionFor(PrinterConfig config) async {
    if (config.connectionType == PrinterConnectionType.wifi) {
      _setStatus('Connecting to ${config.ip}:${config.port} ...');
      await _wifiService.testConnection(
        ip: config.ip,
        port: config.port,
      );
      _setStatus('${config.name}: Wi-Fi connection successful.');
      return;
    }

    if (config.bluetoothMac.isEmpty) {
      throw Exception('Bluetooth MAC address is missing.');
    }

    _setStatus('Connecting to ${config.bluetoothName} ...');
    await _bluetoothService.testConnection(config.bluetoothMac);
    _setStatus('${config.name}: Bluetooth connection successful.');
  }

  Future<void> _printTestTicket(PrinterConfig config) async {
    final bytes = await _ticketBuilder.build(
      paperWidth: config.paperWidth,
      tableNumber: 'Table 07',
      items: const [
        KitchenTicketItem(
          itemName: 'Fried Rice',
          qty: 1,
          kitchenNote: 'No Onion',
        ),
        KitchenTicketItem(
          itemName: 'Chicken Curry',
          qty: 1,
          kitchenNote: 'Extra Chili',
        ),
        KitchenTicketItem(
          itemName: 'Beer',
          qty: 1,
        ),
      ],
      orderNote: 'Birthday Table',
    );

    if (config.connectionType == PrinterConnectionType.wifi) {
      _setStatus('Printing to ${config.name} ...');
      await _wifiService.printBytes(
        ip: config.ip,
        port: config.port,
        bytes: bytes,
      );
      _setStatus('${config.name}: test ticket sent.');
      return;
    }

    if (config.bluetoothMac.isEmpty) {
      throw Exception('Bluetooth MAC address is missing.');
    }

    _setStatus('Printing to ${config.name} ...');
    await _bluetoothService.printBytes(
      macAddress: config.bluetoothMac,
      bytes: bytes,
    );
    _setStatus('${config.name}: test ticket sent.');
  }

  Future<void> _runAction(Future<void> Function() action) async {
    if (_busy) {
      return;
    }

    setState(() {
      _busy = true;
    });

    try {
      await action();
    } catch (error) {
      _setStatus(
        'Error: ${error.toString().replaceFirst('Exception: ', '')}',
      );
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
        });
      }
    }
  }

  void _setStatus(String value) {
    if (!mounted) return;

    setState(() {
      _status = value;
    });
  }

  Future<void> _logout() async {
    if (_autoPrint) {
      stopPrinterBackgroundService();
    }
    await _serverSettingsStore.save(ServerSettings(
      baseUrl: _serverUrlController.text.trim(),
      username: '',
      password: '',
      rememberMe: false,
    ));
    if (!mounted) return;
    setState(() {
      _erpNextService = null;
      _serverLoggedIn = false;
      _autoPrint = false;
      _rememberMe = false;
      _pageIndex = 0;
      _pendingCount = 0;
      _usernameController.clear();
      _passwordController.clear();
      _status = 'Logged out.';
    });
  }


  Color _printerColor(String status) {
    if (status == 'Connected') return const Color(0xFF15966C);
    if (status == 'Offline' || status == 'Bluetooth Off') return Colors.red;
    if (status.contains('Bluetooth')) return Colors.orange.shade800;
    return const Color(0xFF64748B);
  }

  void _showPrinterDetails(String name, PrinterConfig? printer) {
    final index = _savedPrinters.indexWhere((p) => p.name == name);
    final status = printer == null
        ? 'Not Configured' : (_printerStates[name] ?? 'Checking');
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheet) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
          child: Column(mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(name, style: Theme.of(context).textTheme.headlineSmall),
              const SizedBox(height: 8),
              Text(status, style: TextStyle(color: _printerColor(status),
                fontWeight: FontWeight.bold)),
              const SizedBox(height: 8),
              Text(printer == null ? 'No printer configured'
                : printer.connectionType == PrinterConnectionType.wifi
                  ? 'Wi-Fi · ${printer.ip}:${printer.port} · ${printer.paperWidth}mm'
                  : 'Bluetooth · ${printer.bluetoothName} · ${printer.paperWidth}mm'),
              const SizedBox(height: 18),
              if (printer != null) FilledButton.icon(
                onPressed: () {
                  Navigator.pop(sheet);
                  _runAction(() => _printTestTicket(printer));
                },
                icon: const Icon(Icons.print_outlined),
                label: const Text('Test Print'),
              ),
              const SizedBox(height: 8),
              OutlinedButton.icon(
                onPressed: () {
                  Navigator.pop(sheet);
                  if (index >= 0) _editPrinter(index);
                  setState(() => _pageIndex = 1);
                },
                icon: const Icon(Icons.tune),
                label: Text(printer == null ? 'Configure Printer' : 'Edit Printer'),
              ),
              if (printer != null) ...[
                const SizedBox(height: 8),
                OutlinedButton.icon(
                  onPressed: () {
                    Navigator.pop(sheet);
                    _runAction(() => _testConnectionFor(printer));
                  },
                  icon: const Icon(Icons.wifi_tethering),
                  label: const Text('Test Connection'),
                ),
                const SizedBox(height: 8),
                TextButton.icon(
                  style: TextButton.styleFrom(foregroundColor: Colors.red),
                  onPressed: () async {
                    Navigator.pop(sheet);
                    final ok = await showDialog<bool>(
                      context: context,
                      builder: (dialog) => AlertDialog(
                        title: Text('Delete $name printer?'),
                        content: const Text('Remove local configuration and clear its ERPNext backup? The Kitchen Counter record is not deleted.'),
                        actions: [
                          TextButton(onPressed: () => Navigator.pop(dialog, false),
                            child: const Text('Cancel')),
                          FilledButton(onPressed: () => Navigator.pop(dialog, true),
                            child: const Text('Delete')),
                        ],
                      ),
                    );
                    if (ok == true && mounted) await _deletePrinter(index);
                  },
                  icon: const Icon(Icons.delete_outline),
                  label: const Text('Delete Printer'),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _dashboardPrinterTile(String name, PrinterConfig? printer) {
    final status = printer == null
        ? 'Not Configured' : (_printerStates[name] ?? 'Checking');
    final color = _printerColor(status);
    final details = printer == null ? 'No printer configured'
        : printer.connectionType == PrinterConnectionType.wifi
          ? '${printer.ip}:${printer.port} · ${printer.paperWidth}mm · Wi-Fi'
          : '${printer.bluetoothName} · ${printer.paperWidth}mm · Bluetooth';
    return Card(
      color: Colors.white, elevation: 0,
      margin: const EdgeInsets.only(bottom: 8),
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        onTap: () => _showPrinterDetails(name, printer),
        leading: CircleAvatar(
          backgroundColor: color.withValues(alpha: 0.12),
          child: Icon(printer?.connectionType == PrinterConnectionType.bluetooth
              ? Icons.bluetooth : Icons.print_outlined, color: color),
        ),
        title: Text(name, style: const TextStyle(fontWeight: FontWeight.bold)),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SizedBox(height: 4),
            Text(details, maxLines: 1, overflow: TextOverflow.ellipsis),
            const SizedBox(height: 4),
            Text(status, style: TextStyle(color: color,
                fontSize: 12, fontWeight: FontWeight.w700)),
          ],
        ),
        trailing: const Icon(Icons.chevron_right),
      ),
    );
  }

  Widget _buildDashboard() {
    final names = <String>{
      ..._kitchenCounters.map((c) => c.printerName).where((n) => n.isNotEmpty),
      ..._savedPrinters.map((p) => p.name),
    }.toList();
    final printers = {for (final p in _savedPrinters) p.name: p};
    final connected = _savedPrinters.where(
      (p) => _printerStates[p.name] == 'Connected').length;
    final offline = _savedPrinters.where((p) =>
      _printerStates[p.name] == 'Offline' ||
      _printerStates[p.name] == 'Bluetooth Off').length;
    Widget stat(String label, int number, Color color) => Expanded(
      child: Column(children: [
        Text('$number', style: TextStyle(fontSize: 25,
          fontWeight: FontWeight.bold, color: color)),
        Text(label, textAlign: TextAlign.center,
          style: const TextStyle(fontSize: 12)),
      ]),
    );

    return ColoredBox(
      color: const Color(0xFFF5F7FA),
      child: RefreshIndicator(
        onRefresh: () async {
          await _refreshKitchenCounters();
          await _checkPrinterStatuses();
        },
        child: ListView(
          padding: const EdgeInsets.all(14),
          children: [
            Text('BCN Printer Worker',
              style: Theme.of(context).textTheme.titleLarge?.copyWith(
                color: const Color(0xFF0D3970), fontWeight: FontWeight.bold)),
            const SizedBox(height: 12),
            Card(
              color: Colors.white, elevation: 0,
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 18, horizontal: 8),
                child: Row(children: [
                  stat('Connected', connected, const Color(0xFF15966C)),
                  const SizedBox(height: 44, child: VerticalDivider()),
                  stat('Offline', offline, Colors.red),
                  const SizedBox(height: 44, child: VerticalDivider()),
                  stat('Other / Setup', names.length - connected - offline,
                    const Color(0xFF64748B)),
                ]),
              ),
            ),
            const SizedBox(height: 12),
            Row(children: [
              Expanded(child: Text('Printers',
                style: Theme.of(context).textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.bold))),
              TextButton.icon(
                onPressed: _checkingPrinterStatus ? null : () async {
                  await _refreshKitchenCounters();
                  await _checkPrinterStatuses();
                },
                icon: const Icon(Icons.refresh),
                label: const Text('Refresh'),
              ),
            ]),
            if (names.isEmpty)
              Card(child: Padding(
                padding: const EdgeInsets.all(20),
                child: Column(children: [
                  const Icon(Icons.print_disabled_outlined, size: 40),
                  const Text('No Printers Found'),
                  TextButton(
                    onPressed: () => setState(() => _pageIndex = 1),
                    child: const Text('Go to Settings'),
                  ),
                ]),
              ))
            else
              ...names.map((name) => _dashboardPrinterTile(name, printers[name])),
            const SizedBox(height: 12),
            Card(
              color: Colors.white, elevation: 0,
              child: Padding(
                padding: const EdgeInsets.all(14),
                child: Column(crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(children: [
                      const Icon(Icons.receipt_long_outlined),
                      const SizedBox(width: 8),
                      const Expanded(child: Text('Print Jobs',
                        style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16))),
                      Text('Pending: $_pendingCount'),
                    ]),
                    const SizedBox(height: 10),
                    Row(children: [
                      Expanded(child: OutlinedButton.icon(
                        onPressed: _busy ? null :
                          () => _runAction(_refreshPendingCount),
                        icon: const Icon(Icons.refresh),
                        label: const Text('Check Jobs'),
                      )),
                      const SizedBox(width: 8),
                      Expanded(child: FilledButton.icon(
                        onPressed: _busy ? null :
                          () => _runAction(_printPendingJobs),
                        icon: const Icon(Icons.print),
                        label: const Text('Print Pending'),
                      )),
                    ]),
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('Auto Print'),
                      subtitle: const Text('Background check every 5 seconds'),
                      value: _autoPrint,
                      onChanged: _busy ? null : _setAutoPrint,
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 10),
            Text(_status, style: const TextStyle(fontSize: 12)),
          ],
        ),
      ),
    );
  }

  Widget _buildPrinterSettingsPage() {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Row(children: [
          const Expanded(child: Text('Kitchen Counters from ERPNext')),
          IconButton(
            tooltip: 'Refresh Kitchen Counters / sync changes',
            onPressed: _busy ? null : () => _runAction(() => _refreshKitchenCounters()),
            icon: const Icon(Icons.refresh),
          ),
        ]),
        _buildPrinterEditor(),
        const SizedBox(height: 20),
        Text('Saved Printers', style: Theme.of(context).textTheme.titleLarge),
        if (_savedPrinters.isEmpty)
          const Text('No printers saved yet.')
        else
          ...List.generate(_savedPrinters.length, _buildPrinterCard),
        Card(child: Padding(
          padding: const EdgeInsets.all(12), child: Text(_status),
        )),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_initializing) {
      return const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      );
    }
    if (!_serverLoggedIn) {
      return Scaffold(
        appBar: AppBar(title: const Text('ERPNext Login')),
        body: SafeArea(child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            const Icon(Icons.print, size: 64),
            const SizedBox(height: 12),
            _buildServerCard(),
            Card(child: Padding(
              padding: const EdgeInsets.all(12), child: Text(_status),
            )),
          ],
        )),
      );
    }
    return Scaffold(
      appBar: AppBar(
        title: Text(_pageIndex == 0 ? 'Dashboard' : 'Printer Settings'),
        actions: [
          IconButton(
            onPressed: _busy ? null : _logout,
            tooltip: 'Logout',
            icon: const Icon(Icons.logout),
          ),
        ],
      ),
      body: SafeArea(
        child: _pageIndex == 0
            ? _buildDashboard()
            : _buildPrinterSettingsPage(),
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _pageIndex,
        onDestinationSelected: (index) {
          setState(() => _pageIndex = index);
          if (index == 1) _refreshKitchenCounters();
          if (index == 0) _checkPrinterStatuses();
        },
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.dashboard_outlined),
            selectedIcon: Icon(Icons.dashboard),
            label: 'Dashboard',
          ),
          NavigationDestination(
            icon: Icon(Icons.settings_outlined),
            selectedIcon: Icon(Icons.settings),
            label: 'Printer Settings',
          ),
        ],
      ),
    );
  }

  Widget _buildServerCard() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'ERPNext Print Server',
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _serverUrlController,
              enabled: !_busy,
              decoration: const InputDecoration(
                border: OutlineInputBorder(),
                labelText: 'Server URL',
              ),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _usernameController,
              enabled: !_busy,
              decoration: const InputDecoration(
                border: OutlineInputBorder(),
                labelText: 'Username / Email',
              ),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _passwordController,
              enabled: !_busy,
              obscureText: true,
              decoration: const InputDecoration(
                border: OutlineInputBorder(),
                labelText: 'Password',
              ),
            ),
            const SizedBox(height: 8),
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Remember Me'),
              subtitle: const Text('Automatically log in when reopening the app'),
              value: _rememberMe,
              onChanged: _busy ? null : (value) async {
                final enabled = value ?? false;
                setState(() => _rememberMe = enabled);
                if (!enabled) {
                  if (_autoPrint) {
                    await _setAutoPrint(false);
                  }
                  await _serverSettingsStore.save(ServerSettings(
                    baseUrl: _serverUrlController.text.trim(),
                    username: _usernameController.text.trim(),
                    password: '',
                    rememberMe: false,
                  ));
                }
              },
            ),
            const SizedBox(height: 10),
            FilledButton.icon(
              onPressed: _busy ? null : () => _loginServer(),
              icon: const Icon(Icons.login),
              label: Text(
                _serverLoggedIn ? 'Login Again' : 'Login',
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildPrinterEditor() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              _editingIndex == null ? 'Add Printer' : 'Edit Printer',
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<String>(
              key: ValueKey('printer-${_nameController.text}-${_editingIndex ?? -1}'),
              initialValue: _printerNameOptions.contains(_nameController.text.trim())
                  ? _nameController.text.trim()
                  : null,
              isExpanded: true,
              decoration: const InputDecoration(
                border: OutlineInputBorder(),
                labelText: 'Printer Name',
                hintText: 'Select printer',
              ),
              items: _printerNameOptions.map((name) =>
                  DropdownMenuItem<String>(
                    value: name,
                    child: Text(name, overflow: TextOverflow.ellipsis),
                  )).toList(),
              onChanged: _busy ? null : (name) {
                if (name != null) {
                  setState(() => _nameController.text = name);
                }
              },
            ),
            const SizedBox(height: 12),
            SegmentedButton<PrinterConnectionType>(
              segments: const [
                ButtonSegment(
                  value: PrinterConnectionType.wifi,
                  icon: Icon(Icons.wifi),
                  label: Text('Wi-Fi'),
                ),
                ButtonSegment(
                  value: PrinterConnectionType.bluetooth,
                  icon: Icon(Icons.bluetooth),
                  label: Text('Bluetooth'),
                ),
              ],
              selected: {_connectionType},
              onSelectionChanged: _busy
                  ? null
                  : (selection) {
                      setState(() {
                        _connectionType = selection.first;
                      });
                    },
            ),
            const SizedBox(height: 12),
            if (_connectionType == PrinterConnectionType.wifi)
              _buildWifiSettings()
            else
              _buildBluetoothSettings(),
            const SizedBox(height: 12),
            SegmentedButton<int>(
              segments: const [
                ButtonSegment(value: 58, label: Text('58mm')),
                ButtonSegment(value: 80, label: Text('80mm')),
              ],
              selected: {_paperWidth},
              onSelectionChanged: _busy
                  ? null
                  : (selection) {
                      setState(() {
                        _paperWidth = selection.first;
                      });
                    },
            ),
            const SizedBox(height: 12),
            FilledButton.icon(
              onPressed: _busy ? null : _savePrinter,
              icon: const Icon(Icons.save),
              label: Text(
                _editingIndex == null
                    ? 'Save Printer'
                    : 'Update Printer',
              ),
            ),
            const SizedBox(height: 4),
            OutlinedButton.icon(
              onPressed: _busy ? null : _testCurrentConnection,
              icon: const Icon(Icons.link),
              label: const Text('Test Connection'),
            ),
            const SizedBox(height: 4),
            OutlinedButton.icon(
              onPressed: _busy ? null : _testCurrentPrint,
              icon: const Icon(Icons.print),
              label: const Text('Test Print'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildWifiSettings() {
    return Row(
      children: [
        Expanded(
          flex: 3,
          child: TextField(
            controller: _ipController,
            enabled: !_busy,
            keyboardType: TextInputType.number,
            decoration: const InputDecoration(
              border: OutlineInputBorder(),
              labelText: 'Printer IP',
            ),
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          flex: 2,
          child: TextField(
            controller: _portController,
            enabled: !_busy,
            keyboardType: TextInputType.number,
            decoration: const InputDecoration(
              border: OutlineInputBorder(),
              labelText: 'Port',
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildBluetoothSettings() {
    final selectedMac = _selectedBluetoothDevice?.mac;
    final knownMacs = _bluetoothDevices.map((d) => d.mac).toSet();

    final validSelectedMac =
        selectedMac != null && knownMacs.contains(selectedMac)
            ? selectedMac
            : null;

    return Row(
      children: [
        Expanded(
          child: DropdownButtonFormField<String>(
            key: ValueKey('bluetooth-${validSelectedMac ?? 'none'}'),
            initialValue: validSelectedMac,
            decoration: const InputDecoration(
              border: OutlineInputBorder(),
              labelText: 'Paired Printer',
            ),
            items: _bluetoothDevices
                .map(
                  (device) => DropdownMenuItem(
                    value: device.mac,
                    child: Text(
                      device.name.isEmpty
                          ? device.mac
                          : '${device.name} (${device.mac})',
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                )
                .toList(),
            onChanged: _busy
                ? null
                : (mac) {
                    if (mac == null) return;

                    setState(() {
                      _selectedBluetoothDevice =
                          _bluetoothDevices.firstWhere(
                        (device) => device.mac == mac,
                      );
                    });
                  },
          ),
        ),
        const SizedBox(width: 8),
        IconButton.filledTonal(
          onPressed: _busy ? null : _loadPairedBluetoothDevices,
          icon: const Icon(Icons.refresh),
          tooltip: 'Refresh paired devices',
        ),
      ],
    );
  }

  Widget _buildPrinterCard(int index) {
    final printer = _savedPrinters[index];

    final detail = printer.connectionType == PrinterConnectionType.wifi
        ? '${printer.ip}:${printer.port}'
        : '${printer.bluetoothName} • ${printer.bluetoothMac}';

    final connectionStatus = _printerStates[printer.name] ?? 'Checking';
    return Card(
      child: ListTile(
        leading: Icon(
          printer.connectionType == PrinterConnectionType.wifi
              ? Icons.wifi
              : Icons.bluetooth,
        ),
        title: Text(printer.name),
        subtitle: Text('$detail • ${printer.paperWidth}mm • $connectionStatus'),
        trailing: PopupMenuButton<String>(
          onSelected: (value) {
            if (value == 'test') {
              _runAction(() => _printTestTicket(printer));
            } else if (value == 'edit') {
              _editPrinter(index);
            } else if (value == 'delete') {
              _deletePrinter(index);
            }
          },
          itemBuilder: (context) => const [
            PopupMenuItem(
              value: 'test',
              child: Text('Test Print'),
            ),
            PopupMenuItem(
              value: 'edit',
              child: Text('Edit'),
            ),
            PopupMenuItem(
              value: 'delete',
              child: Text('Delete'),
            ),
          ],
        ),
      ),
    );
  }
}
