import 'package:flutter/material.dart';

import 'models/printer_config.dart';
import 'services/bluetooth_printer_service.dart';
import 'services/kitchen_ticket_builder.dart';
import 'services/printer_settings_store.dart';
import 'services/wifi_printer_service.dart';

void main() {
  runApp(const BcnPrinterApp());
}

class BcnPrinterApp extends StatelessWidget {
  const BcnPrinterApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'BCN Printer Test',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF1565C0)),
        useMaterial3: true,
      ),
      home: const PrinterTestScreen(),
    );
  }
}

class PrinterTestScreen extends StatefulWidget {
  const PrinterTestScreen({super.key});

  @override
  State<PrinterTestScreen> createState() => _PrinterTestScreenState();
}

class _PrinterTestScreenState extends State<PrinterTestScreen> {
  final _wifiService = WifiPrinterService();
  final _bluetoothService = BluetoothPrinterService();
  final _ticketBuilder = KitchenTicketBuilder();
  final _settingsStore = PrinterSettingsStore();

  final _nameController = TextEditingController(text: 'Kitchen Printer');
  final _ipController = TextEditingController(text: '192.168.0.90');
  final _portController = TextEditingController(text: '9100');

  PrinterConnectionType _connectionType = PrinterConnectionType.wifi;
  int _paperWidth = 80;
  List<BluetoothPrinterDevice> _bluetoothDevices = const [];
  BluetoothPrinterDevice? _selectedBluetoothDevice;
  List<PrinterConfig> _savedPrinters = const [];
  int? _editingIndex;

  bool _busy = false;
  String _status = 'Ready';

  @override
  void initState() {
    super.initState();
    _loadSavedPrinters();
  }

  @override
  void dispose() {
    _nameController.dispose();
    _ipController.dispose();
    _portController.dispose();
    _bluetoothService.disconnect();
    super.dispose();
  }

  Future<void> _loadSavedPrinters() async {
    final printers = await _settingsStore.loadPrinters();
    if (!mounted) return;
    setState(() {
      _savedPrinters = printers;
    });
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
            (d) => d.mac == _selectedBluetoothDevice!.mac,
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

      await _settingsStore.savePrinters(updated);
      if (!mounted) return;

      setState(() {
        _savedPrinters = updated;
        _editingIndex = null;
      });
      _setStatus('Printer saved.');
    });
  }

  void _editPrinter(int index) {
    final p = _savedPrinters[index];
    setState(() {
      _editingIndex = index;
      _nameController.text = p.name;
      _connectionType = p.connectionType;
      _paperWidth = p.paperWidth;
      _ipController.text = p.ip;
      _portController.text = p.port.toString();
      _selectedBluetoothDevice = p.bluetoothMac.isEmpty
          ? null
          : BluetoothPrinterDevice(
              name: p.bluetoothName,
              mac: p.bluetoothMac,
            );
    });
  }

  Future<void> _deletePrinter(int index) async {
    final updated = List<PrinterConfig>.from(_savedPrinters)..removeAt(index);
    await _settingsStore.savePrinters(updated);
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
      await _wifiService.testConnection(ip: config.ip, port: config.port);
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
      waiter: 'Htay Oo Lwin',
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
    if (_busy) return;
    setState(() => _busy = true);

    try {
      await action();
    } catch (error) {
      _setStatus(
        'Error: ${error.toString().replaceFirst('Exception: ', '')}',
      );
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  void _setStatus(String value) {
    if (!mounted) return;
    setState(() => _status = value);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('BCN Printer Test')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(16),
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
                hintText: 'Kitchen Printer',
              ),
            ),
            const SizedBox(height: 16),
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
                      setState(() => _connectionType = selection.first);
                    },
            ),
            const SizedBox(height: 16),
            if (_connectionType == PrinterConnectionType.wifi)
              _buildWifiSettings()
            else
              _buildBluetoothSettings(),
            const SizedBox(height: 16),
            SegmentedButton<int>(
              segments: const [
                ButtonSegment(value: 58, label: Text('58mm')),
                ButtonSegment(value: 80, label: Text('80mm')),
              ],
              selected: {_paperWidth},
              onSelectionChanged: _busy
                  ? null
                  : (selection) {
                      setState(() => _paperWidth = selection.first);
                    },
            ),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: _busy ? null : _savePrinter,
              icon: const Icon(Icons.save),
              label: Text(
                _editingIndex == null ? 'Save Printer' : 'Update Printer',
              ),
            ),
            const SizedBox(height: 3),
            OutlinedButton.icon(
              onPressed: _busy ? null : _testCurrentConnection,
              icon: const Icon(Icons.link),
              label: const Text('Test Connection'),
            ),
            const SizedBox(height: 3),
            OutlinedButton.icon(
              onPressed: _busy ? null : _testCurrentPrint,
              icon: const Icon(Icons.print),
              label: const Text('Test Print'),
            ),
            const SizedBox(height: 16),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Text(_status),
              ),
            ),
            const SizedBox(height: 24),
            Text(
              'Saved Printers',
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 3),
            if (_savedPrinters.isEmpty)
              const Text('No printers saved yet.')
            else
              ...List.generate(
                _savedPrinters.length,
                (index) => _buildPrinterCard(index),
              ),
            const SizedBox(height: 24),
            _buildTicketPreview(),
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

    return Column(
      children: [
        Row(
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
                      (d) => DropdownMenuItem(
                        value: d.mac,
                        child: Text(
                          d.name.isEmpty ? d.mac : '${d.name} (${d.mac})',
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
                            (d) => d.mac == mac,
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
        ),
        const SizedBox(height: 6),
        const Align(
          alignment: Alignment.centerLeft,
          child: Text(
            'Pair the printer in Android Bluetooth settings first, then refresh.',
          ),
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
        isThreeLine: false,
        trailing: PopupMenuButton<String>(
          onSelected: (value) {
            if (value == 'edit') {
              _editPrinter(index);
            } else if (value == 'test') {
              _runAction(() => _printTestTicket(printer));
            } else if (value == 'delete') {
              _deletePrinter(index);
            }
          },
          itemBuilder: (context) => const [
            PopupMenuItem(value: 'test', child: Text('Test Print')),
            PopupMenuItem(value: 'edit', child: Text('Edit')),
            PopupMenuItem(value: 'delete', child: Text('Delete')),
          ],
        ),
      ),
    );
  }

  Widget _buildTicketPreview() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: DefaultTextStyle(
          style: const TextStyle(
            fontFamily: 'monospace',
            fontSize: 13,
            color: Colors.black87,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: const [
              Text('--------------------------------'),
              Text(
                'Table 07',
                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
              ),
              Text(
                'Waiter: Htay Oo Lwin',
                style: TextStyle(fontWeight: FontWeight.bold),
              ),
              Text('--------------------------------'),
              Text(
                '1 x Fried Rice',
                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
              ),
              Text('  No Onion'),
              SizedBox(height: 3),
              Text(
                '1 x Chicken Curry',
                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
              ),
              Text('  Extra Chili'),
              SizedBox(height: 3),
              Text(
                '1 x Beer',
                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
              ),
              Text('--------------------------------'),
              Text(
                'Order Note: Birthday Table',
                style: TextStyle(fontWeight: FontWeight.bold),
              ),
              Text('--------------------------------'),
            ],
          ),
        ),
      ),
    );
  }
}
