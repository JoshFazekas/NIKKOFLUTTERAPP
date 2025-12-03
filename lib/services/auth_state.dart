import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

class AuthState extends ChangeNotifier {
  static final AuthState _instance = AuthState._internal();
  factory AuthState() => _instance;
  AuthState._internal();

  static const _storage = FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
    iOptions: IOSOptions(accessibility: KeychainAccessibility.first_unlock),
  );

  static const _tokenKey = 'auth_token';
  static const _refreshTokenKey = 'refresh_token';
  static const _userIdKey = 'user_id';
  static const _emailKey = 'user_email';
  static const _passwordKey = 'user_password';

  String? _token;
  String? _refreshToken;
  int? _userId;
  String? _email;
  String? _password;

  String? get token => _token;
  String? get refreshToken => _refreshToken;
  int? get userId => _userId;
  String? get email => _email;
  String? get password => _password;
  bool get isLoggedIn => _token != null;

  /// Load stored credentials from secure storage
  Future<bool> loadStoredCredentials() async {
    try {
      _token = await _storage.read(key: _tokenKey);
      _refreshToken = await _storage.read(key: _refreshTokenKey);
      final userIdStr = await _storage.read(key: _userIdKey);
      _userId = userIdStr != null ? int.tryParse(userIdStr) : null;
      _email = await _storage.read(key: _emailKey);
      _password = await _storage.read(key: _passwordKey);

      notifyListeners();
      return _token != null && _email != null && _password != null;
    } catch (e) {
      debugPrint('Error loading stored credentials: $e');
      return false;
    }
  }

  /// Check if we have stored credentials (without loading them into memory)
  Future<bool> hasStoredCredentials() async {
    try {
      final token = await _storage.read(key: _tokenKey);
      final email = await _storage.read(key: _emailKey);
      final password = await _storage.read(key: _passwordKey);
      return token != null && email != null && password != null;
    } catch (e) {
      return false;
    }
  }

  Future<void> login({
    required String token,
    required String refreshToken,
    required int userId,
    String? email,
    String? password,
  }) async {
    _token = token;
    _refreshToken = refreshToken;
    _userId = userId;
    if (email != null) _email = email;
    if (password != null) _password = password;

    // Persist to secure storage
    try {
      await _storage.write(key: _tokenKey, value: token);
      await _storage.write(key: _refreshTokenKey, value: refreshToken);
      await _storage.write(key: _userIdKey, value: userId.toString());
      if (email != null) {
        await _storage.write(key: _emailKey, value: email);
      }
      if (password != null) {
        await _storage.write(key: _passwordKey, value: password);
      }
    } catch (e) {
      debugPrint('Error saving credentials: $e');
    }

    notifyListeners();
  }

  /// Update just the token (used for re-authentication)
  Future<void> updateToken({
    required String token,
    required String refreshToken,
    required int userId,
  }) async {
    _token = token;
    _refreshToken = refreshToken;
    _userId = userId;

    try {
      await _storage.write(key: _tokenKey, value: token);
      await _storage.write(key: _refreshTokenKey, value: refreshToken);
      await _storage.write(key: _userIdKey, value: userId.toString());
    } catch (e) {
      debugPrint('Error updating token: $e');
    }

    notifyListeners();
  }

  Future<void> logout() async {
    _token = null;
    _refreshToken = null;
    _userId = null;
    _email = null;
    _password = null;

    // Clear from secure storage
    try {
      await _storage.deleteAll();
    } catch (e) {
      debugPrint('Error clearing credentials: $e');
    }

    notifyListeners();
  }
}
