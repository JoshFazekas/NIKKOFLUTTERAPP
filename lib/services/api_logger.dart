import 'package:flutter/foundation.dart';

enum LogType { request, response, error }

class ApiLogEntry {
  final DateTime timestamp;
  final LogType type;
  final String method;
  final String endpoint;
  final Map<String, dynamic>? headers;
  final dynamic body;
  final int? statusCode;

  ApiLogEntry({
    required this.timestamp,
    required this.type,
    required this.method,
    required this.endpoint,
    this.headers,
    this.body,
    this.statusCode,
  });

  String get typeLabel {
    switch (type) {
      case LogType.request:
        return '→ REQUEST';
      case LogType.response:
        return '← RESPONSE';
      case LogType.error:
        return '✕ ERROR';
    }
  }
}

class ApiLogger extends ChangeNotifier {
  static final ApiLogger _instance = ApiLogger._internal();
  factory ApiLogger() => _instance;
  ApiLogger._internal();

  final List<ApiLogEntry> _logs = [];
  List<ApiLogEntry> get logs => List.unmodifiable(_logs);

  void logRequest({
    required String method,
    required String endpoint,
    Map<String, dynamic>? headers,
    dynamic body,
  }) {
    _logs.insert(
      0,
      ApiLogEntry(
        timestamp: DateTime.now(),
        type: LogType.request,
        method: method,
        endpoint: endpoint,
        headers: headers,
        body: body,
      ),
    );
    notifyListeners();
  }

  void logResponse({
    required String method,
    required String endpoint,
    required int statusCode,
    dynamic body,
  }) {
    _logs.insert(
      0,
      ApiLogEntry(
        timestamp: DateTime.now(),
        type: LogType.response,
        method: method,
        endpoint: endpoint,
        statusCode: statusCode,
        body: body,
      ),
    );
    notifyListeners();
  }

  void logError({
    required String method,
    required String endpoint,
    dynamic error,
  }) {
    _logs.insert(
      0,
      ApiLogEntry(
        timestamp: DateTime.now(),
        type: LogType.error,
        method: method,
        endpoint: endpoint,
        body: error.toString(),
      ),
    );
    notifyListeners();
  }

  void clearLogs() {
    _logs.clear();
    notifyListeners();
  }
}
