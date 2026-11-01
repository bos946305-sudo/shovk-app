import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// JWT хранится только здесь: iOS Keychain / Android Keystore (в открытом виде нигде не лежит).
class TokenStorage {
  const TokenStorage([this._storage = const FlutterSecureStorage()]);

  final FlutterSecureStorage _storage;
  static const _jwtKey = 'jwt';

  Future<String?> readJwt() async {
    try {
      return await _storage.read(key: _jwtKey);
    } catch (_) {
      return null; // например, после переустановки Android не может расшифровать старое значение
    }
  }

  Future<void> saveJwt(String token) => _storage.write(key: _jwtKey, value: token);

  Future<void> clear() async {
    try {
      await _storage.delete(key: _jwtKey);
    } catch (_) {}
  }
}
