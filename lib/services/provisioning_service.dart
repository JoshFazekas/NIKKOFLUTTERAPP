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
const defaultWifiSsid = 'Hav3n Production_IoT';
const defaultWifiPassword = '12345678';

// Device announce URL (hardcoded for production)
const deviceAnnounceUrl =
    'https://stg-api.havenlighting.com/api/Device/DeviceAnnounce';

// Add device to location URL
const addDeviceToLocationUrl =
    'https://stg-api.havenlighting.com/api/Devices/AddDeviceToLocation';

// Auto location IDs based on device type
const autoLocationIdXmini = '28599';
const autoLocationIdXseries = '28600';
const autoLocationIdXpoe = '28724';

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

/// Device info obtained from WHO_AM_I command
class DeviceInfo {
  final String deviceType; // "X-Series" or "X-Mini"
  final String macAddress;
  final String firmwareVersion;
  final String last4Mac;

  DeviceInfo({
    required this.deviceType,
    required this.macAddress,
    required this.firmwareVersion,
  }) : last4Mac = macAddress.length >= 4 
          ? macAddress.substring(macAddress.length - 4).toUpperCase()
          : macAddress.toUpperCase();
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
  final _deviceInfoController = StreamController<DeviceInfo>.broadcast();
  final _deviceAddedController = StreamController<void>.broadcast();

  Stream<ProvisioningStatus> get statusStream => _statusController.stream;
  Stream<String> get messageStream => _messageController.stream;
  Stream<ProvisioningResult> get resultsStream => _resultsController.stream;
  Stream<DeviceInfo> get deviceInfoStream => _deviceInfoController.stream;
  Stream<void> get deviceAddedStream => _deviceAddedController.stream;

  // Stored log messages (persists across screen navigations)
  final List<String> _logMessages = [];
  List<String> get logMessages => List.unmodifiable(_logMessages);

  /// Add a message to the log and broadcast it
  void _addMessage(String message) {
    final timestamp = DateTime.now();
    final timeStr = '${timestamp.hour.toString().padLeft(2, '0')}:${timestamp.minute.toString().padLeft(2, '0')}:${timestamp.second.toString().padLeft(2, '0')}';
    final formattedMessage = '[$timeStr] $message';
    
    _logMessages.add(formattedMessage);
    // Keep only last 200 messages
    if (_logMessages.length > 200) {
      _logMessages.removeAt(0);
    }
    // Broadcast the original message (listeners add their own timestamp if needed)
    _messageController.add(message);
  }

