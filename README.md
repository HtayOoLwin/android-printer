# Android Printer

Small Flutter printer test app for BCN restaurant printing.

## MVP

- Wi-Fi ESC/POS printing over TCP (default port 9100)
- Bluetooth thermal printer printing
- 58mm / 80mm paper
- Test kitchen ticket with:
  - Table Number
  - Waiter
  - Items
  - Qty
  - Kitchen Note
  - Order Note
- Local printer settings

## Local setup

This repository starts with the app source and Android manifest. If platform scaffolding is missing after clone, run:

```bash
flutter create .
flutter pub get
flutter run
```

Flutter 3.44+ is recommended.

## First test

1. Pair the Bluetooth printer in Android settings, or connect the tablet and Wi-Fi printer to the same LAN.
2. For Wi-Fi, enter the printer IP and RAW TCP port (usually 9100).
3. Select 58mm or 80mm.
4. Tap **Test Connection**.
5. Tap **Test Print**.

ERPNext integration and multi-printer routing will be added after direct Wi-Fi/Bluetooth printing is verified.
