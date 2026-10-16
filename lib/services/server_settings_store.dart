import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

class ServerSettings {
  const ServerSettings({
    required this.baseUrl,
    required this.username,
    required this.password,
    this.rememberMe = true,
  });

  final String baseUrl;
  final String username;
  final String password;
  final bool rememberMe;
}

class ServerSettingsStore {
  static const _baseUrlKey = 'erpnext_base_url';
  static const _usernameKey = 'erpnext_username';
  static const _passwordKey = 'erpnext_password';
  static const _rememberMeKey = 'erpnext_remember_me';

  final FlutterSecureStorage _secureStorage = const FlutterSecureStorage();

  Future<ServerSettings> load() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.reload();

    return ServerSettings(
      baseUrl: prefs.getString(_baseUrlKey) ?? 'https://ourcity.s.frappe.cloud',
      username: prefs.getString(_usernameKey) ?? '',
      password: await _secureStorage.read(key: _passwordKey) ?? '',
      rememberMe: prefs.getBool(_rememberMeKey) ?? true,
    );
  }

  Future<void> save(ServerSettings settings) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_baseUrlKey, settings.baseUrl.trim());
    await prefs.setString(_usernameKey, settings.username.trim());
    await prefs.setBool(_rememberMeKey, settings.rememberMe);
    if (settings.rememberMe) {
      await _secureStorage.write(key: _passwordKey, value: settings.password);
    } else {
      await _secureStorage.delete(key: _passwordKey);
    }
  }
}
