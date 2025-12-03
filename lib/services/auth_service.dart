import 'dart:convert';
import 'package:http/http.dart' as http;
import 'api_logger.dart';

class AuthService {
  static const String _baseUrl = 'https://stg-api.havenlighting.com/api';
  static const Map<String, String> _defaultHeaders = {
    'Accept': 'application/json',
    'Content-Type': 'application/json',
    'Referer': 'https://portal.havenlighting.com/',
    'Origin': 'https://portal.havenlighting.com',
  };

  final ApiLogger _logger = ApiLogger();

  /// Authenticates user with email and password
  /// Returns a map containing: token, refreshToken, id
  Future<Map<String, dynamic>> authenticate(String email, String password) async {
    const endpoint = '$_baseUrl/Auth/Authenticate';
    final body = {
      'userName': email,
      'password': password,
    };

    // Log the request
    _logger.logRequest(
      method: 'POST',
      endpoint: endpoint,
      headers: _defaultHeaders,
      body: body,
    );

    try {
      final response = await http.post(
        Uri.parse(endpoint),
        headers: _defaultHeaders,
        body: jsonEncode(body),
      );

      // Log the response
      _logger.logResponse(
        method: 'POST',
        endpoint: endpoint,
        statusCode: response.statusCode,
        body: response.body,
      );

      if (response.statusCode == 200) {
        return jsonDecode(response.body);
        // Returns: {"token": "...", "refreshToken": "...", "id": 123}
      } else {
        throw AuthException('Sign in failed. Please enter correct email/password.');
      }
    } catch (e) {
      if (e is AuthException) rethrow;
      
      // Log the error
      _logger.logError(
        method: 'POST',
        endpoint: endpoint,
        error: e,
      );
      
      throw AuthException('Sign in failed. Please check your connection and try again.');
    }
  }

  /// Gets device API key for a given MAC address
  /// Returns the API key string
  Future<String> getDeviceApiKey(String macAddress, String bearerToken) async {
    // Normalize MAC: remove colons, uppercase
    final normalizedMac = macAddress.replaceAll(':', '').toUpperCase();
    final endpoint = '$_baseUrl/Device/GetCredentials/$normalizedMac?controllerTypeId=1';
    
    final headers = {
      ..._defaultHeaders,
      'Authorization': 'Bearer $bearerToken',
    };

    // Log the request
    _logger.logRequest(
      method: 'GET',
      endpoint: endpoint,
      headers: headers,
    );

    try {
      final response = await http.get(
        Uri.parse(endpoint),
        headers: headers,
      );

      // Log the response
      _logger.logResponse(
        method: 'GET',
        endpoint: endpoint,
        statusCode: response.statusCode,
        body: response.body,
      );

      if (response.statusCode == 200) {
        // Response: ["API_KEY : 5a6d8c17-fda3-4252-bf3e-dc5220ab161b"]
        final List<dynamic> data = jsonDecode(response.body);
        final apiKeyString = data[0] as String;
        return apiKeyString.split(' : ')[1];
      } else {
        throw AuthException('Failed to get device credentials.');
      }
    } catch (e) {
      if (e is AuthException) rethrow;
      
      // Log the error
      _logger.logError(
        method: 'GET',
        endpoint: endpoint,
        error: e,
      );
      
      throw AuthException('Failed to get device credentials. Please try again.');
    }
  }

  /// Validates if the current token is still valid by making a test API call
  /// Returns true if token is valid, false if expired/invalid
  Future<bool> validateToken(String bearerToken) async {
    // Use a lightweight endpoint to check token validity
    const endpoint = '$_baseUrl/User/GetCurrent';
    
    final headers = {
      ..._defaultHeaders,
      'Authorization': 'Bearer $bearerToken',
    };

    try {
      final response = await http.get(
        Uri.parse(endpoint),
        headers: headers,
      );

      // Token is valid if we get a 200 response
      return response.statusCode == 200;
    } catch (e) {
      return false;
    }
  }
}

class AuthException implements Exception {
  final String message;
  AuthException(this.message);

  @override
  String toString() => message;
}

class SessionExpiredException implements Exception {
  final String message;
  SessionExpiredException([this.message = 'Session has expired']);

  @override
  String toString() => message;
}
