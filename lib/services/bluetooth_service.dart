import 'dart:async';
import 'dart:convert';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:http/http.dart' as http;

// Haven Controller Service UUIDs
const havenServiceUuid = '00000006-8C26-476F-89A7-A108033A69C7';
const havenCharacteristicUuid = '0000000B-8C26-476F-89A7-A108033A69C7';

// Signal strength threshold - device must be very close
const rssiThreshold = -25;

// Hardcoded WiFi credentials
const wifiSsid = 'Hav3n Production_IoT';
const wifiPassword = '12345678';

/// Manages a single BLE connection to a Haven controller
class HavenBluetoothConnection {
  BluetoothDevice? _device;
  BluetoothCharacteristic? _characteristic;
  String? _connectedDeviceName;

  bool get isConnected => _device != null && _characteristic != null;
  String? get connectedDeviceName => _connectedDeviceName;

  /// Connect to a Haven device and discover the characteristic
  Future<void> connect(BluetoothDevice device, {String? deviceName}) async {
    // Stop any ongoing scan before connecting
    await FlutterBluePlus.stopScan();
    
    // Connect with timeout
    await device.connect(timeout: const Duration(seconds: 10));

    // Discover services & find our characteristic
    final services = await device.discoverServices();

    for (var service in services) {
      if (service.uuid.toString().toUpperCase() == havenServiceUuid.toUpperCase()) {
        for (var char in service.characteristics) {
          if (char.uuid.toString().toUpperCase() == havenCharacteristicUuid.toUpperCase()) {
            _characteristic = char;
            break;
          }
        }
      }
    }

    if (_characteristic == null) {
      await device.disconnect();
      throw Exception('Haven characteristic not found');
    }

    _device = device;
    _connectedDeviceName = deviceName ?? device.platformName;
  }

  /// Write a command string to the device
  Future<void> write(String command) async {
    if (_characteristic == null) {
      throw Exception('Not connected to device');
    }
    await _characteristic!.write(utf8.encode(command), withoutResponse: false);
  }

  /// Read response from the device as a Map
  Future<Map<String, dynamic>> read() async {
    if (_characteristic == null) {
      throw Exception('Not connected to device');
    }
    final bytes = await _characteristic!.read();
    final response = utf8.decode(bytes);

    if (response.isEmpty) return {};
    return jsonDecode(response);
  }

  /// Read response from the device as raw string
  Future<String> readString() async {
    if (_characteristic == null) {
      throw Exception('Not connected to device');
    }
    final bytes = await _characteristic!.read();
    return utf8.decode(bytes);
  }

  /// Send a command and read the response
  Future<Map<String, dynamic>> sendCommand(String command) async {
    await write(command);
    return await read();
  }

  /// Disconnect from the device
  Future<void> disconnect() async {
    await _device?.disconnect();
    _device = null;
    _characteristic = null;
    _connectedDeviceName = null;
  }
}

/// Status updates for the provisioning process
enum ProvisioningStatus {
  idle,
  scanning,
  deviceFound,
  connected,
  connecting,
  discoveringServices,
  provisioning,
  waitingForResponse,
  success,
  error,
  disconnecting,
}

/// Result of a single provisioning attempt
class ProvisioningResult {
  final String deviceName;
  final String macAddress;
  final bool success;
  final String? response;
  final String? error;
  final DateTime timestamp;

  ProvisioningResult({
    required this.deviceName,
    required this.macAddress,
    required this.success,
    this.response,
    this.error,
  }) : timestamp = DateTime.now();
}

/// Bluetooth provisioning service for Haven devices
class BluetoothService {
  static final BluetoothService _instance = BluetoothService._internal();
  factory BluetoothService() => _instance;
  BluetoothService._internal();

  // Stream controllers
  final _statusController = StreamController<ProvisioningStatus>.broadcast();
  final _messageController = StreamController<String>.broadcast();
  final _resultsController = StreamController<ProvisioningResult>.broadcast();

