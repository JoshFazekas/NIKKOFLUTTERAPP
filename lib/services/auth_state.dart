import 'package:flutter/foundation.dart';

class AuthState extends ChangeNotifier {
  static final AuthState _instance = AuthState._internal();
  factory AuthState() => _instance;
  AuthState._internal();

  String? _token;
  String? _refreshToken;
  int? _userId;

  String? get token => _token;
  String? get refreshToken => _refreshToken;
  int? get userId => _userId;
  bool get isLoggedIn => _token != null;

  void login({
    required String token,
    required String refreshToken,
    required int userId,
  }) {
    _token = token;
    _refreshToken = refreshToken;
    _userId = userId;
    notifyListeners();
  }

  void logout() {
    _token = null;
    _refreshToken = null;
    _userId = null;
    notifyListeners();
  }
}