  /// Clear all stored log messages
  void clearLogMessages() {
    _logMessages.clear();
  }

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
      _addMessage('Provisioning already running');
      return;
    }

    // Use provided values or defaults
    final effectiveSsid = (ssid != null && ssid.isNotEmpty)
        ? ssid
        : defaultWifiSsid;
    final effectivePassword = (wifiPassword != null && wifiPassword.isNotEmpty)
        ? wifiPassword
        : defaultWifiPassword;

    _isRunning = true;
    _shouldStop = false;

    _addMessage('Starting provisioning loop...');
    _addMessage('WiFi SSID: $effectiveSsid');
    _addMessage('Location ID: $locationId');
    _statusController.add(ProvisioningStatus.idle);

    while (!_shouldStop) {
      try {
        // 1. Scan until we find a strong Haven device
        _statusController.add(ProvisioningStatus.scanning);
        _addMessage(
          'Scanning for nearby Haven devices (RSSI between $rssiMaxThreshold and $rssiMinThreshold dBm)...',
        );

        final scanResult = await _scanUntilStrongSignal();

        if (_shouldStop) break;

        final device = scanResult.device;
        final deviceName = device.platformName.isNotEmpty
            ? device.platformName
            : scanResult.advertisementData.advName;
        final bluetoothId = device.remoteId.toString();

        _statusController.add(ProvisioningStatus.deviceFound);
        _addMessage(
          'Found device: $deviceName (RSSI: ${scanResult.rssi} dBm)',
        );
        _addMessage('Bluetooth Remote ID: $bluetoothId');

        // Connect, get MAC, fetch API key, and provision - all in one session
        _statusController.add(ProvisioningStatus.connecting);
        _addMessage('Connecting to $deviceName...');

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

          _resultsController.add(
            ProvisioningResult(
              deviceName: deviceName,
              macAddress: deviceMac,
              success: true,
              response: 'Provisioning complete',
            ),
          );
        } catch (e) {
          _addMessage('Failed to provision device: $e');
          _resultsController.add(
            ProvisioningResult(
              deviceName: deviceName,
              macAddress: 'Unknown',
              success: false,
              error: 'Failed to provision: $e',
            ),
          );
          await Future.delayed(const Duration(seconds: 2));
          continue;
        }
      } catch (e) {
        _statusController.add(ProvisioningStatus.error);
        _addMessage('Error: $e');

        // Brief pause on error before retrying
        await Future.delayed(const Duration(seconds: 2));
      }

      if (!_shouldStop) {
        _addMessage('---');
        _addMessage('Looping back to scan for next device...');
        await Future.delayed(const Duration(seconds: 1));
      }
    }

    _isRunning = false;
    _statusController.add(ProvisioningStatus.idle);
    _addMessage('Provisioning loop stopped.');
  }

  /// Stop the provisioning loop
  void stopProvisioningLoop() {
    _shouldStop = true;
    FlutterBluePlus.stopScan();
    _addMessage('Stopping provisioning loop...');
  }

  /// Provision a specific device (called from home screen when strong signal detected)
  Future<void> provisionDevice({
    required ScanResult scanResult,
    required String bearerToken,
    bool autoLocationMode = true,
    String? customLocationId,
    String? ssid,
    String? wifiPassword,
  }) async {
    if (_isRunning) {
      _addMessage('Provisioning already in progress');
      return;
    }

    _isRunning = true;
    _shouldStop = false;

    // Use provided values or defaults
    final effectiveSsid = (ssid != null && ssid.isNotEmpty)
        ? ssid
        : defaultWifiSsid;
    final effectivePassword = (wifiPassword != null && wifiPassword.isNotEmpty)
        ? wifiPassword
        : defaultWifiPassword;

    try {
      final device = scanResult.device;
      final deviceName = device.platformName.isNotEmpty
          ? device.platformName
          : scanResult.advertisementData.advName;
      final bluetoothId = device.remoteId.toString();

      // Determine location ID based on mode and device type
      String locationId;
      if (autoLocationMode) {
        locationId = _getAutoLocationId(deviceName);
        _addMessage(
          'Auto location mode: Assigned location ID $locationId for device type',
        );
      } else {
        locationId = customLocationId ?? '';
        if (locationId.isEmpty) {
          throw Exception(
            'Custom location ID is required when not using auto mode',
          );
        }
        _addMessage(
          'Custom location mode: Using location ID $locationId',
        );
      }

      _statusController.add(ProvisioningStatus.deviceFound);
      _addMessage(
        'Found device: $deviceName (RSSI: ${scanResult.rssi} dBm)',
      );
      _addMessage('Bluetooth Remote ID: $bluetoothId');

      // Connect, get MAC, fetch API key, and provision - all in one session
      _statusController.add(ProvisioningStatus.connecting);
      _addMessage('Connecting to $deviceName...');

      final deviceMac = await _connectGetMacAndProvision(
        device,
        deviceName: deviceName,
        bearerToken: bearerToken,
        locationId: locationId,
        ssid: effectiveSsid,
        wifiPassword: effectivePassword,
      );

      _resultsController.add(
        ProvisioningResult(
          deviceName: deviceName,
          macAddress: deviceMac,
          success: true,
          response: 'Provisioning complete',
        ),
      );
    } catch (e) {
      _statusController.add(ProvisioningStatus.error);
      _addMessage('Error: $e');
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

      // Determine preliminary device type from device name (before connecting)
      String preliminaryDeviceType;
      if (deviceName.toUpperCase().contains('MINI')) {
        preliminaryDeviceType = 'X-Mini';
      } else {
        preliminaryDeviceType = 'X-Series';
      }
      
      // Extract last 4 characters from device name (usually the MAC suffix)
      String preliminaryMacSuffix = '';
      if (deviceName.length >= 4) {
        // Try to get last 4 hex characters from the device name
        final hexMatch = RegExp(r'[0-9A-Fa-f]{4}$').firstMatch(deviceName);
        if (hexMatch != null) {
          preliminaryMacSuffix = hexMatch.group(0)!.toUpperCase();
        } else {
          preliminaryMacSuffix = deviceName.substring(deviceName.length - 4).toUpperCase();
        }
      }

      // Emit preliminary device info immediately (with placeholder firmware)
      _deviceInfoController.add(DeviceInfo(
        deviceType: preliminaryDeviceType,
        macAddress: preliminaryMacSuffix, // Just the suffix for now
        firmwareVersion: '---',
      ));

      await device.connect(timeout: const Duration(seconds: 10));
      _statusController.add(ProvisioningStatus.connected);
      _addMessage('Connected to device');

      final services = await device.discoverServices();

      // Find Haven service and characteristic
      BluetoothCharacteristic? characteristic;
      for (var service in services) {
        if (service.uuid.toString().toUpperCase() ==
            havenServiceUuid.toUpperCase()) {
          for (var char in service.characteristics) {
            if (char.uuid.toString().toUpperCase() ==
                havenCharacteristicUuid.toUpperCase()) {
              characteristic = char;
              break;
            }
          }
        }
      }

      if (characteristic == null) {
        throw Exception('Haven characteristic not found');
      }
      _addMessage('Found Haven characteristic');

      // Helper function to send command and read response
      Future<String> sendCommand(String command) async {
        _addMessage('[TX→] $command');
        await characteristic!.write(
          utf8.encode(command),
          withoutResponse: false,
        );

        // Small delay to allow device to process
        await Future.delayed(const Duration(milliseconds: 100));

        final bytes = await characteristic.read();
        final response = utf8.decode(bytes, allowMalformed: true);
        _addMessage('[←RX] $response');
        return response;
      }

      // Step 1: Send WHO_AM_I command to get MAC address
      _addMessage('--- Getting Device MAC Address ---');
      _addMessage('[TX→] <CONSOLE.WHO_AM_I()>');
      await characteristic.write(
        utf8.encode('<CONSOLE.WHO_AM_I()>'),
        withoutResponse: false,
      );
      await Future.delayed(const Duration(milliseconds: 500));

      final bytes = await characteristic.read();
      _addMessage('[←RX] Raw bytes (${bytes.length}): $bytes');

      final response = utf8.decode(bytes, allowMalformed: true);
      _addMessage('[←RX] Decoded string: $response');
      _addMessage('═══════════════════════════════════════');
      _addMessage('WHO_AM_I FULL RESPONSE:');
      _addMessage('Length: ${response.length} chars');
      _addMessage('Content: "$response"');
      _addMessage('═══════════════════════════════════════');

      // Parse the response to get DeviceID (MAC address), DeviceType, and FirmwareVersion
      String macAddress;
      String firmwareVersion = '---';
      String deviceType = 'Unknown';
      
      try {
        _addMessage('Attempting to parse response...');

        // Try to extract JSON from response - handle full JSON with nested content
        // Find the first { and match until the last }
        final startIndex = response.indexOf('{');
        final endIndex = response.lastIndexOf('}');
        
        if (startIndex != -1 && endIndex != -1 && endIndex > startIndex) {
          final jsonStr = response.substring(startIndex, endIndex + 1);
          _addMessage('Found JSON: $jsonStr');
          
          // Clean up common JSON issues (spaces in keys, etc.)
          String cleanedJson = jsonStr
              .replaceAll(RegExp(r'"\s*,\s*"'), '","')  // Fix spacing around commas
              .replaceAll("'", '"');  // Replace single quotes with double quotes
          
          final data = jsonDecode(cleanedJson) as Map<String, dynamic>;
          _addMessage('Parsed JSON keys: ${data.keys.toList()}');
          
          // Extract MAC address
          final deviceId =
              data['DeviceID'] ??
              data['deviceId'] ??
              data['MAC'] ??
              data['mac'] ??
              data['device_id'] ??
              data['macAddress'];
          if (deviceId == null) {
            _addMessage(
              'No DeviceID/MAC key found in JSON. Available keys: ${data.keys.toList()}',
            );
            _addMessage('Full JSON data: $data');
            throw Exception('DeviceID not found in response');
          }
          macAddress = deviceId.toString();
          _addMessage('Extracted MAC: $macAddress');
          
          // Extract firmware version (handle various key formats including "Firmware_ Version")
          firmwareVersion = (data['Firmware_ Version'] ??
                            data['Firmware_Version'] ??
                            data['FirmwareVersion'] ?? 
                            data['firmwareVersion'] ?? 
                            data['Firmware'] ?? 
                            data['firmware'] ?? 
                            data['FW'] ?? 
                            data['fw'] ?? 
                            '---').toString();
          _addMessage('Extracted Firmware: $firmwareVersion');
          
          // Extract device type (handle Model_Name field)
          deviceType = (data['Model_Name'] ??
                       data['ModelName'] ??
                       data['DeviceType'] ?? 
                       data['deviceType'] ?? 
                       data['Type'] ?? 
                       data['type'] ?? 
                       'Unknown').toString();
          _addMessage('Extracted DeviceType: $deviceType');
        } else {
          _addMessage('No JSON found, trying regex MAC pattern...');
          final macMatch = RegExp(
            r'([0-9A-Fa-f]{2}[:-]?){5}[0-9A-Fa-f]{2}',
          ).firstMatch(response);
          if (macMatch != null) {
            macAddress = macMatch
                .group(0)!
                .replaceAll(':', '')
                .replaceAll('-', '')
                .toUpperCase();
            _addMessage('Found MAC via regex: $macAddress');
          } else {
            _addMessage('No MAC pattern found in response');
            throw Exception('Could not parse MAC from response');
          }
        }
      } catch (e) {
        _addMessage('═══════════════════════════════════════');
        _addMessage('ERROR PARSING WHO_AM_I: $e');
        _addMessage('═══════════════════════════════════════');
        rethrow;
      }

      macAddress = macAddress
          .replaceAll(':', '')
          .replaceAll('-', '')
          .toUpperCase();
      _addMessage('Device WiFi MAC: $macAddress');

      // Determine friendly device type from deviceName or deviceType field
      String friendlyDeviceType;
      if (deviceType != 'Unknown' && deviceType.isNotEmpty) {
        friendlyDeviceType = deviceType;
      } else if (deviceName.toUpperCase().contains('MINI')) {
        friendlyDeviceType = 'X-Mini';
      } else {
        friendlyDeviceType = 'X-Series';
      }

      // Emit device info for UI display
      _deviceInfoController.add(DeviceInfo(
        deviceType: friendlyDeviceType,
        macAddress: macAddress,
        firmwareVersion: firmwareVersion,
      ));

      // Step 2: Get API key from server (while still connected to BLE)
      _addMessage('--- Fetching API Key from Server ---');
      _addMessage('Fetching API key for MAC: $macAddress');
      String apiKey;
      try {
        apiKey = await _getDeviceApiKey(macAddress, bearerToken, deviceName);
        _addMessage('Got API key: ${apiKey.substring(0, 8)}...');
      } catch (e) {
        _addMessage('Failed to get API key: $e');
        throw Exception('Failed to get API key: $e');
      }

      // Step 3: Now provision the device (still connected)
      _statusController.add(ProvisioningStatus.provisioning);

      // Set API Key first
      _addMessage('--- Setting API Key ---');
      await sendCommand('<SYSTEM.SET({"API_KEY":"$apiKey"})>');
      await Future.delayed(const Duration(milliseconds: 500));

      // Set WiFi SSID
      _addMessage('--- Setting WiFi SSID ---');
      await sendCommand('<WIFI.SET({"SSID1":"$ssid"})>');
      await Future.delayed(const Duration(milliseconds: 500));

      // Set WiFi Password
      _addMessage('--- Setting WiFi Password ---');
      await sendCommand('<WIFI.SET({"PASS1":"$wifiPassword"})>');
      await Future.delayed(const Duration(milliseconds: 500));

      // Set Device Announce URL (hardcoded production URL)
      _addMessage('--- Setting Device Announce URL ---');
      await sendCommand(
        '<SYSTEM.SET({"DEVICE_ANNOUNCE_URL":"$deviceAnnounceUrl"})>',
      );
      await Future.delayed(const Duration(milliseconds: 500));

      // Connect to server
      _addMessage('--- Connecting to Server ---');
      await sendCommand('<SYSTEM.SERVER_CONNECT()>');
      await Future.delayed(const Duration(milliseconds: 500));

      // Step 4: Add device to location (before stopping BLE)
      _addMessage('--- Adding Device to Location ---');
      try {
        await _addDeviceToLocation(
          deviceId: macAddress,
          locationId: locationId,
          bearerToken: bearerToken,
        );
        _addMessage('✓ Device added to location!');
      } catch (e) {
        _addMessage('Warning: Failed to add device to location: $e');
        // Don't throw - continue with BLE stop
      }

      // Stop BLE advertising - this completes provisioning
      _addMessage('--- Stopping BLE Advertising ---');
      try {
        await sendCommand('<BLE.ADVERT_STOP()>');
      } catch (e) {
        _addMessage('BLE stop command failed (device may have disconnected): $e');
        // Continue anyway - the provisioning was successful
      }
      
      // Notify that device was successfully added (BLE stop sent = device provisioned)
      _deviceAddedController.add(null);
      _addMessage('📊 Counter incremented - device added!');

      // Device is now provisioned, disconnect cleanly
      try {
        await device.disconnect();
      } catch (_) {
        // Device may have already disconnected
      }

      _addMessage('✓ Provisioning complete!');
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

    final bodyMap = {'deviceId': deviceId, 'locationId': locationIdInt};
    final body = jsonEncode(bodyMap);

    // Log request to debug overlay
    apiLogger.logRequest(
      method: 'POST',
      endpoint: addDeviceToLocationUrl,
      headers: {
        'Content-Type': 'application/json',
        'Authorization':
            'Bearer ${bearerToken.length > 20 ? '${bearerToken.substring(0, 20)}...' : bearerToken}',
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
      throw Exception(
        'Failed to add device to location: ${response.statusCode}',
      );
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
        final rssiInRange =
            result.rssi >= rssiMinThreshold && result.rssi <= rssiMaxThreshold;
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
  Future<String> _getDeviceApiKey(
    String macAddress,
    String bearerToken,
    String deviceName,
  ) async {
    final apiLogger = ApiLogger();

    // Normalize MAC: remove colons, uppercase
    final normalizedMac = macAddress.replaceAll(':', '').toUpperCase();

    // Determine controllerTypeId based on device name
    final controllerTypeId = _getControllerTypeId(deviceName);

    final url =
        'https://stg-api.havenlighting.com/api/Device/GetCredentials/$normalizedMac?controllerTypeId=$controllerTypeId';
    _addMessage('API Request URL: $url');

    // Log request to debug overlay
    apiLogger.logRequest(
      method: 'GET',
      endpoint: url,
      headers: {
        'Accept': 'application/json',
        'Authorization':
            'Bearer ${bearerToken.length > 20 ? '${bearerToken.substring(0, 20)}...' : bearerToken}',
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

    _addMessage('API Response Status: ${response.statusCode}');
    _addMessage('API Response Body: ${response.body}');

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
        throw Exception(
          'Device not registered in Haven system. MAC: $normalizedMac',
        );
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
      throw Exception(
        'Failed to get device credentials: ${response.statusCode}',
      );
    }
  }

  /// Dispose of resources
  void dispose() {
    _shouldStop = true;
    _statusController.close();
    _messageController.close();
    _resultsController.close();
  }

  /// Get auto location ID based on device type
  /// X-MINI = 28599, X-SERIES = 28600, X-POE = 28724
  String _getAutoLocationId(String deviceName) {
    final upperName = deviceName.toUpperCase();

    // Check for X-POE (location ID = 28724)
    if (upperName.contains('X-POE') ||
        upperName.contains('XPOE') ||
        upperName.contains('X POE')) {
      _addMessage(
        '✓ Detected X-POE → Auto Location ID: $autoLocationIdXpoe',
      );
      return autoLocationIdXpoe;
    }

    // Check for X-MINI (location ID = 28599)
    if (upperName.contains('X-MINI') ||
        upperName.contains('XMINI') ||
        upperName.contains('X MINI')) {
      _addMessage(
        '✓ Detected X-MINI → Auto Location ID: $autoLocationIdXmini',
      );
      return autoLocationIdXmini;
    }

    // Check for X-SERIES (location ID = 28600)
    if (upperName.contains('X-SERIES') ||
        upperName.contains('XSERIES') ||
        upperName.contains('X SERIES')) {
      _addMessage(
        '✓ Detected X-SERIES → Auto Location ID: $autoLocationIdXseries',
      );
      return autoLocationIdXseries;
    }

    // Default fallback to X-MINI location
    _addMessage(
      '⚠ Unknown device type "$deviceName", defaulting to X-MINI location ID: $autoLocationIdXmini',
    );
    return autoLocationIdXmini;
  }

  /// Get controllerTypeId based on Bluetooth device name
  /// X-MINI = 10, X-SERIES = 8, X-POE = 9
  int _getControllerTypeId(String deviceName) {
    final upperName = deviceName.toUpperCase();
    _addMessage(
      'Determining controller type for device: "$deviceName"',
    );

    // Check for X-POE (controllerTypeId = 9)
    if (upperName.contains('X-POE') ||
        upperName.contains('XPOE') ||
        upperName.contains('X POE')) {
      _addMessage('✓ Detected X-POE → controllerTypeId: 9');
      return 9;
    }

    // Check for X-MINI (controllerTypeId = 10)
    if (upperName.contains('X-MINI') ||
        upperName.contains('XMINI') ||
        upperName.contains('X MINI')) {
      _addMessage('✓ Detected X-MINI → controllerTypeId: 10');
      return 10;
    }

    // Check for X-SERIES (controllerTypeId = 8)
    if (upperName.contains('X-SERIES') ||
        upperName.contains('XSERIES') ||
        upperName.contains('X SERIES')) {
      _addMessage('✓ Detected X-SERIES → controllerTypeId: 8');
      return 8;
    }

    // Default fallback - log warning
    _addMessage(
      '⚠ Unknown device type "$deviceName", defaulting to controllerTypeId: 1',
    );
    return 1;
  }
}