  Stream<ProvisioningStatus> get statusStream => _statusController.stream;
  Stream<String> get messageStream => _messageController.stream;
  Stream<ProvisioningResult> get resultsStream => _resultsController.stream;

  bool _isRunning = false;
  bool _shouldStop = false;
  
  bool get isRunning => _isRunning;

  /// Check if a device name belongs to a Haven device
  bool isHavenDevice(String? name) {
    if (name == null || name.isEmpty) return false;
    final upperName = name.toUpperCase();
    return upperName.startsWith('HVN') || upperName.startsWith('HAVEN');
  }

  /// Start the provisioning loop
  Future<void> startProvisioningLoop({
    required String bearerToken,
  }) async {
    if (_isRunning) {
      _messageController.add('Provisioning already running');
      return;
    }

    _isRunning = true;
    _shouldStop = false;
    
    _messageController.add('Starting provisioning loop...');
    _statusController.add(ProvisioningStatus.idle);

    while (!_shouldStop) {
      try {
        // 1. Scan until we find a strong Haven device
        _statusController.add(ProvisioningStatus.scanning);
        _messageController.add('Scanning for nearby Haven devices (RSSI >= $rssiThreshold dBm)...');
        
        final scanResult = await _scanUntilStrongSignal();
        
        if (_shouldStop) break;
        
        final device = scanResult.device;
        final deviceName = device.platformName.isNotEmpty 
            ? device.platformName 
            : scanResult.advertisementData.advName;
        final macAddress = device.remoteId.toString();
        
        _statusController.add(ProvisioningStatus.deviceFound);
        _messageController.add('Found device: $deviceName (RSSI: ${scanResult.rssi} dBm)');

        // 2. Get API key for this device
        _messageController.add('Fetching API key for MAC: $macAddress...');
        String apiKey;
        try {
          apiKey = await _getDeviceApiKey(macAddress, bearerToken);
          _messageController.add('Got API key: ${apiKey.substring(0, 8)}...');
        } catch (e) {
          _messageController.add('Failed to get API key: $e');
          _resultsController.add(ProvisioningResult(
            deviceName: deviceName,
            macAddress: macAddress,
            success: false,
            error: 'Failed to get API key: $e',
          ));
          await Future.delayed(const Duration(seconds: 2));
          continue;
        }

        // 3. Connect and provision
        _statusController.add(ProvisioningStatus.connecting);
        _messageController.add('Connecting to $deviceName...');
        
        final response = await _connectAndProvision(
          device,
          ssid: wifiSsid,
          wifiPassword: wifiPassword,
          apiKey: apiKey,
        );
        
        _statusController.add(ProvisioningStatus.success);
        _messageController.add('✓ Provisioned $deviceName successfully!');
        _messageController.add('Response: $response');
        
        _resultsController.add(ProvisioningResult(
          deviceName: deviceName,
          macAddress: macAddress,
          success: true,
          response: response,
        ));

      } catch (e) {
        _statusController.add(ProvisioningStatus.error);
        _messageController.add('Error: $e');
        
        // Brief pause on error before retrying
        await Future.delayed(const Duration(seconds: 2));
      }
      
      if (!_shouldStop) {
        _messageController.add('---');
        _messageController.add('Looping back to scan for next device...');
        await Future.delayed(const Duration(seconds: 1));
      }
    }

    _isRunning = false;
    _statusController.add(ProvisioningStatus.idle);
    _messageController.add('Provisioning loop stopped.');
  }

  /// Stop the provisioning loop
  void stopProvisioningLoop() {
    _shouldStop = true;
    FlutterBluePlus.stopScan();
    _messageController.add('Stopping provisioning loop...');
  }

