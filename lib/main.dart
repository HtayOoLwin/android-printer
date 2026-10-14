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

  final _ipController = TextEditingController(text: '192.168.1.50');
  final _portController = TextEditingController(text: '9100');

  PrinterConnectionType _connectionType = PrinterConnectionType.wifi;
  int _paperWidth = 80;
  List<BluetoothPrinterDevice> _bluetoothDevices = const [];
  BluetoothPrinterDevice? _selectedBluetoothDevice;

  bool _busy = false;
  String _status = 'Ready';

  @override
  void initState() {
    super.initState();
    _loadSettings();
  }

  @override
  void dispose() {
    _ipController.dispose();
    _portController.dispose();
    _bluetoothService.disconnect();
    super.dispose();
  }

  Future<void> _loadSettings() async {
    final settings = await _settingsStore.load();
    if (!mounted) return;

    setState(() {
      _connectionType = settings['connection_type'] == 'bluetooth'
          ? PrinterConnectionType.bluetooth
          : PrinterConnectionType.wifi;
      _ipController.text = settings['printer_ip'] as String;
      _portController.text = (settings['printer_port'] as int).toString();
      _paperWidth = settings['paper_width'] as int;

      final savedName = settings['bluetooth_name'] as String;
      final savedMac = settings['bluetooth_mac'] as String;
      if (savedMac.isNotEmpty) {
        _selectedBluetoothDevice = BluetoothPrinterDevice(
          name: savedName,
          mac: savedMac,
        );
      }
    });
  }

  Future<void> _saveSettings() async {
    final port = int.tryParse(_portController.text.trim()) ?? 9100;

    await _settingsStore.save(
      connectionType: _connectionType.name,
      ip: _ipController.text.trim(),
      port: port,
      paperWidth: _paperWidth,
      bluetoothName: _selectedBluetoothDevice?.name ?? '',
      bluetoothMac: _selectedBluetoothDevice?.mac ?? '',
    );
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
            ? 'No paired Bluetooth printers found. Pair the printer in Android Settings first.'
            : 'Found ${devices.length} paired Bluetooth device(s).',
      );
    });
  }

  Future<void> _testConnection() async {
    await _runAction(() async {
      await _saveSettings();

      if (_connectionType == PrinterConnectionType.wifi) {
        final ip = _ipController.text.trim();
        final port = int.tryParse(_portController.text.trim());

        if (ip.isEmpty || port == null) {
          throw Exception('Enter a valid printer IP and port.');
        }

        _setStatus('Connecting to $ip:$port ...');
        await _wifiService.testConnection(ip: ip, port: port);
        _setStatus('Wi-Fi printer connection successful.');
        return;
      }

      final device = _selectedBluetoothDevice;
      if (device == null) {
        throw Exception('Select a paired Bluetooth printer first.');
      }

      _setStatus('Connecting to ${device.name} ...');
      await _bluetoothService.testConnection(device.mac);
      _setStatus('Bluetooth printer connection successful.');
    });
  }

  Future<void> _testPrint() async {
    await _runAction(() async {
      await _saveSettings();

      final bytes = await _ticketBuilder.build(
        paperWidth: _paperWidth,
        tableNumber: 'Table 05',
        waiter: 'Htay Oo Lwin',
        items: const [
          KitchenTicketItem(
            itemName: 'Fried Rice',
            qty: 2,
            kitchenNote: 'No Onion',
          ),
          KitchenTicketItem(
            itemName: 'Chicken Curry',
            qty: 1,
            kitchenNote: 'Extra Chili',
          ),
          KitchenTicketItem(
            itemName: 'Beer',
            qty: 3,
          ),
        ],
        orderNote: 'Birthday Table',
      );

      if (_connectionType == PrinterConnectionType.wifi) {
        final ip = _ipController.text.trim();
        final port = int.tryParse(_portController.text.trim());

        if (ip.isEmpty || port == null) {
          throw Exception('Enter a valid printer IP and port.');
        }

        _setStatus('Printing by Wi-Fi to $ip:$port ...');
        await _wifiService.printBytes(
          ip: ip,
          port: port,
          bytes: bytes,
        );
        _setStatus('Wi-Fi test ticket sent successfully.');
        return;
      }

      final device = _selectedBluetoothDevice;
      if (device == null) {
        throw Exception('Select a paired Bluetooth printer first.');
      }

      _setStatus('Printing by Bluetooth to ${device.name} ...');
      await _bluetoothService.printBytes(
        macAddress: device.mac,
        bytes: bytes,
      );
      _setStatus('Bluetooth test ticket sent successfully.');
    });
  }

  Future<void> _runAction(Future<void> Function() action) async {
    if (_busy) return;

    setState(() {
      _busy = true;
    });

    try {
      await action();
    } catch (error) {
      _setStatus('Error: ${_cleanError(error)}');
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
        });
      }
    }
  }

  String _cleanError(Object error) {
    return error.toString().replaceFirst('Exception: ', '');
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
        title: const Text('BCN Printer Test'),
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Text(
              'Connection Type',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
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
            const SizedBox(height: 20),
            if (_connectionType == PrinterConnectionType.wifi)
              _buildWifiSettings()
            else
              _buildBluetoothSettings(),
            const SizedBox(height: 20),
            Text(
              'Paper Width',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
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
            const SizedBox(height: 24),
            FilledButton.icon(
              onPressed: _busy ? null : _testConnection,
              icon: const Icon(Icons.link),
              label: const Text('Test Connection'),
            ),
            const SizedBox(height: 12),
            FilledButton.icon(
              onPressed: _busy ? null : _testPrint,
              icon: const Icon(Icons.print),
              label: const Text('Test Print'),
            ),
            const SizedBox(height: 24),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (_busy)
                      const Padding(
                        padding: EdgeInsets.only(right: 12, top: 2),
                        child: SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                      )
                    else
                      const Padding(
                        padding: EdgeInsets.only(right: 12),
                        child: Icon(Icons.info_outline),
                      ),
                    Expanded(
                      child: Text(
                        _status,
                        style: Theme.of(context).textTheme.bodyMedium,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 20),
            _buildTicketPreview(),
          ],
        ),
      ),
    );
  }

  Widget _buildWifiSettings() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Wi-Fi Printer',
          style: Theme.of(context).textTheme.titleMedium,
        ),
        const SizedBox(height: 8),
        TextField(
          controller: _ipController,
          enabled: !_busy,
          keyboardType: TextInputType.number,
          decoration: const InputDecoration(
            border: OutlineInputBorder(),
            labelText: 'Printer IP',
            hintText: '192.168.1.50',
          ),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _portController,
          enabled: !_busy,
          keyboardType: TextInputType.number,
          decoration: const InputDecoration(
            border: OutlineInputBorder(),
            labelText: 'Port',
            hintText: '9100',
          ),
        ),
      ],
    );
  }

  Widget _buildBluetoothSettings() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                'Bluetooth Printer',
                style: Theme.of(context).textTheme.titleMedium,
              ),
            ),
            TextButton.icon(
              onPressed: _busy ? null : _loadPairedBluetoothDevices,
              icon: const Icon(Icons.refresh),
              label: const Text('Refresh'),
            ),
          ],
        ),
        const SizedBox(height: 8),
        DropdownButtonFormField<String>(
          initialValue: _selectedBluetoothDevice?.mac,
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
                    _selectedBluetoothDevice = _bluetoothDevices.firstWhere(
                      (device) => device.mac == mac,
                    );
                  });
                },
        ),
        const SizedBox(height: 8),
        Text(
          'Pair the thermal printer in Android Bluetooth settings first, then tap Refresh.',
          style: Theme.of(context).textTheme.bodySmall,
        ),
      ],
    );
  }

  Widget _buildTicketPreview() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: DefaultTextStyle(
          style: const TextStyle(
            fontFamily: 'monospace',
            color: Colors.black87,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: const [
              Text(
                'KITCHEN ORDER',
                textAlign: TextAlign.center,
                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18),
              ),
              Divider(),
              Text('Table No : Table 05'),
              Text('Waiter   : Htay Oo Lwin'),
              Divider(),
              Text('QTY   ITEM', style: TextStyle(fontWeight: FontWeight.bold)),
              Divider(),
              Text('2     Fried Rice'),
              Text('      Note: No Onion'),
              SizedBox(height: 8),
              Text('1     Chicken Curry'),
              Text('      Note: Extra Chili'),
              SizedBox(height: 8),
              Text('3     Beer'),
              Divider(),
              Text(
                'Order Note:',
                style: TextStyle(fontWeight: FontWeight.bold),
              ),
              Text('Birthday Table'),
            ],
          ),
        ),
      ),
    );
  }
}
