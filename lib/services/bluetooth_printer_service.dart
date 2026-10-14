import 'package:print_bluetooth_thermal/print_bluetooth_thermal.dart';

class BluetoothPrinterDevice {
  const BluetoothPrinterDevice({
    required this.name,
    required this.mac,
  });

  final String name;
  final String mac;
}

class BluetoothPrinterService {
  Future<bool> isBluetoothEnabled() {
    return PrintBluetoothThermal.bluetoothEnabled;
  }

  Future<bool> hasPermission() {
    return PrintBluetoothThermal.isPermissionBluetoothGranted;
  }

  Future<List<BluetoothPrinterDevice>> pairedDevices() async {
    final devices = await PrintBluetoothThermal.pairedBluetooths;

    return devices
        .map(
          (device) => BluetoothPrinterDevice(
            name: device.name,
            mac: device.macAdress,
          ),
        )
        .toList();
  }

  Future<void> connect(String macAddress) async {
    final connected = await PrintBluetoothThermal.connect(
      macPrinterAddress: macAddress,
    );

    if (!connected) {
      throw Exception('Bluetooth printer connection failed.');
    }
  }

  Future<void> testConnection(String macAddress) async {
    await connect(macAddress);
  }

  Future<void> printBytes({
    required String macAddress,
    required List<int> bytes,
  }) async {
    final alreadyConnected = await PrintBluetoothThermal.connectionStatus;

    if (!alreadyConnected) {
      await connect(macAddress);
    }

    final success = await PrintBluetoothThermal.writeBytes(bytes);
    if (!success) {
      throw Exception('Bluetooth print failed.');
    }
  }

  Future<void> disconnect() async {
    final connected = await PrintBluetoothThermal.connectionStatus;
    if (connected) {
      await PrintBluetoothThermal.disconnect;
    }
  }
}
