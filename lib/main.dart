import 'dart:async';

import 'package:flutter/material.dart';

import 'models/print_job.dart';
import 'models/printer_config.dart';
import 'services/background_print_service.dart';
import 'services/bluetooth_printer_service.dart';
import 'services/erpnext_print_service.dart';
import 'services/kitchen_ticket_builder.dart';
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

  PrinterConnectionType _connectionType = PrinterConnectionType.wifi;
  int _paperWidth = 80;
  List<BluetoothPrinterDevice> _bluetoothDevices = const [];
  BluetoothPrinterDevice? _selectedBluetoothDevice;
  List<PrinterConfig> _savedPrinters = const [];
  int? _editingIndex;

  ErpNextPrintService? _erpNextService;
  StreamSubscription<Map<String, dynamic>?>? _backgroundStatusSubscription;

  bool _busy = false;
  bool _serverLoggedIn = false;
  bool _rememberMe = true;
  bool _autoPrint = false;
  int _pendingCount = 0;
  String _status = 'Ready';

  @override
  void initState() {
    super.initState();
    _loadInitialSettings();
  }

  @override
  void dispose() {
    _backgroundStatusSubscription?.cancel();
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
      });

      _setStatus(silent ? 'Auto login successful.' : 'ERPNext login successful.');
      await _refreshPendingCount();
    });
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

    if (name.isEmpty) {
      throw Exception('Enter printer name.');
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
      final updated = List<PrinterConfig>.from(_savedPrinters);

      if (_editingIndex == null) {
        updated.add(config);
      } else {
        updated[_editingIndex!] = config;
      }

      await _printerSettingsStore.savePrinters(updated);

      if (!mounted) return;

      setState(() {
        _savedPrinters = updated;
        _editingIndex = null;
      });

      _setStatus('Printer saved.');
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
    final updated = List<PrinterConfig>.from(_savedPrinters)
      ..removeAt(index);

    await _printerSettingsStore.savePrinters(updated);

    if (!mounted) return;

    setState(() {
      _savedPrinters = updated;

      if (_editingIndex == index) {
        _editingIndex = null;
      }
    });

    _setStatus('Printer deleted.');
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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('BCN Printer Worker'),
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            _buildServerCard(),
            const SizedBox(height: 20),
            _buildPrinterEditor(),
            const SizedBox(height: 20),
            Text(
              'Saved Printers',
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 6),
            if (_savedPrinters.isEmpty)
              const Text('No printers saved yet.')
            else
              ...List.generate(
                _savedPrinters.length,
                _buildPrinterCard,
              ),
            const SizedBox(height: 16),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Text(_status),
              ),
            ),
          ],
        ),
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
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: !_serverLoggedIn || _busy
                        ? null
                        : () => _runAction(_refreshPendingCount),
                    icon: const Icon(Icons.refresh),
                    label: const Text('Check Jobs'),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: !_serverLoggedIn || _busy
                        ? null
                        : () => _runAction(_printPendingJobs),
                    icon: const Icon(Icons.print),
                    label: const Text('Print Pending'),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Auto Print'),
              subtitle: const Text(
                'Runs as Android foreground service every 5 seconds',
              ),
              value: _autoPrint,
              onChanged: _busy
                  ? null
                  : (enabled) {
                      _setAutoPrint(enabled);
                    },
            ),
            Text(
              'Pending Jobs: $_pendingCount',
              style: const TextStyle(fontWeight: FontWeight.bold),
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
            TextField(
              controller: _nameController,
              enabled: !_busy,
              decoration: const InputDecoration(
                border: OutlineInputBorder(),
                labelText: 'Printer Name',
                hintText: 'Kitchen / Bar / Service',
              ),
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
            value: validSelectedMac,
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

    return Card(
      child: ListTile(
        leading: Icon(
          printer.connectionType == PrinterConnectionType.wifi
              ? Icons.wifi
              : Icons.bluetooth,
        ),
        title: Text(printer.name),
        subtitle: Text('$detail • ${printer.paperWidth}mm'),
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