  /// Scan until a Haven device with strong signal is found
  Future<ScanResult> _scanUntilStrongSignal() async {
    final completer = Completer<ScanResult>();
    StreamSubscription<List<ScanResult>>? subscription;

    await FlutterBluePlus.startScan();

    subscription = FlutterBluePlus.scanResults.listen((results) {
      for (final result in results) {
        final name = result.device.platformName.isNotEmpty 
            ? result.device.platformName 
            : result.advertisementData.advName;
        
        if (isHavenDevice(name) && result.rssi >= rssiThreshold) {
          if (!completer.isCompleted) {
            completer.complete(result);
          }
        }
      }
    });

    final device = await completer.future;

    await FlutterBluePlus.stopScan();
    await subscription.cancel();

    return device;
  }

  /// Get API key for a device from the server
  Future<String> _getDeviceApiKey(String macAddress, String bearerToken) async {
    // Normalize MAC: remove colons, uppercase
    final normalizedMac = macAddress.replaceAll(':', '').toUpperCase();

    final response = await http.get(
      Uri.parse('https://stg-api.havenlighting.com/api/Device/GetCredentials/$normalizedMac?controllerTypeId=1'),
      headers: {
        'Accept': 'application/json',
        'Authorization': 'Bearer $bearerToken',
        'Referer': 'https://portal.havenlighting.com/',
        'Origin': 'https://portal.havenlighting.com',
      },
    );

    if (response.statusCode == 200) {
      // Response: ["API_KEY : 5a6d8c17-fda3-4252-bf3e-dc5220ab161b"]
      final List<dynamic> data = jsonDecode(response.body);
      final apiKeyString = data[0] as String;
      return apiKeyString.split(' : ')[1];
    } else {
      throw Exception('Failed to get device credentials: ${response.statusCode}');
    }
  }

  /// Connect to device and send provisioning data
  Future<String?> _connectAndProvision(
    BluetoothDevice device, {
    required String ssid,
    required String wifiPassword,
    required String apiKey,
  }) async {
    try {
      // Stop scanning before connecting
      await FlutterBluePlus.stopScan();
      
      // 1. Connect
      _statusController.add(ProvisioningStatus.connecting);
      await device.connect(timeout: const Duration(seconds: 10));
      _statusController.add(ProvisioningStatus.connected);
      _messageController.add('Connected!');

      // 2. Discover services
      _statusController.add(ProvisioningStatus.discoveringServices);
      _messageController.add('Discovering services...');
      final services = await device.discoverServices();

      // 4. Find Haven service and characteristic
      BluetoothCharacteristic? characteristic;
      for (var service in services) {
        if (service.uuid.toString().toUpperCase() == havenServiceUuid.toUpperCase()) {
          for (var char in service.characteristics) {
            if (char.uuid.toString().toUpperCase() == havenCharacteristicUuid.toUpperCase()) {
              characteristic = char;
              break;
            }
          }
        }
      }

      if (characteristic == null) {
        throw Exception('Haven characteristic not found');
      }
      _messageController.add('Found Haven characteristic');

      // 5. Write provisioning JSON to characteristic
      _statusController.add(ProvisioningStatus.provisioning);
      final jsonData = jsonEncode({
        'ssid': ssid,
        'password': wifiPassword,
        'apiKey': apiKey,
      });
      _messageController.add('Sending provisioning data...');
      await characteristic.write(utf8.encode(jsonData), withoutResponse: false);

      // 6. Read response from characteristic
      _statusController.add(ProvisioningStatus.waitingForResponse);
      _messageController.add('Reading response...');
      String? response;
      try {
        final bytes = await characteristic.read();
        response = utf8.decode(bytes);
        if (response.isEmpty) {
          response = 'Empty response received';
        }
      } catch (e) {
        response = 'Error reading response: $e';
      }

      // 7. Disconnect
      _statusController.add(ProvisioningStatus.disconnecting);
      await device.disconnect();
      _messageController.add('Disconnected');

      return response;
    } catch (e) {
      // Ensure we disconnect on error
      try {
        await device.disconnect();
      } catch (_) {}
      rethrow;
    }
  }

  /// Dispose of resources
  void dispose() {
    _shouldStop = true;
    _statusController.close();
    _messageController.close();
    _resultsController.close();
  }
}
