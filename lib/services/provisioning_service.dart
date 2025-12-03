import 'dart:async';
import 'dart:convert';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:http/http.dart' as http;
import 'api_logger.dart';

// Haven Controller Service UUIDs
const havenServiceUuid = '00000006-8C26-476F-89A7-A108033A69C7';
const havenCharacteristicUuid = '0000000B-8C26-476F-89A7-A108033A69C7';

// Signal strength threshold range - device must be in specific RSSI range
// Only provision devices with RSSI between -10 and -25 (inclusive)
const rssiMinThreshold = -25; // Weakest acceptable signal
const rssiMaxThreshold = -10; // Strongest acceptable signal

// Default WiFi credentials
const defaultWifiSsid = 'shopHaven iOT';
const defaultWifiPassword = '12345678';

// Device announce URL (hardcoded for production)
const deviceAnnounceUrl = 'https://stg-api.havenlighting.com/api/Device/DeviceAnnounce';

// Add device to location URL
const addDeviceToLocationUrl = 'https://stg-api.havenlighting.com/api/Devices/AddDeviceToLocation';

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
class ProvisioningService {
  static final ProvisioningService _instance = ProvisioningService._internal();
  factory ProvisioningService() => _instance;
  ProvisioningService._internal();

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
    required String locationId,
    String? ssid,
    String? wifiPassword,
  }) async {
    if (_isRunning) {
      _messageController.add('Provisioning already running');
      return;
    }

    // Use provided values or defaults
    final effectiveSsid = (ssid != null && ssid.isNotEmpty) ? ssid : defaultWifiSsid;
    final effectivePassword = (wifiPassword != null && wifiPassword.isNotEmpty) ? wifiPassword : defaultWifiPassword;

    _isRunning = true;
    _shouldStop = false;
    
    _messageController.add('Starting provisioning loop...');
    _messageController.add('WiFi SSID: $effectiveSsid');
    _messageController.add('Location ID: $locationId');
    _statusController.add(ProvisioningStatus.idle);

    while (!_shouldStop) {
      try {
        // 1. Scan until we find a strong Haven device
        _statusController.add(ProvisioningStatus.scanning);
        _messageController.add('Scanning for nearby Haven devices (RSSI between $rssiMaxThreshold and $rssiMinThreshold dBm)...');
        
        final scanResult = await _scanUntilStrongSignal();
        
        if (_shouldStop) break;
        
        final device = scanResult.device;
        final deviceName = device.platformName.isNotEmpty 
            ? device.platformName 
            : scanResult.advertisementData.advName;
        final bluetoothId = device.remoteId.toString();
        
        _statusController.add(ProvisioningStatus.deviceFound);
        _messageController.add('Found device: $deviceName (RSSI: ${scanResult.rssi} dBm)');
        _messageController.add('Bluetooth Remote ID: $bluetoothId');

        // Connect, get MAC, fetch API key, and provision - all in one session
        _statusController.add(ProvisioningStatus.connecting);
        _messageController.add('Connecting to $deviceName...');
        
        String deviceMac;
        try {
          deviceMac = await _connectGetMacAndProvision(
            device,
            deviceName: deviceName,
            bearerToken: bearerToken,
            locationId: locationId,
            ssid: effectiveSsid,
            wifiPassword: effectivePassword,
          );
          
          _resultsController.add(ProvisioningResult(
            deviceName: deviceName,
            macAddress: deviceMac,
            success: true,
            response: 'Provisioning complete',
          ));
        } catch (e) {
          _messageController.add('Failed to provision device: $e');
          _resultsController.add(ProvisioningResult(
            deviceName: deviceName,
            macAddress: 'Unknown',
            success: false,
            error: 'Failed to provision: $e',
          ));
          await Future.delayed(const Duration(seconds: 2));
          continue;
        }

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

  /// Provision a specific device (called from home screen when strong signal detected)
  Future<void> provisionDevice({
    required ScanResult scanResult,
    required String bearerToken,
    required String locationId,
    String? ssid,
    String? wifiPassword,
  }) async {
    if (_isRunning) {
      _messageController.add('Provisioning already in progress');
      return;
    }

    _isRunning = true;
    _shouldStop = false;

    // Use provided values or defaults
    final effectiveSsid = (ssid != null && ssid.isNotEmpty) ? ssid : defaultWifiSsid;
    final effectivePassword = (wifiPassword != null && wifiPassword.isNotEmpty) ? wifiPassword : defaultWifiPassword;

    try {
      final device = scanResult.device;
      final deviceName = device.platformName.isNotEmpty 
          ? device.platformName 
          : scanResult.advertisementData.advName;
      final bluetoothId = device.remoteId.toString();

      _statusController.add(ProvisioningStatus.deviceFound);
      _messageController.add('Found device: $deviceName (RSSI: ${scanResult.rssi} dBm)');
      _messageController.add('Bluetooth Remote ID: $bluetoothId');

      // Connect, get MAC, fetch API key, and provision - all in one session
      _statusController.add(ProvisioningStatus.connecting);
      _messageController.add('Connecting to $deviceName...');
      
      final deviceMac = await _connectGetMacAndProvision(
        device,
        deviceName: deviceName,
        bearerToken: bearerToken,
        locationId: locationId,
        ssid: effectiveSsid,
        wifiPassword: effectivePassword,
      );
      
      _resultsController.add(ProvisioningResult(
        deviceName: deviceName,
        macAddress: deviceMac,
        success: true,
        response: 'Provisioning complete',
      ));

    } catch (e) {
      _statusController.add(ProvisioningStatus.error);
      _messageController.add('Error: $e');
    }

    _isRunning = false;
    _statusController.add(ProvisioningStatus.idle);
  }

  /// Connect to device, get MAC via WHO_AM_I, fetch API key, and provision - all in one session
  Future<String> _connectGetMacAndProvision(
    BluetoothDevice device, {
    required String deviceName,
    required String bearerToken,
    required String locationId,
    required String ssid,
    required String wifiPassword,
  }) async {
    try {
      // Stop scanning before connecting
      await FlutterBluePlus.stopScan();
      
      await device.connect(timeout: const Duration(seconds: 10));
      _statusController.add(ProvisioningStatus.connected);
      _messageController.add('Connected to device');

      final services = await device.discoverServices();
      
      // Find Haven service and characteristic
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

      // Helper function to send command and read response
      Future<String> sendCommand(String command) async {
        _messageController.add('[TX→] $command');
        await characteristic!.write(utf8.encode(command), withoutResponse: false);
        
        // Small delay to allow device to process
        await Future.delayed(const Duration(milliseconds: 100));
        
        final bytes = await characteristic.read();
        final response = utf8.decode(bytes, allowMalformed: true);
        _messageController.add('[←RX] $response');
        return response;
      }

      // Step 1: Send WHO_AM_I command to get MAC address
      _messageController.add('--- Getting Device MAC Address ---');
      _messageController.add('[TX→] <CONSOLE.WHO_AM_I()>');
      await characteristic.write(utf8.encode('<CONSOLE.WHO_AM_I()>'), withoutResponse: false);
      await Future.delayed(const Duration(milliseconds: 500));

      final bytes = await characteristic.read();
      _messageController.add('[←RX] Raw bytes (${bytes.length}): $bytes');
      
      final response = utf8.decode(bytes, allowMalformed: true);
      _messageController.add('[←RX] Decoded string: $response');
      _messageController.add('═══════════════════════════════════════');
      _messageController.add('WHO_AM_I FULL RESPONSE:');
      _messageController.add('Length: ${response.length} chars');
      _messageController.add('Content: "$response"');
      _messageController.add('═══════════════════════════════════════');

      // Parse the response to get DeviceID (MAC address)
      String macAddress;
      try {
        _messageController.add('Attempting to parse response...');
        
        // Try to extract JSON from response
        final jsonMatch = RegExp(r'\{[^}]+\}').firstMatch(response);
        if (jsonMatch != null) {
          final jsonStr = jsonMatch.group(0)!;
          _messageController.add('Found JSON: $jsonStr');
          final data = jsonDecode(jsonStr) as Map<String, dynamic>;
          _messageController.add('Parsed JSON keys: ${data.keys.toList()}');
          final deviceId = data['DeviceID'] ?? data['deviceId'] ?? data['MAC'] ?? data['mac'] ?? data['device_id'] ?? data['macAddress'];
          if (deviceId == null) {
            _messageController.add('No DeviceID/MAC key found in JSON. Available keys: ${data.keys.toList()}');
            _messageController.add('Full JSON data: $data');
            throw Exception('DeviceID not found in response');
          }
          macAddress = deviceId.toString();
          _messageController.add('Extracted MAC: $macAddress');
        } else {
          _messageController.add('No JSON found, trying regex MAC pattern...');
          final macMatch = RegExp(r'([0-9A-Fa-f]{2}[:-]?){5}[0-9A-Fa-f]{2}').firstMatch(response);
          if (macMatch != null) {
            macAddress = macMatch.group(0)!.replaceAll(':', '').replaceAll('-', '').toUpperCase();
            _messageController.add('Found MAC via regex: $macAddress');
          } else {
            _messageController.add('No MAC pattern found in response');
            throw Exception('Could not parse MAC from response');
          }
        }
      } catch (e) {
        _messageController.add('═══════════════════════════════════════');
        _messageController.add('ERROR PARSING WHO_AM_I: $e');
        _messageController.add('═══════════════════════════════════════');
        rethrow;
      }

      macAddress = macAddress.replaceAll(':', '').replaceAll('-', '').toUpperCase();
      _messageController.add('Device WiFi MAC: $macAddress');

      // Step 2: Get API key from server (while still connected to BLE)
      _messageController.add('--- Fetching API Key from Server ---');
      _messageController.add('Fetching API key for MAC: $macAddress');
      String apiKey;
      try {
        apiKey = await _getDeviceApiKey(macAddress, bearerToken, deviceName);
        _messageController.add('Got API key: ${apiKey.substring(0, 8)}...');
      } catch (e) {
        _messageController.add('Failed to get API key: $e');
        throw Exception('Failed to get API key: $e');
      }

      // Step 3: Now provision the device (still connected)
      _statusController.add(ProvisioningStatus.provisioning);

      // Set API Key first
      _messageController.add('--- Setting API Key ---');
      await sendCommand('<SYSTEM.SET({"API_KEY":"$apiKey"})>');
      await Future.delayed(const Duration(milliseconds: 500));

      // Set WiFi SSID
      _messageController.add('--- Setting WiFi SSID ---');
      await sendCommand('<WIFI.SET({"SSID1":"$ssid"})>');
      await Future.delayed(const Duration(milliseconds: 500));

      // Set WiFi Password
      _messageController.add('--- Setting WiFi Password ---');
      await sendCommand('<WIFI.SET({"PASS1":"$wifiPassword"})>');
      await Future.delayed(const Duration(milliseconds: 500));

      // Set Device Announce URL (hardcoded production URL)
      _messageController.add('--- Setting Device Announce URL ---');
      await sendCommand('<SYSTEM.SET({"DEVICE_ANNOUNCE_URL":"$deviceAnnounceUrl"})>');
      await Future.delayed(const Duration(milliseconds: 500));

      // Connect to server
      _messageController.add('--- Connecting to Server ---');
      await sendCommand('<SYSTEM.SERVER_CONNECT()>');
      await Future.delayed(const Duration(milliseconds: 500));

      // Step 4: Add device to location (before stopping BLE)
      _messageController.add('--- Adding Device to Location ---');
      try {
        await _addDeviceToLocation(
          deviceId: macAddress,
          locationId: locationId,
          bearerToken: bearerToken,
        );
        _messageController.add('✓ Device added to location!');
      } catch (e) {
        _messageController.add('Warning: Failed to add device to location: $e');
        // Don't throw - continue with BLE stop
      }

      // Stop BLE advertising - this completes provisioning
      _messageController.add('--- Stopping BLE Advertising ---');
      await sendCommand('<BLE.ADVERT_STOP()>');
      
      // Device is now provisioned, disconnect cleanly
      try {
        await device.disconnect();
      } catch (_) {
        // Device may have already disconnected
      }

      _messageController.add('✓ Provisioning complete!');
      _statusController.add(ProvisioningStatus.success);

      return macAddress;
    } catch (e) {
      // Ensure we disconnect on error
      try {
        await device.disconnect();
      } catch (_) {}
      rethrow;
    }
  }

  /// Add device to location via API
  Future<void> _addDeviceToLocation({
    required String deviceId,
    required String locationId,
    required String bearerToken,
  }) async {
    final apiLogger = ApiLogger();

    // Parse locationId as int (it's a 5-digit number)
    final locationIdInt = int.tryParse(locationId);
    if (locationIdInt == null) {
      throw Exception('Invalid location ID: $locationId (must be a number)');
    }

    final bodyMap = {
      'deviceId': deviceId,
      'locationId': locationIdInt,
    };
    final body = jsonEncode(bodyMap);

    // Log request to debug overlay
    apiLogger.logRequest(
      method: 'POST',
      endpoint: addDeviceToLocationUrl,
      headers: {
        'Content-Type': 'application/json',
        'Authorization': 'Bearer ${bearerToken.length > 20 ? '${bearerToken.substring(0, 20)}...' : bearerToken}',
      },
      body: bodyMap,
    );

    final response = await http.post(
      Uri.parse(addDeviceToLocationUrl),
      headers: {
        'Authorization': 'Bearer $bearerToken',
        'Accept': 'application/json',
        'Content-Type': 'application/json',
      },
      body: body,
    );

    // Log response to debug overlay
    dynamic responseBody;
    try {
      responseBody = jsonDecode(response.body);
    } catch (_) {
      responseBody = response.body;
    }

    if (response.statusCode == 200 || response.statusCode == 201) {
      apiLogger.logResponse(
        method: 'POST',
        endpoint: addDeviceToLocationUrl,
        statusCode: response.statusCode,
        body: responseBody,
      );
    } else if (response.statusCode == 401) {
      apiLogger.logError(
        method: 'POST',
        endpoint: addDeviceToLocationUrl,
        error: 'Authentication failed (401)',
      );
      throw Exception('Authentication failed. Please sign in again.');
    } else if (response.statusCode == 409) {
      apiLogger.logResponse(
        method: 'POST',
        endpoint: addDeviceToLocationUrl,
        statusCode: response.statusCode,
        body: 'Device already added to location (conflict)',
      );
      // Don't throw - this is okay
    } else {
      apiLogger.logError(
        method: 'POST',
        endpoint: addDeviceToLocationUrl,
        error: 'Status: ${response.statusCode}, Body: ${response.body}',
      );
      throw Exception('Failed to add device to location: ${response.statusCode}');
    }
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
        
        // Only provision devices with RSSI between -10 and -25 (inclusive)
        final rssiInRange = result.rssi >= rssiMinThreshold && result.rssi <= rssiMaxThreshold;
        if (isHavenDevice(name) && rssiInRange) {
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
  Future<String> _getDeviceApiKey(String macAddress, String bearerToken, String deviceName) async {
    final apiLogger = ApiLogger();
    
    // Normalize MAC: remove colons, uppercase
    final normalizedMac = macAddress.replaceAll(':', '').toUpperCase();
    
    // Determine controllerTypeId based on device name
    final controllerTypeId = _getControllerTypeId(deviceName);
    
    final url = 'https://stg-api.havenlighting.com/api/Device/GetCredentials/$normalizedMac?controllerTypeId=$controllerTypeId';
    _messageController.add('API Request URL: $url');

    // Log request to debug overlay
    apiLogger.logRequest(
      method: 'GET',
      endpoint: url,
      headers: {
        'Accept': 'application/json',
        'Authorization': 'Bearer ${bearerToken.length > 20 ? '${bearerToken.substring(0, 20)}...' : bearerToken}',
      },
    );

    final response = await http.get(
      Uri.parse(url),
      headers: {
        'Accept': 'application/json',
        'Authorization': 'Bearer $bearerToken',
        'Referer': 'https://portal.havenlighting.com/',
        'Origin': 'https://portal.havenlighting.com',
      },
    );
    
    _messageController.add('API Response Status: ${response.statusCode}');
    _messageController.add('API Response Body: ${response.body}');

    if (response.statusCode == 200) {
      // Response: ["API_KEY : 5a6d8c17-fda3-4252-bf3e-dc5220ab161b"]
      final List<dynamic> data = jsonDecode(response.body);
      
      // Log success response to debug overlay
      apiLogger.logResponse(
        method: 'GET',
        endpoint: url,
        statusCode: response.statusCode,
        body: data,
      );
      
      if (data.isEmpty) {
        throw Exception('Device not registered in Haven system. MAC: $normalizedMac');
      }
      
      final apiKeyString = data[0] as String;
      final parts = apiKeyString.split(' : ');
      
      if (parts.length < 2) {
        throw Exception('Invalid API key format received: $apiKeyString');
      }
      
      return parts[1];
    } else if (response.statusCode == 401) {
      apiLogger.logError(
        method: 'GET',
        endpoint: url,
        error: 'Authentication failed (401)',
      );
      throw Exception('Authentication failed. Please sign in again.');
    } else if (response.statusCode == 404) {
      apiLogger.logError(
        method: 'GET',
        endpoint: url,
        error: 'Device not found (404). MAC: $normalizedMac',
      );
      throw Exception('Device not found. MAC: $normalizedMac');
    } else {
      apiLogger.logError(
        method: 'GET',
        endpoint: url,
        error: 'Status: ${response.statusCode}, Body: ${response.body}',
      );
      throw Exception('Failed to get device credentials: ${response.statusCode}');
    }
  }

  /// Dispose of resources
  void dispose() {
    _shouldStop = true;
    _statusController.close();
    _messageController.close();
    _resultsController.close();
  }

  /// Get controllerTypeId based on Bluetooth device name
  /// X-MINI = 10, X-SERIES = 8
  int _getControllerTypeId(String deviceName) {
    final upperName = deviceName.toUpperCase();
    _messageController.add('Determining controller type for device: "$deviceName"');
    
    // Check for X-MINI (controllerTypeId = 10)
    if (upperName.contains('X-MINI') || 
        upperName.contains('XMINI') || 
        upperName.contains('X MINI')) {
      _messageController.add('✓ Detected X-MINI → controllerTypeId: 10');
      return 10;
    }
    
    // Check for X-SERIES (controllerTypeId = 8)
    if (upperName.contains('X-SERIES') || 
        upperName.contains('XSERIES') || 
        upperName.contains('X SERIES')) {
      _messageController.add('✓ Detected X-SERIES → controllerTypeId: 8');
      return 8;
    }
    
    // Default fallback - log warning
    _messageController.add('⚠ Unknown device type "$deviceName", defaulting to controllerTypeId: 1');
    return 1;
  }
}
