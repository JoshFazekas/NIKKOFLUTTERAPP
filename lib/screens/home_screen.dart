import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:lottie/lottie.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:audioplayers/audioplayers.dart';
import '../services/auth_state.dart';
import '../services/provisioning_service.dart';
import 'sign_in_screen.dart';
import 'menu_screen.dart';

/// RSSI threshold for auto-provisioning (in dBm). 
/// Devices must have signal strength >= this value to trigger connection.
/// Typical values: -25 (very close), -35 (close), -50 (medium range)
const int kDefaultProximityRssiThreshold = -25;

/// Storage key for provisioned count
const String _provisionedCountKey = 'provisioned_count_today';
const String _provisionedCountDateKey = 'provisioned_count_date';

/// Storage keys for scan settings
const String _wifiSsidKey = 'scan_settings_wifi_ssid';
const String _wifiPasswordKey = 'scan_settings_wifi_password';
const String _rssiThresholdKey = 'scan_settings_rssi_threshold';
const String _locationModeKey = 'scan_settings_location_mode';
const String _customLocationIdKey = 'scan_settings_custom_location_id';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with WidgetsBindingObserver {
  final _provisioningService = ProvisioningService();
  
  // Secure storage for persisting provisioned count
  static const _storage = FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
    iOptions: IOSOptions(accessibility: KeychainAccessibility.first_unlock),
  );

  ProvisioningStatus _status = ProvisioningStatus.idle;
  final List<String> _logMessages = [];
  final List<ProvisioningResult> _results = [];
  final ScrollController _logScrollController = ScrollController();

  // Scan settings
  String _wifiSsid = defaultWifiSsid;
  String _wifiPassword = defaultWifiPassword;
  int _rssiThreshold = kDefaultProximityRssiThreshold; // RSSI threshold for auto-connect
  String _locationMode = locationModeNikko; // 'nikko', 'chase', or 'custom'
  String _customLocationId = ''; // Only used when _locationMode is 'custom'

  // Bluetooth device list
  final Map<String, ScanResult> _discoveredDevices = {};
  final Set<String> _provisionedDeviceIds =
      {}; // Track already provisioned devices
  int _provisionedCount = 0; // Counter for successfully provisioned devices
  StreamSubscription<List<ScanResult>>? _scanSubscription;
  Timer? _scanRefreshTimer;
  Timer? _uiUpdateTimer;
  bool _isScanning = false;
  bool _isScanInProgress = false; // Track if a scan operation is running
  bool _pendingUiUpdate = false; // Throttle UI updates
  bool _provisioningCooldown = false; // Prevent immediate re-provisioning
  String? _connectedDeviceId;
  bool _isProvisioningRunning = false;

  StreamSubscription<ProvisioningStatus>? _statusSubscription;
  StreamSubscription<String>? _messageSubscription;
  StreamSubscription<ProvisioningResult>? _resultsSubscription;
  StreamSubscription<void>? _deviceAddedSubscription;

  // Overlay state
  bool _showProvisioningOverlay = false;
  bool _showSuccessOverlay = false;
  
  // Close proximity countdown state
  bool _showCloseProximityOverlay = false;
  String? _proximityDeviceId;
  String? _proximityDeviceName;
  Timer? _proximityCountdownTimer;
  int _proximityCountdownSeconds = 2;

  // Device info from WHO_AM_I
  DeviceInfo? _currentDeviceInfo;
  StreamSubscription<DeviceInfo>? _deviceInfoSubscription;

  // Audio player for success sound (lazy initialized)
  AudioPlayer? _audioPlayer;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _loadProvisionedCount();
    _loadScanSettings();
    _setupListeners();
    _startDeviceScan();
  }

  /// Load the provisioned count from storage (resets daily)
  Future<void> _loadProvisionedCount() async {
    try {
      final today = DateTime.now().toIso8601String().substring(0, 10); // YYYY-MM-DD
      final storedDate = await _storage.read(key: _provisionedCountDateKey);
      
      if (storedDate == today) {
        // Same day, load the count
        final countStr = await _storage.read(key: _provisionedCountKey);
        if (countStr != null && mounted) {
          setState(() {
            _provisionedCount = int.tryParse(countStr) ?? 0;
          });
        }
      } else {
        // New day, reset the count
        await _storage.write(key: _provisionedCountDateKey, value: today);
        await _storage.write(key: _provisionedCountKey, value: '0');
      }
    } catch (e) {
      debugPrint('Error loading provisioned count: $e');
    }
  }

  /// Save the provisioned count to storage
  Future<void> _saveProvisionedCount() async {
    try {
      final today = DateTime.now().toIso8601String().substring(0, 10);
      await _storage.write(key: _provisionedCountDateKey, value: today);
      await _storage.write(key: _provisionedCountKey, value: _provisionedCount.toString());
    } catch (e) {
      debugPrint('Error saving provisioned count: $e');
    }
  }

  /// Load scan settings from storage
  Future<void> _loadScanSettings() async {
    try {
      final ssid = await _storage.read(key: _wifiSsidKey);
      final password = await _storage.read(key: _wifiPasswordKey);
      final rssiStr = await _storage.read(key: _rssiThresholdKey);
      final locationModeStr = await _storage.read(key: _locationModeKey);
      final customLocationId = await _storage.read(key: _customLocationIdKey);

      if (mounted) {
        setState(() {
          if (ssid != null && ssid.isNotEmpty) {
            _wifiSsid = ssid;
          }
          if (password != null && password.isNotEmpty) {
            _wifiPassword = password;
          }
          if (rssiStr != null) {
            _rssiThreshold = int.tryParse(rssiStr) ?? kDefaultProximityRssiThreshold;
          }
          if (locationModeStr != null && locationModeStr.isNotEmpty) {
            _locationMode = locationModeStr;
          }
          if (customLocationId != null) {
            _customLocationId = customLocationId;
          }
        });
      }
    } catch (e) {
      debugPrint('Error loading scan settings: $e');
    }
  }

  /// Save scan settings to storage
  Future<void> _saveScanSettings() async {
    try {
      await _storage.write(key: _wifiSsidKey, value: _wifiSsid);
      await _storage.write(key: _wifiPasswordKey, value: _wifiPassword);
      await _storage.write(key: _rssiThresholdKey, value: _rssiThreshold.toString());
      await _storage.write(key: _locationModeKey, value: _locationMode);
      await _storage.write(key: _customLocationIdKey, value: _customLocationId);
    } catch (e) {
      debugPrint('Error saving scan settings: $e');
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _stopDeviceScan();
    _uiUpdateTimer?.cancel();
    _proximityCountdownTimer?.cancel();
    _statusSubscription?.cancel();
    _messageSubscription?.cancel();
    _resultsSubscription?.cancel();
    _deviceAddedSubscription?.cancel();
    _deviceInfoSubscription?.cancel();
    _logScrollController.dispose();
    _audioPlayer?.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    // Stop provisioning when app is minimized or closed
    if (state == AppLifecycleState.paused || 
        state == AppLifecycleState.inactive ||
        state == AppLifecycleState.detached) {
      if (_isProvisioningRunning) {
        _stopProvisioning();
      }
    }
  }

  void _startDeviceScan() async {
    final hasPermissions = await _checkPermissions();
    if (!hasPermissions) return;

    // Cancel any existing subscriptions first
    _scanRefreshTimer?.cancel();
    _scanSubscription?.cancel();
    await FlutterBluePlus.stopScan();

    setState(() {
      _isScanning = true;
      _isScanInProgress = true;
      _discoveredDevices.clear();
    });

    // Listen for scan results - use onScanResults which clears between scans
    // This prevents cached results from previous scans being re-used
    _scanSubscription = FlutterBluePlus.onScanResults.listen(
      (results) {
        if (mounted && _isScanning) {
          // Update the device map silently (no setState yet)
          for (final result in results) {
            final deviceId = result.device.remoteId.toString();
            _discoveredDevices[deviceId] = result;
          }
          // Mark that we have pending updates
          _pendingUiUpdate = true;
        }
      },
      onError: (e) {
        debugPrint('Scan error: $e');
      },
    );

    // Throttle UI updates to every 500ms to avoid overwhelming the UI
    _uiUpdateTimer = Timer.periodic(const Duration(milliseconds: 500), (_) {
      if (mounted && _isScanning && _pendingUiUpdate) {
        _pendingUiUpdate = false;
        setState(() {});
        _checkForAutoProvisioning();
      }
    });

    // Platform-specific scanning approach
    if (Platform.isAndroid) {
      // Android has a 5 scans per 30 seconds limit!
      // Use a single continuous scan with NO timeout for continuous scanning
      // The scan runs indefinitely until we call stopScan()
      try {
        await FlutterBluePlus.startScan(
          androidUsesFineLocation: true,
          continuousUpdates: true, // Get continuous RSSI updates
        );
      } catch (e) {
        debugPrint('Android scan start error: $e');
      }

      // For Android, we DON'T restart the scan - we let it run continuously
      // Just periodically check for auto-provisioning
      _scanRefreshTimer = Timer.periodic(const Duration(seconds: 1), (_) {
        if (mounted && _isScanning) {
          _checkForAutoProvisioning();
        }
      });
    } else {
      // iOS: Can use continuous scanning without timeout
      try {
        await FlutterBluePlus.startScan(continuousUpdates: true);
      } catch (e) {
        debugPrint('iOS scan start error: $e');
      }

      // Periodically check for auto-provisioning
      _scanRefreshTimer = Timer.periodic(const Duration(seconds: 1), (_) {
        if (mounted && _isScanning) {
          _checkForAutoProvisioning();
        }
      });
    }
  }

  void _stopDeviceScan() async {
    _scanRefreshTimer?.cancel();
    _scanRefreshTimer = null;
    _uiUpdateTimer?.cancel();
    _uiUpdateTimer = null;
    _scanSubscription?.cancel();
    _scanSubscription = null;
    _isScanInProgress = false;
    _pendingUiUpdate = false;
    try {
      await FlutterBluePlus.stopScan();
    } catch (e) {
      debugPrint('Stop scan error: $e');
    }
    if (mounted) {
      setState(() {
        _isScanning = false;
      });
    }
  }

  void _refreshDeviceScan() {
    _stopDeviceScan();
    // Clear discovered devices immediately for visual feedback
    setState(() {
      _discoveredDevices.clear();
    });
    // Small delay to ensure clean stop, then restart
    Future.delayed(const Duration(milliseconds: 300), () {
      if (mounted) {
        _startDeviceScan();
      }
    });
  }

  /// Check if any Haven device has strong signal and should be auto-provisioned
  void _checkForAutoProvisioning() {
    // Only check if provisioning mode is ON and we're not already provisioning
    // Also skip if we're in cooldown period after a recent provisioning
    if (!_isProvisioningRunning ||
        _provisioningService.isRunning ||
        _provisioningCooldown) {
      return;
    }

    // If we're already counting down for a device, check if that device is still above threshold
    // STICK with this device - don't switch to another even if it's stronger
    if (_showCloseProximityOverlay && _proximityDeviceId != null) {
      final currentDevice = _discoveredDevices[_proximityDeviceId];
      if (currentDevice != null && currentDevice.rssi >= _rssiThreshold) {
        // Current device is still above threshold, let the countdown continue
        return;
      }
      // Current device dropped below threshold, cancel and look for another
      _cancelProximityCountdown();
    }

    // Find the first Haven device with strong signal
    ScanResult? strongSignalDevice;
    String? strongSignalDeviceId;
    String? strongSignalDeviceName;
    
    for (final entry in _discoveredDevices.entries) {
      final result = entry.value;
      final deviceId = entry.key;
      final deviceName = result.device.platformName.isNotEmpty
          ? result.device.platformName
          : result.advertisementData.advName;

      // Skip devices we've already provisioned in this session
      if (_provisionedDeviceIds.contains(deviceId)) {
        continue;
      }

      // Skip devices with positive dBm (invalid readings)
      if (result.rssi >= 0) {
        continue;
      }

      // Check if it's a Haven device with strong signal
      if (_provisioningService.isHavenDevice(deviceName) &&
          result.rssi >= _rssiThreshold) {
        strongSignalDevice = result;
        strongSignalDeviceId = deviceId;
        strongSignalDeviceName = deviceName;
        break;
      }
    }

    // If we found a strong signal device, start countdown for it
    if (strongSignalDevice != null && strongSignalDeviceId != null) {
      _startProximityCountdown(strongSignalDevice, strongSignalDeviceId, strongSignalDeviceName ?? 'Haven Device');
    }
  }

  /// Start the 2-second proximity countdown before connecting
  void _startProximityCountdown(ScanResult scanResult, String deviceId, String deviceName) {
    // Cancel any existing countdown
    _proximityCountdownTimer?.cancel();
    
    // Heavy haptic feedback when proximity detected - like a PS5 controller rumble!
    HapticFeedback.heavyImpact();
    
    setState(() {
      _showCloseProximityOverlay = true;
      _proximityDeviceId = deviceId;
      _proximityDeviceName = deviceName;
      _proximityCountdownSeconds = 2;
    });

    // Start countdown timer
    _proximityCountdownTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted) {
        timer.cancel();
        return;
      }

      // Check if device still has strong signal
      final currentDevice = _discoveredDevices[deviceId];
      if (currentDevice == null || currentDevice.rssi < _rssiThreshold) {
        // Device moved away, cancel countdown
        _cancelProximityCountdown();
        return;
      }

      // Haptic feedback on each countdown tick
      HapticFeedback.mediumImpact();

      setState(() {
        _proximityCountdownSeconds--;
      });

      if (_proximityCountdownSeconds <= 0) {
        timer.cancel();
        // Final strong haptic when connecting
        HapticFeedback.heavyImpact();
        _connectToDevice(scanResult, deviceId);
      }
    });
  }

  /// Cancel the proximity countdown
  void _cancelProximityCountdown() {
    _proximityCountdownTimer?.cancel();
    _proximityCountdownTimer = null;
    if (mounted && _showCloseProximityOverlay) {
      setState(() {
        _showCloseProximityOverlay = false;
        _proximityDeviceId = null;
        _proximityDeviceName = null;
        _proximityCountdownSeconds = 2;
      });
    }
  }

  /// Actually connect to the device after countdown completes
  void _connectToDevice(ScanResult scanResult, String deviceId) {
    // Cancel the proximity countdown timer
    _proximityCountdownTimer?.cancel();
    _proximityCountdownTimer = null;
    
    setState(() {
      _showCloseProximityOverlay = false;
      _proximityDeviceId = null;
      _proximityDeviceName = null;
      _proximityCountdownSeconds = 2;
      _connectedDeviceId = deviceId;
    });

    // Get the bearer token
    final authState = AuthState();
    final bearerToken = authState.token;

    if (bearerToken == null || bearerToken.isEmpty) {
      return;
    }

    // Trigger provisioning for this device
    _provisioningService.provisionDevice(
      scanResult: scanResult,
      bearerToken: bearerToken,
      ssid: _wifiSsid,
      wifiPassword: _wifiPassword,
      locationMode: _locationMode,
      customLocationId: _customLocationId,
    );

    // Stop scanning while provisioning
    _stopDeviceScan();
  }

  void _setupListeners() {
    _statusSubscription = _provisioningService.statusStream.listen((status) {
      if (mounted) {
        setState(() {
          _status = status;

          // Show provisioning overlay when connecting/provisioning
          if (status == ProvisioningStatus.connecting ||
              status == ProvisioningStatus.discoveringServices ||
              status == ProvisioningStatus.provisioning ||
              status == ProvisioningStatus.waitingForResponse) {
            _showProvisioningOverlay = true;
            _showSuccessOverlay = false;
            _stopDeviceScan();
          }

          // Note: Device info is now set immediately when connecting starts
          // (with preliminary data from BLE name), then updated after WHO_AM_I

          // Show success overlay when done
          if (status == ProvisioningStatus.success) {
            _showProvisioningOverlay = false;
            _showSuccessOverlay = true;

            // Note: Counter is incremented when BLE stop command is sent (deviceAddedStream)

            // Add the device to provisioned list so we don't re-provision it
            if (_connectedDeviceId != null) {
              _provisionedDeviceIds.add(_connectedDeviceId!);
            }
            _connectedDeviceId = null;

            // Clear cached devices so we get fresh scan results
            _discoveredDevices.clear();

            // Start cooldown period to prevent immediate re-provisioning
            _provisioningCooldown = true;

            // Auto-dismiss success overlay after 1.5 seconds and end cooldown
            Future.delayed(const Duration(milliseconds: 1500), () {
              if (mounted) {
                setState(() {
                  _showSuccessOverlay = false;
                  _provisioningCooldown = false;
                  _currentDeviceInfo = null; // Clear device info after success
                });
              }
            });
          }

          // Hide overlays on error and clear connected device
          if (status == ProvisioningStatus.error) {
            _showProvisioningOverlay = false;
            _showSuccessOverlay = false;
            _connectedDeviceId = null;
            _currentDeviceInfo = null;
          }

          // Clear connected device and resume scanning when idle
          if (status == ProvisioningStatus.idle) {
            _connectedDeviceId = null;
            _showProvisioningOverlay = false;
            // Resume scanning if provisioning mode is still ON
            if (_isProvisioningRunning && !_isScanning) {
              _startDeviceScan();
            }
          }
        });
      }
    });

    _messageSubscription = _provisioningService.messageStream.listen((message) {
      if (mounted) {
        setState(() {
          _logMessages.add('[${_formatTime(DateTime.now())}] $message');
          // Keep only last 100 messages
          if (_logMessages.length > 100) {
            _logMessages.removeAt(0);
          }

          // Extract connected device ID from "Connecting to" message
          if (message.contains('Connecting to')) {
            // Try to find the device by name in our discovered devices
            for (final entry in _discoveredDevices.entries) {
              final result = entry.value;
              final deviceName = result.device.platformName.isNotEmpty
                  ? result.device.platformName
                  : result.advertisementData.advName;
              if (message.contains(deviceName)) {
                _connectedDeviceId = entry.key;
                break;
              }
            }
          }
        });
        // Auto-scroll to bottom
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (_logScrollController.hasClients) {
            _logScrollController.animateTo(
              _logScrollController.position.maxScrollExtent,
              duration: const Duration(milliseconds: 200),
              curve: Curves.easeOut,
            );
          }
        });
      }
    });

    _resultsSubscription = _provisioningService.resultsStream.listen((result) {
      if (mounted) {
        setState(() {
          _results.insert(0, result); // Add to top
          // Keep only last 50 results
          if (_results.length > 50) {
            _results.removeLast();
          }
        });
      }
    });

    // Listen for device info updates from WHO_AM_I
    _deviceInfoSubscription = _provisioningService.deviceInfoStream.listen((info) {
      if (mounted) {
        setState(() {
          _currentDeviceInfo = info;
        });
      }
    });

    // Listen for device added events (BLE stop command sent = device provisioned)
    _deviceAddedSubscription = _provisioningService.deviceAddedStream.listen((_) {
      debugPrint('🎯 deviceAddedStream received! Current count: $_provisionedCount');
      if (mounted) {
        setState(() {
          _provisionedCount++;
          debugPrint('🎯 Counter incremented to: $_provisionedCount');
        });
        // Persist the count to storage
        _saveProvisionedCount();
        // Play success sound
        _playSuccessSound();
      }
    });
  }

  /// Play success sound when device is added
  Future<void> _playSuccessSound() async {
    try {
      _audioPlayer ??= AudioPlayer();
      await _audioPlayer!.play(AssetSource('sounds/ping.aac'));
    } catch (e) {
      debugPrint('Error playing success sound: $e');
    }
  }

  void _openMenuScreen(BuildContext context) {
    // Stop provisioning when navigating to menu
    if (_isProvisioningRunning) {
      _stopProvisioning();
    }
    Navigator.of(
      context,
    ).push(MaterialPageRoute(builder: (context) => const MenuScreen()));
  }

  String _formatTime(DateTime time) {
    return '${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')}:${time.second.toString().padLeft(2, '0')}';
  }

  Future<bool> _checkPermissions() async {
    if (Platform.isIOS) {
      try {
        // On iOS, we need to trigger the Bluetooth permission prompt by trying to scan
        // The permission dialog only appears when we actually try to use Bluetooth

        // First, try to start a scan - this will trigger the permission prompt if needed
        try {
          await FlutterBluePlus.startScan(
            timeout: const Duration(milliseconds: 500),
          );
          await FlutterBluePlus.stopScan();
        } catch (e) {
          debugPrint('Initial scan attempt: $e');
        }

        // Wait for state to settle
        await Future.delayed(const Duration(milliseconds: 500));

        // Now check the adapter state
        BluetoothAdapterState adapterState = BluetoothAdapterState.unknown;

        // Wait for up to 2 seconds for Bluetooth to report correct state
        for (int i = 0; i < 4; i++) {
          adapterState = await FlutterBluePlus.adapterState.first.timeout(
            const Duration(seconds: 1),
            onTimeout: () => BluetoothAdapterState.unknown,
          );

          // If we got a definitive state, break out
          if (adapterState == BluetoothAdapterState.on ||
              adapterState == BluetoothAdapterState.unauthorized ||
              adapterState == BluetoothAdapterState.off) {
            break;
          }

          // Wait a bit before retrying
          await Future.delayed(const Duration(milliseconds: 300));
        }

        if (adapterState == BluetoothAdapterState.unauthorized) {
          if (mounted) {
            _showPermissionDialog(
              'Please enable Bluetooth permission for this app in Settings.',
            );
          }
          return false;
        }

        if (adapterState != BluetoothAdapterState.on) {
          if (mounted) {
            _showBluetoothOffDialog();
          }
          return false;
        }
        return true;
      } catch (e) {
        debugPrint('Permission check error: $e');
        return true;
      }
    } else {
      final bluetoothScanStatus = await Permission.bluetoothScan.status;
      final bluetoothConnectStatus = await Permission.bluetoothConnect.status;

      bool allGranted =
          (bluetoothScanStatus.isGranted || bluetoothScanStatus.isLimited) &&
          (bluetoothConnectStatus.isGranted ||
              bluetoothConnectStatus.isLimited);

      if (allGranted) {
        return true;
      }

      List<Permission> permissionsToRequest = [];

      if (!bluetoothScanStatus.isGranted && !bluetoothScanStatus.isLimited) {
        permissionsToRequest.add(Permission.bluetoothScan);
      }
      if (!bluetoothConnectStatus.isGranted &&
          !bluetoothConnectStatus.isLimited) {
        permissionsToRequest.add(Permission.bluetoothConnect);
      }

      if (permissionsToRequest.isNotEmpty) {
        await permissionsToRequest.request();

        final newBluetoothScanStatus = await Permission.bluetoothScan.status;
        final newBluetoothConnectStatus =
            await Permission.bluetoothConnect.status;

        allGranted =
            (newBluetoothScanStatus.isGranted ||
                newBluetoothScanStatus.isLimited) &&
            (newBluetoothConnectStatus.isGranted ||
                newBluetoothConnectStatus.isLimited);
      }

      if (!allGranted) {
        if (mounted) {
          _showPermissionDialog(
            'Bluetooth permission is required to scan for Haven devices.',
          );
        }
        return false;
      }
      return true;
    }
  }

  Future<void> _startProvisioning() async {
    // Check if custom location ID is required but not provided
    if (_locationMode == locationModeCustom && _customLocationId.trim().isEmpty) {
      _showErrorDialog(
        'Custom Location ID is required. Please go to Scan Settings and enter a Location ID.',
      );
      return;
    }

    final hasPermissions = await _checkPermissions();
    if (!hasPermissions) return;

    // Get the bearer token from auth state
    final authState = AuthState();
    final bearerToken = authState.token;

    if (bearerToken == null || bearerToken.isEmpty) {
      _showErrorDialog('Not authenticated. Please sign in again.');
      return;
    }

    setState(() {
      _logMessages.clear();
      _isProvisioningRunning = true;
    });

    // Refresh the nearby devices list
    _refreshDeviceScan();

    // Immediately check if there's already a device with strong signal
    Future.delayed(const Duration(milliseconds: 500), () {
      _checkForAutoProvisioning();
    });
  }

  void _stopProvisioning() {
    _provisioningService.stopProvisioningLoop();
    _cancelProximityCountdown();
    setState(() {
      _isProvisioningRunning = false;
      _connectedDeviceId = null;
    });
    // Resume device scanning
    if (!_isScanning) {
      _startDeviceScan();
    }
  }

  void _showScanSettingsDialog() {
    final ssidController = TextEditingController(text: _wifiSsid);
    final passwordController = TextEditingController(text: _wifiPassword);
    final customLocationIdController = TextEditingController(
      text: _customLocationId,
    );
    bool obscurePassword = true;
    int rssiThreshold = _rssiThreshold;
    String locationMode = _locationMode;

    showDialog(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          backgroundColor: const Color(0xFF1E1E2D),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(20),
          ),
          title: const Row(
            children: [
              Icon(Icons.settings, color: Color(0xFF8B5CF6), size: 28),
              SizedBox(width: 12),
              Text(
                'Scan Settings',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 20,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ],
          ),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // WiFi SSID
                TextField(
                  controller: ssidController,
                  style: const TextStyle(color: Colors.white),
                  decoration: InputDecoration(
                    labelText: 'WiFi Name (SSID)',
                    labelStyle: TextStyle(color: Colors.grey.shade400),
                    hintText: 'Enter WiFi network name',
                    hintStyle: TextStyle(color: Colors.grey.shade600),
                    prefixIcon: Icon(Icons.wifi, color: Colors.grey.shade400),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: BorderSide.none,
                    ),
                    filled: true,
                    fillColor: const Color(0xFF2A2A3C),
                  ),
                ),
                const SizedBox(height: 16),

                // WiFi Password
                TextField(
                  controller: passwordController,
                  obscureText: obscurePassword,
                  style: const TextStyle(color: Colors.white),
                  decoration: InputDecoration(
                    labelText: 'WiFi Password',
                    labelStyle: TextStyle(color: Colors.grey.shade400),
                    hintText: 'Enter WiFi password',
                    hintStyle: TextStyle(color: Colors.grey.shade600),
                    prefixIcon: Icon(
                      Icons.lock_outline,
                      color: Colors.grey.shade400,
                    ),
                    suffixIcon: IconButton(
                      icon: Icon(
                        obscurePassword
                            ? Icons.visibility_outlined
                            : Icons.visibility_off_outlined,
                        color: Colors.grey.shade400,
                      ),
                      onPressed: () {
                        setDialogState(() {
                          obscurePassword = !obscurePassword;
                        });
                      },
                    ),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: BorderSide.none,
                    ),
                    filled: true,
                    fillColor: const Color(0xFF2A2A3C),
                  ),
                ),
                const SizedBox(height: 16),

                // RSSI Threshold Setting
                Align(
                  alignment: Alignment.centerLeft,
                  child: Padding(
                    padding: const EdgeInsets.only(left: 4, bottom: 8),
                    child: Text(
                      'RSSI Threshold',
                      style: TextStyle(
                        color: Colors.grey.shade400,
                        fontSize: 12,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ),
                ),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  decoration: BoxDecoration(
                    color: const Color(0xFF2A2A3C),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Column(
                    children: [
                      Row(
                        children: [
                          Icon(
                            Icons.signal_cellular_alt,
                            color: rssiThreshold >= -35 
                                ? const Color(0xFF22C55E) 
                                : rssiThreshold >= -60 
                                    ? const Color(0xFFFBBF24) 
                                    : const Color(0xFFEF4444),
                            size: 22,
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Text(
                              '$rssiThreshold dBm',
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 16,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                          Text(
                            rssiThreshold >= -35 
                                ? 'Very Close' 
                                : rssiThreshold >= -50 
                                    ? 'Close' 
                                    : rssiThreshold >= -70 
                                        ? 'Medium' 
                                        : 'Far',
                            style: TextStyle(
                              color: rssiThreshold >= -35 
                                  ? const Color(0xFF22C55E) 
                                  : rssiThreshold >= -60 
                                      ? const Color(0xFFFBBF24) 
                                      : const Color(0xFFEF4444),
                              fontSize: 12,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      SliderTheme(
                        data: SliderThemeData(
                          activeTrackColor: rssiThreshold >= -35 
                              ? const Color(0xFF22C55E) 
                              : rssiThreshold >= -60 
                                  ? const Color(0xFFFBBF24) 
                                  : const Color(0xFFEF4444),
                          inactiveTrackColor: Colors.grey.shade700,
                          thumbColor: Colors.white,
                          overlayColor: const Color(0xFF8B5CF6).withOpacity(0.2),
                          trackHeight: 4,
                        ),
                        child: Slider(
                          value: rssiThreshold.toDouble(),
                          min: -99,
                          max: -25,
                          divisions: 74,
                          onChanged: (value) {
                            setDialogState(() {
                              rssiThreshold = value.round();
                            });
                          },
                        ),
                      ),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text(
                            '-99 dBm',
                            style: TextStyle(
                              color: Colors.grey.shade600,
                              fontSize: 10,
                            ),
                          ),
                          Text(
                            '-25 dBm',
                            style: TextStyle(
                              color: Colors.grey.shade600,
                              fontSize: 10,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(
                    'Device must have signal ≥ $rssiThreshold dBm to auto-connect',
                    style: TextStyle(
                      color: Colors.grey.shade500,
                      fontSize: 12,
                    ),
                  ),
                ),
                const SizedBox(height: 16),

                // Location label
                Align(
                  alignment: Alignment.centerLeft,
                  child: Padding(
                    padding: const EdgeInsets.only(left: 4, bottom: 8),
                    child: Text(
                      'Location',
                      style: TextStyle(
                        color: Colors.grey.shade400,
                        fontSize: 12,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ),
                ),

                // Location ID Mode Dropdown - Styled like a TextField
                Container(
                  height: 56,
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  decoration: BoxDecoration(
                    color: const Color(0xFF2A2A3C),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Row(
                    children: [
                      Container(
                        width: 40,
                        alignment: Alignment.center,
                        child: Icon(
                          locationMode == locationModeNikko
                              ? Icons.auto_awesome
                              : locationMode == locationModeChase
                                  ? Icons.storefront
                                  : locationMode == locationModeDev
                                      ? Icons.developer_mode
                                      : Icons.location_on_outlined,
                          color: locationMode == locationModeCustom
                              ? Colors.grey.shade400
                              : const Color(0xFF8B5CF6),
                          size: 22,
                        ),
                      ),
                      Expanded(
                        child: DropdownButtonHideUnderline(
                          child: DropdownButton<String>(
                            value: locationMode,
                            isExpanded: true,
                            icon: Icon(
                              Icons.keyboard_arrow_down_rounded,
                              color: Colors.grey.shade400,
                            ),
                            dropdownColor: const Color(0xFF2A2A3C),
                            borderRadius: BorderRadius.circular(12),
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 16,
                            ),
                            items: [
                              DropdownMenuItem(
                                value: locationModeNikko,
                                child: Row(
                                  children: [
                                    Icon(
                                      Icons.auto_awesome,
                                      color: const Color(0xFF8B5CF6),
                                      size: 18,
                                    ),
                                    const SizedBox(width: 10),
                                    const Text('Nikko'),
                                  ],
                                ),
                              ),
                              DropdownMenuItem(
                                value: locationModeChase,
                                child: Row(
                                  children: [
                                    Icon(
                                      Icons.storefront,
                                      color: const Color(0xFF8B5CF6),
                                      size: 18,
                                    ),
                                    const SizedBox(width: 10),
                                    const Text('Chase'),
                                  ],
                                ),
                              ),
                              DropdownMenuItem(
                                value: locationModeDev,
                                child: Row(
                                  children: [
                                    Icon(
                                      Icons.developer_mode,
                                      color: const Color(0xFF8B5CF6),
                                      size: 18,
                                    ),
                                    const SizedBox(width: 10),
                                    const Text('Dev'),
                                  ],
                                ),
                              ),
                              DropdownMenuItem(
                                value: locationModeCustom,
                                child: Row(
                                  children: [
                                    Icon(
                                      Icons.location_on_outlined,
                                      color: Colors.grey.shade400,
                                      size: 18,
                                    ),
                                    const SizedBox(width: 10),
                                    const Text('Custom Location ID'),
                                  ],
                                ),
                              ),
                            ],
                            selectedItemBuilder: (context) => [
                              Align(
                                alignment: Alignment.centerLeft,
                                child: Text(
                                  'Nikko',
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 16,
                                  ),
                                ),
                              ),
                              Align(
                                alignment: Alignment.centerLeft,
                                child: Text(
                                  'Chase',
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 16,
                                  ),
                                ),
                              ),
                              Align(
                                alignment: Alignment.centerLeft,
                                child: Text(
                                  'Dev',
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 16,
                                  ),
                                ),
                              ),
                              Align(
                                alignment: Alignment.centerLeft,
                                child: Text(
                                  'Custom Location ID',
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 16,
                                  ),
                                ),
                              ),
                            ],
                            onChanged: (value) {
                              setDialogState(() {
                                locationMode = value ?? locationModeNikko;
                              });
                            },
                          ),
                        ),
                      ),
                    ],
                  ),
                ),

                // Nikko mode explanation
                if (locationMode == locationModeNikko)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Text(
                      'X-Mini → Location: Xmini\nX-Series → Location: Xseries\nX-POE → Location: Xpoe',
                      style: TextStyle(
                        color: Colors.grey.shade500,
                        fontSize: 12,
                      ),
                    ),
                  ),

                // Chase mode explanation
                if (locationMode == locationModeChase)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Text(
                      'X-Mini → Location: Production Xmini (28755)\nX-Series → Location: Production Xseries (28757)\nX-POE → Location: Production Xpoe (28756)',
                      style: TextStyle(
                        color: Colors.grey.shade500,
                        fontSize: 12,
                      ),
                    ),
                  ),

                // Dev mode explanation
                if (locationMode == locationModeDev)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Text(
                      'X-Mini → Location: Dev.Xmini (28758)\nX-Series → Location: Dev.Xseries (28760)\nX-POE → Location: Dev.Xpoe (28759)',
                      style: TextStyle(
                        color: Colors.grey.shade500,
                        fontSize: 12,
                      ),
                    ),
                  ),

                // Custom Location ID (only shown when Custom is selected)
                if (locationMode == locationModeCustom) ...[
                  const SizedBox(height: 16),
                  TextField(
                    controller: customLocationIdController,
                    style: const TextStyle(color: Colors.white),
                    keyboardType: TextInputType.number,
                    decoration: InputDecoration(
                      labelText: 'Custom Location ID *',
                      labelStyle: TextStyle(color: Colors.grey.shade400),
                      hintText: 'Enter location ID',
                      hintStyle: TextStyle(color: Colors.grey.shade600),
                      prefixIcon: Icon(
                        Icons.pin_drop_outlined,
                        color: Colors.grey.shade400,
                      ),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: BorderSide.none,
                      ),
                      filled: true,
                      fillColor: const Color(0xFF2A2A3C),
                    ),
                  ),
                ],
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: Text(
                'Cancel',
                style: TextStyle(color: Colors.white.withOpacity(0.7)),
              ),
            ),
            TextButton(
              onPressed: () {
                setState(() {
                  _wifiSsid = ssidController.text;
                  _wifiPassword = passwordController.text;
                  _rssiThreshold = rssiThreshold;
                  _locationMode = locationMode;
                  _customLocationId = customLocationIdController.text;
                });
                // Persist settings to storage
                _saveScanSettings();
                Navigator.of(context).pop();
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text(
                      'Settings saved (RSSI: $rssiThreshold dBm)',
                    ),
                    backgroundColor: const Color(0xFF22C55E),
                    behavior: SnackBarBehavior.floating,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                );
              },
              style: TextButton.styleFrom(
                backgroundColor: const Color(0xFF8B5CF6),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
                padding: const EdgeInsets.symmetric(
                  horizontal: 20,
                  vertical: 12,
                ),
              ),
              child: const Text(
                'Save',
                style: TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _showPermissionDialog(String message) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xFF1E1E2D),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: const Row(
          children: [
            Icon(Icons.bluetooth_disabled, color: Color(0xFFEF4444), size: 28),
            SizedBox(width: 12),
            Expanded(
              child: Text(
                'Permission Required',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
          ],
        ),
        content: Text(
          message,
          style: TextStyle(color: Colors.white.withOpacity(0.8), fontSize: 16),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: Text(
              'Cancel',
              style: TextStyle(color: Colors.white.withOpacity(0.7)),
            ),
          ),
          TextButton(
            onPressed: () {
              Navigator.of(context).pop();
              openAppSettings();
            },
            style: TextButton.styleFrom(
              backgroundColor: const Color(0xFF8B5CF6),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
            ),
            child: const Text(
              'Settings',
              style: TextStyle(color: Colors.white),
            ),
          ),
        ],
      ),
    );
  }

  void _showBluetoothOffDialog() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xFF1E1E2D),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: const Row(
          children: [
            Icon(Icons.bluetooth_disabled, color: Color(0xFFEF4444), size: 28),
            SizedBox(width: 12),
            Text(
              'Bluetooth Off',
              style: TextStyle(
                color: Colors.white,
                fontSize: 20,
                fontWeight: FontWeight.bold,
              ),
            ),
          ],
        ),
        content: Text(
          'Please turn on Bluetooth to scan for Haven devices.',
          style: TextStyle(color: Colors.white.withOpacity(0.8), fontSize: 16),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            style: TextButton.styleFrom(
              backgroundColor: const Color(0xFF8B5CF6),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
            ),
            child: const Text('OK', style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );
  }

  void _showDeviceCountDialog() {
    String message;
    String lottieAsset;
    Color countColor;
    
    if (_provisionedCount >= 20) {
      message = 'You have added a grand total of $_provisionedCount ${_provisionedCount == 1 ? 'device' : 'devices'} today!';
      lottieAsset = 'assets/lottie/fire.json';
      countColor = const Color(0xFFFF6B35); // Orange/fire color
    } else if (_provisionedCount >= 10) {
      message = 'You have added a decent $_provisionedCount ${_provisionedCount == 1 ? 'device' : 'devices'} today!';
      lottieAsset = 'assets/lottie/rocket.json';
      countColor = const Color(0xFF22C55E); // Green
    } else {
      message = 'You have added a lousy $_provisionedCount ${_provisionedCount == 1 ? 'device' : 'devices'} today!';
      lottieAsset = 'assets/lottie/angry.json';
      countColor = const Color(0xFFEF4444); // Red
    }

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xFF1E1E2D),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Column(
          children: [
            SizedBox(
              width: 100,
              height: 100,
              child: Lottie.asset(
                lottieAsset,
                fit: BoxFit.contain,
              ),
            ),
            const SizedBox(height: 12),
            const Text(
              'Devices Added',
              style: TextStyle(
                color: Colors.white,
                fontSize: 20,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 16),
            Text(
              '$_provisionedCount',
              style: TextStyle(
                color: countColor,
                fontSize: 64,
                fontWeight: FontWeight.bold,
              ),
            ),
          ],
        ),
        content: Text(
          message,
          style: TextStyle(color: Colors.white.withOpacity(0.8), fontSize: 16),
          textAlign: TextAlign.center,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            style: TextButton.styleFrom(
              backgroundColor: const Color(0xFF8B5CF6),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
            ),
            child: const Text('OK', style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );
  }

  void _showErrorDialog(String message) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xFF1E1E2D),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: const Row(
          children: [
            Icon(Icons.error_outline, color: Color(0xFFEF4444), size: 28),
            SizedBox(width: 12),
            Text(
              'Error',
              style: TextStyle(
                color: Colors.white,
                fontSize: 20,
                fontWeight: FontWeight.bold,
              ),
            ),
          ],
        ),
        content: Text(
          message,
          style: TextStyle(color: Colors.white.withOpacity(0.8), fontSize: 16),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            style: TextButton.styleFrom(
              backgroundColor: const Color(0xFF8B5CF6),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
            ),
            child: const Text('OK', style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );
  }

  void _logout(BuildContext context) async {
    _provisioningService.stopProvisioningLoop();
    // Get the current email before logout (it will be saved by logout())
    final currentEmail = AuthState().email;
    await AuthState().logout();
    if (!mounted) return;
    Navigator.of(context).pushAndRemoveUntil(
      MaterialPageRoute(builder: (context) => SignInScreen(initialEmail: currentEmail)),
      (route) => false,
    );
  }

  void _showLogoutConfirmation(BuildContext context) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xFF1E1E2D),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: const Row(
          children: [
            Icon(Icons.logout_rounded, color: Color(0xFF8B5CF6), size: 28),
            SizedBox(width: 12),
            Text(
              'Log Out',
              style: TextStyle(
                color: Colors.white,
                fontSize: 20,
                fontWeight: FontWeight.bold,
              ),
            ),
          ],
        ),
        content: Text(
          'Are you sure you want to log out?',
          style: TextStyle(color: Colors.white.withOpacity(0.8), fontSize: 16),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: Text(
              'Cancel',
              style: TextStyle(color: Colors.white.withOpacity(0.7)),
            ),
          ),
          TextButton(
            onPressed: () {
              Navigator.of(context).pop();
              _logout(context);
            },
            style: TextButton.styleFrom(
              backgroundColor: const Color(0xFFEF4444),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
            ),
            child: const Text('Log Out', style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );
  }

  String _getStatusText() {
    switch (_status) {
      case ProvisioningStatus.idle:
        return 'Ready';
      case ProvisioningStatus.scanning:
        return 'Scanning...';
      case ProvisioningStatus.deviceFound:
        return 'Device Found!';
      case ProvisioningStatus.connected:
        return 'Connected!';
      case ProvisioningStatus.connecting:
        return 'Connecting...';
      case ProvisioningStatus.discoveringServices:
        return 'Discovering Services...';
      case ProvisioningStatus.provisioning:
        return 'Provisioning...';
      case ProvisioningStatus.waitingForResponse:
        return 'Waiting for Response...';
      case ProvisioningStatus.success:
        return 'Success!';
      case ProvisioningStatus.error:
        return 'Error';
      case ProvisioningStatus.disconnecting:
        return 'Disconnecting...';
    }
  }

  Color _getStatusColor() {
    switch (_status) {
      case ProvisioningStatus.idle:
        return Colors.grey;
      case ProvisioningStatus.scanning:
        return const Color(0xFF8B5CF6);
      case ProvisioningStatus.deviceFound:
        return const Color(0xFF22C55E);
      case ProvisioningStatus.connected:
        return const Color(0xFF22C55E);
      case ProvisioningStatus.connecting:
      case ProvisioningStatus.discoveringServices:
      case ProvisioningStatus.provisioning:
      case ProvisioningStatus.waitingForResponse:
        return const Color(0xFFFBBF24);
      case ProvisioningStatus.success:
        return const Color(0xFF22C55E);
      case ProvisioningStatus.error:
        return const Color(0xFFEF4444);
      case ProvisioningStatus.disconnecting:
        return Colors.orange;
    }
  }

  /// Build the counter badge with different styles based on count
  Widget _buildCounterBadge() {
    // Determine colors and effects based on count
    Color backgroundColor;
    Color borderColor;
    Color textColor;
    List<BoxShadow>? boxShadow;
    Gradient? gradient;

    if (_provisionedCount >= 40) {
      // 40-100+: FIRE MODE 🔥 - intense fire gradient with glow
      gradient = const LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [
          Color(0xFFFF4500), // Orange red
          Color(0xFFFF6B00), // Orange
          Color(0xFFFFD700), // Gold
          Color(0xFFFF4500), // Orange red
        ],
      );
      borderColor = const Color(0xFFFFD700);
      textColor = Colors.white;
      boxShadow = [
        BoxShadow(
          color: const Color(0xFFFF4500).withOpacity(0.6),
          blurRadius: 20,
          spreadRadius: 2,
        ),
        BoxShadow(
          color: const Color(0xFFFFD700).withOpacity(0.4),
          blurRadius: 30,
          spreadRadius: 4,
        ),
      ];
      backgroundColor = Colors.transparent;
    } else if (_provisionedCount >= 20) {
      // 20-39: Fiery glow effect - warm orange glow
      gradient = LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [
          const Color(0xFFFF6B35).withOpacity(0.8),
          const Color(0xFFFF4500).withOpacity(0.6),
        ],
      );
      borderColor = const Color(0xFFFF6B35);
      textColor = Colors.white;
      boxShadow = [
        BoxShadow(
          color: const Color(0xFFFF6B35).withOpacity(0.5),
          blurRadius: 12,
          spreadRadius: 1,
        ),
      ];
      backgroundColor = Colors.transparent;
    } else if (_provisionedCount >= 10) {
      // 10-19: Light green
      backgroundColor = const Color(0xFF22C55E).withOpacity(0.25);
      borderColor = const Color(0xFF22C55E).withOpacity(0.6);
      textColor = const Color(0xFF22C55E);
      boxShadow = [
        BoxShadow(
          color: const Color(0xFF22C55E).withOpacity(0.3),
          blurRadius: 8,
          spreadRadius: 0,
        ),
      ];
    } else if (_provisionedCount > 0) {
      // 1-9: Grey/neutral (same as 0)
      backgroundColor = Colors.white.withOpacity(0.1);
      borderColor = Colors.white.withOpacity(0.2);
      textColor = Colors.white;
    } else {
      // 0: Grey/neutral
      backgroundColor = Colors.white.withOpacity(0.1);
      borderColor = Colors.white.withOpacity(0.2);
      textColor = Colors.white;
    }

    return AnimatedContainer(
      duration: const Duration(milliseconds: 300),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      decoration: BoxDecoration(
        color: gradient == null ? backgroundColor : null,
        gradient: gradient,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: borderColor, width: _provisionedCount >= 20 ? 2 : 1),
        boxShadow: boxShadow,
      ),
      child: AnimatedCounter(
        value: _provisionedCount,
        style: TextStyle(
          fontSize: 22,
          fontWeight: FontWeight.bold,
          color: textColor,
          shadows: _provisionedCount >= 40
              ? [
                  const Shadow(
                    color: Colors.black54,
                    blurRadius: 4,
                    offset: Offset(1, 1),
                  ),
                ]
              : null,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isRunning = _isProvisioningRunning;

    return Stack(
      children: [
        Scaffold(
          body: Container(
            decoration: const BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  Color(0xFF1A1A2E),
                  Color(0xFF0F0F1E),
                  Color(0xFF0A0A14),
                ],
              ),
            ),
            child: SafeArea(
              child: Column(
                children: [
                  // App Bar with Provisioning Title & Status
                  Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 12,
                    ),
                    child: Row(
                      children: [
                        SizedBox(
                          width: 48,
                          child: GestureDetector(
                            onTap: () => _openMenuScreen(context),
                            child: Image.asset(
                              'assets/images/nikko.png',
                              height: 32,
                            ),
                          ),
                        ),
                        Expanded(
                          child: Center(
                            child: GestureDetector(
                              onTap: _showDeviceCountDialog,
                              child: _buildCounterBadge(),
                            ),
                          ),
                        ),
                        SizedBox(
                          width: 48,
                          child: IconButton(
                            onPressed: () => _showLogoutConfirmation(context),
                            icon: const Icon(
                              Icons.logout_rounded,
                              color: Colors.white70,
                              size: 24,
                            ),
                            tooltip: 'Logout',
                          ),
                        ),
                      ],
                    ),
                  ),

                  const SizedBox(height: 8),

                  // Bluetooth Devices List
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 20),
                      child: AnimatedContainer(
                        duration: const Duration(milliseconds: 500),
                        curve: Curves.easeInOut,
                        padding: const EdgeInsets.all(16),
                        decoration: BoxDecoration(
                          color: _isProvisioningRunning
                              ? const Color(0xFF2D1E1E) // Dark red
                              : const Color(0xFF1E1E2D), // Purple
                          borderRadius: BorderRadius.circular(16),
                          border: Border.all(
                            color: _isProvisioningRunning
                                ? const Color(0xFFEF4444).withOpacity(0.2)
                                : Colors.white.withOpacity(0.1),
                          ),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                Row(
                                  children: [
                                    Text(
                                      'Nearby Devices',
                                      style: TextStyle(
                                        color: Colors.white.withOpacity(0.9),
                                        fontWeight: FontWeight.w600,
                                        fontSize: 18,
                                      ),
                                    ),
                                    if (_isProvisioningRunning && _isScanning) ...[
                                      const SizedBox(width: 12),
                                      SizedBox(
                                        width: 36,
                                        height: 36,
                                        child: Lottie.asset(
                                          'assets/lottie/provision.json',
                                          fit: BoxFit.contain,
                                        ),
                                      ),
                                    ],
                                  ],
                                ),
                                IconButton(
                                  onPressed: _refreshDeviceScan,
                                  icon: Icon(
                                    Icons.refresh,
                                    color: Colors.white.withOpacity(0.7),
                                    size: 20,
                                  ),
                                  padding: EdgeInsets.zero,
                                  constraints: const BoxConstraints(),
                                ),
                              ],
                            ),
                            const SizedBox(height: 12),
                            Expanded(
                              child: Builder(
                                builder: (context) {
                                  // Filter to only Haven devices with valid (negative) RSSI values
                                  final havenDevices =
                                      _discoveredDevices.entries.where((entry) {
                                        final result = entry.value;
                                        final deviceName =
                                            result
                                                .device
                                                .platformName
                                                .isNotEmpty
                                            ? result.device.platformName
                                            : result.advertisementData.advName;
                                        // Exclude devices with positive dBm (invalid readings)
                                        if (result.rssi >= 0) {
                                          return false;
                                        }
                                        return _provisioningService
                                            .isHavenDevice(deviceName);
                                      }).toList()..sort(
                                        (a, b) => b.value.rssi.compareTo(
                                          a.value.rssi,
                                        ),
                                      );

                                  if (havenDevices.isEmpty) {
                                    return Center(
                                      child: Column(
                                        mainAxisAlignment:
                                            MainAxisAlignment.center,
                                        children: [
                                          Icon(
                                            Icons.bluetooth_searching,
                                            size: 48,
                                            color: Colors.white.withOpacity(
                                              0.2,
                                            ),
                                          ),
                                          const SizedBox(height: 12),
                                          Text(
                                            'Scanning for Haven devices...',
                                            style: TextStyle(
                                              color: Colors.white.withOpacity(
                                                0.3,
                                              ),
                                            ),
                                          ),
                                          const SizedBox(height: 4),
                                          Text(
                                            'Looking for devices starting with HVN or Haven',
                                            style: TextStyle(
                                              color: Colors.white.withOpacity(
                                                0.2,
                                              ),
                                              fontSize: 11,
                                            ),
                                          ),
                                        ],
                                      ),
                                    );
                                  }

                                  return ListView.builder(
                                    itemCount: havenDevices.length,
                                    itemBuilder: (context, index) {
                                      final deviceId = havenDevices[index].key;
                                      final result = havenDevices[index].value;
                                      final deviceName =
                                          result.device.platformName.isNotEmpty
                                          ? result.device.platformName
                                          : result
                                                .advertisementData
                                                .advName
                                                .isNotEmpty
                                          ? result.advertisementData.advName
                                          : 'Unknown Device';
                                      final rssi = result.rssi;
                                      final isConnected =
                                          _connectedDeviceId == deviceId;
                                      final isStrongSignal =
                                          rssi >= _rssiThreshold || isConnected;

                                      return Container(
                                        margin: const EdgeInsets.only(
                                          bottom: 10,
                                        ),
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 16,
                                          vertical: 16,
                                        ),
                                        decoration: BoxDecoration(
                                          color: isStrongSignal
                                              ? const Color(
                                                  0xFF22C55E,
                                                ).withOpacity(0.15)
                                              : const Color(
                                                  0xFF8B5CF6,
                                                ).withOpacity(0.15),
                                          borderRadius: BorderRadius.circular(
                                            8,
                                          ),
                                          border: Border.all(
                                            color: isStrongSignal
                                                ? const Color(
                                                    0xFF22C55E,
                                                  ).withOpacity(0.5)
                                                : const Color(
                                                    0xFF8B5CF6,
                                                  ).withOpacity(0.3),
                                          ),
                                        ),
                                        child: Row(
                                          children: [
                                            Icon(
                                              isConnected
                                                  ? Icons.lightbulb
                                                  : Icons.lightbulb_outline,
                                              color: isStrongSignal
                                                  ? const Color(0xFF22C55E)
                                                  : const Color(0xFF8B5CF6),
                                              size: 18,
                                            ),
                                            const SizedBox(width: 10),
                                            Expanded(
                                              child: Text(
                                                deviceName,
                                                style: const TextStyle(
                                                  color: Colors.white,
                                                  fontSize: 16,
                                                  fontWeight: FontWeight.w600,
                                                ),
                                                overflow: TextOverflow.ellipsis,
                                              ),
                                            ),
                                            _buildRssiIndicator(
                                              rssi,
                                              isConnected: isConnected,
                                            ),
                                          ],
                                        ),
                                      );
                                    },
                                  );
                                },
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),

                  const SizedBox(height: 16),

                  // Start/Stop Button
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 20),
                    child: Column(
                      children: [
                        SizedBox(
                          width: double.infinity,
                          height: 56,
                          child: isRunning
                              ? ElevatedButton.icon(
                                  onPressed: _stopProvisioning,
                                  icon: const Icon(
                                    Icons.stop_rounded,
                                    size: 28,
                                  ),
                                  label: const Text(
                                    'Stop Provisioning',
                                    style: TextStyle(
                                      fontSize: 16,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                  style: ElevatedButton.styleFrom(
                                    backgroundColor: const Color(0xFFEF4444),
                                    foregroundColor: Colors.white,
                                    shape: RoundedRectangleBorder(
                                      borderRadius: BorderRadius.circular(16),
                                    ),
                                    elevation: 0,
                                  ),
                                )
                              : OutlinedButton.icon(
                                  onPressed:
                                      (_locationMode == locationModeCustom &&
                                          _customLocationId.trim().isEmpty)
                                      ? null
                                      : _startProvisioning,
                                  icon: const Icon(
                                    Icons.play_arrow_rounded,
                                    size: 28,
                                  ),
                                  label: const Text(
                                    'Start Provisioning',
                                    style: TextStyle(
                                      fontSize: 16,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                  style: OutlinedButton.styleFrom(
                                    foregroundColor:
                                        (_locationMode == locationModeCustom &&
                                            _customLocationId.trim().isEmpty)
                                        ? Colors.grey.shade600
                                        : const Color(0xFF22C55E),
                                    side: BorderSide(
                                      color:
                                          (_locationMode == locationModeCustom &&
                                              _customLocationId.trim().isEmpty)
                                          ? Colors.grey.shade700
                                          : const Color(0xFF22C55E),
                                      width: 2,
                                    ),
                                    shape: RoundedRectangleBorder(
                                      borderRadius: BorderRadius.circular(16),
                                    ),
                                  ),
                                ),
                        ),
                        if (_locationMode == locationModeCustom &&
                            _customLocationId.trim().isEmpty &&
                            !isRunning)
                          Padding(
                            padding: const EdgeInsets.only(top: 8),
                            child: Row(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Icon(
                                  Icons.warning_amber_rounded,
                                  size: 16,
                                  color: Colors.amber.shade400,
                                ),
                                const SizedBox(width: 6),
                                Text(
                                  'Custom Location ID required - Set in Scan Settings',
                                  style: TextStyle(
                                    color: Colors.amber.shade400,
                                    fontSize: 12,
                                    fontWeight: FontWeight.w500,
                                  ),
                                ),
                              ],
                            ),
                          ),
                      ],
                    ),
                  ),

                  const SizedBox(height: 12),

                  // Scan Settings Button
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 20),
                    child: SizedBox(
                      width: double.infinity,
                      height: 48,
                      child: OutlinedButton.icon(
                        onPressed: isRunning ? null : _showScanSettingsDialog,
                        icon: const Icon(Icons.settings, size: 20),
                        label: const Text(
                          'Scan Settings',
                          style: TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        style: OutlinedButton.styleFrom(
                          foregroundColor: const Color(0xFF8B5CF6),
                          side: BorderSide(
                            color: isRunning
                                ? Colors.grey.shade700
                                : const Color(0xFF8B5CF6),
                          ),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                          disabledForegroundColor: Colors.grey.shade600,
                        ),
                      ),
                    ),
                  ),

                  const SizedBox(height: 20),
                ],
              ),
            ),
          ),
        ),

        // Provisioning Overlay (deviceadding.json)
        if (_showProvisioningOverlay) _buildProvisioningOverlay(),

        // Success Overlay (connected.json)
        if (_showSuccessOverlay) _buildSuccessOverlay(),

        // Close Proximity Countdown Overlay (close.json)
        if (_showCloseProximityOverlay) _buildCloseProximityOverlay(),
      ],
    );
  }

  Widget _buildCloseProximityOverlay() {
    return Container(
      color: const Color(0xFF0A0A14).withOpacity(0.95),
      child: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            SizedBox(
              width: 200,
              height: 200,
              child: Lottie.asset(
                'assets/lottie/close.json',
                fit: BoxFit.contain,
              ),
            ),
            const SizedBox(height: 24),
            Text(
              _proximityDeviceName ?? 'Device',
              style: const TextStyle(
                color: Colors.white,
                fontSize: 18,
                fontWeight: FontWeight.w600,
                decoration: TextDecoration.none,
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 12),
            Text(
              '$_proximityCountdownSeconds',
              style: const TextStyle(
                color: Color(0xFF22C55E),
                fontSize: 48,
                fontWeight: FontWeight.bold,
                decoration: TextDecoration.none,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'Keep device close',
              style: TextStyle(
                color: Colors.white.withOpacity(0.6),
                fontSize: 14,
                fontWeight: FontWeight.normal,
                decoration: TextDecoration.none,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildProvisioningOverlay() {
    return Container(
      color: const Color(0xFF0A0A14).withOpacity(0.95),
      child: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            SizedBox(
              width: 200,
              height: 200,
              child: Lottie.asset(
                'assets/lottie/deviceadding.json',
                fit: BoxFit.contain,
              ),
            ),
            const SizedBox(height: 24),
            const Text(
              'Adding',
              style: TextStyle(
                color: Colors.white,
                fontSize: 24,
                fontWeight: FontWeight.bold,
                decoration: TextDecoration.none,
              ),
            ),
            const SizedBox(height: 16),
            // Device type with last 4 MAC digits (e.g., "X-Series :CB1C")
            if (_currentDeviceInfo != null) ...[
              Text(
                '${_currentDeviceInfo!.deviceType} :${_currentDeviceInfo!.last4Mac}',
                style: const TextStyle(
                  color: Color(0xFF8B5CF6),
                  fontSize: 32,
                  fontWeight: FontWeight.w600,
                  decoration: TextDecoration.none,
                ),
              ),
              const SizedBox(height: 12),
              // Firmware version
              Text(
                'Firmware: ${_currentDeviceInfo!.firmwareVersion}',
                style: TextStyle(
                  color: Colors.white.withOpacity(0.8),
                  fontSize: 22,
                  fontWeight: FontWeight.w600,
                  decoration: TextDecoration.none,
                ),
              ),
            ] else ...[
              // Fallback if no device info yet
              Text(
                'Connecting...',
                style: TextStyle(
                  color: Colors.white.withOpacity(0.6),
                  fontSize: 16,
                  fontWeight: FontWeight.w500,
                  decoration: TextDecoration.none,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildSuccessOverlay() {
    return Container(
      color: const Color(0xFF0A0A14).withOpacity(0.95),
      child: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            SizedBox(
              width: 200,
              height: 200,
              child: Lottie.asset(
                'assets/lottie/connected.json',
                fit: BoxFit.contain,
              ),
            ),
            const SizedBox(height: 24),
            const Text(
              'Added!',
              style: TextStyle(
                color: Color(0xFF22C55E),
                fontSize: 28,
                fontWeight: FontWeight.bold,
                decoration: TextDecoration.none,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildRssiIndicator(int rssi, {bool isConnected = false}) {
    // Show connected indicator
    if (isConnected) {
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.check_circle, color: Color(0xFF22C55E), size: 16),
          const SizedBox(width: 4),
          const Text(
            'CONNECTED',
            style: TextStyle(
              color: Color(0xFF22C55E),
              fontSize: 11,
              fontWeight: FontWeight.bold,
            ),
          ),
        ],
      );
    }

    Color color;
    int bars;

    if (rssi >= _rssiThreshold) {
      color = const Color(0xFF22C55E); // Green - excellent (provisioning range)
      bars = 4;
    } else if (rssi >= -50) {
      color = const Color(0xFF22C55E); // Green - good
      bars = 3;
    } else if (rssi >= -70) {
      color = const Color(0xFFFBBF24); // Yellow - fair
      bars = 2;
    } else {
      color = const Color(0xFFEF4444); // Red - weak
      bars = 1;
    }

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          '$rssi dBm',
          style: TextStyle(
            color: color,
            fontSize: 11,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(width: 6),
        Row(
          children: List.generate(4, (index) {
            return Container(
              width: 3,
              height: 6 + (index * 3).toDouble(),
              margin: const EdgeInsets.only(left: 2),
              decoration: BoxDecoration(
                color: index < bars ? color : Colors.grey.shade700,
                borderRadius: BorderRadius.circular(1),
              ),
            );
          }),
        ),
      ],
    );
  }
}

/// Animated counter widget with flip/slide animation like a digital clock
class AnimatedCounter extends StatelessWidget {
  final int value;
  final TextStyle? style;
  final Duration duration;

  const AnimatedCounter({
    super.key,
    required this.value,
    this.style,
    this.duration = const Duration(milliseconds: 300),
  });

  @override
  Widget build(BuildContext context) {
    // Pass value directly to _AnimatedDigits which handles its own animation
    return _AnimatedDigits(
      value: value,
      style: style,
      duration: duration,
    );
  }
}

class _AnimatedDigits extends StatefulWidget {
  final int value;
  final TextStyle? style;
  final Duration duration;

  const _AnimatedDigits({
    required this.value,
    this.style,
    required this.duration,
  });

  @override
  State<_AnimatedDigits> createState() => _AnimatedDigitsState();
}

class _AnimatedDigitsState extends State<_AnimatedDigits> {
  int _previousValue = 0;

  @override
  void initState() {
    super.initState();
    _previousValue = widget.value;
  }

  @override
  void didUpdateWidget(_AnimatedDigits oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.value != widget.value) {
      _previousValue = oldWidget.value;
    }
  }

  @override
  Widget build(BuildContext context) {
    final digits = widget.value.toString().split('');
    final prevDigits = _previousValue.toString().split('');
    
    // Pad the shorter one with empty strings on the left
    while (prevDigits.length < digits.length) {
      prevDigits.insert(0, '');
    }
    while (digits.length < prevDigits.length) {
      digits.insert(0, '');
    }

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: List.generate(digits.length, (index) {
        final currentDigit = digits[index];
        final prevDigit = prevDigits[index];
        final hasChanged = currentDigit != prevDigit;

        return _SingleDigitAnimation(
          digit: currentDigit,
          previousDigit: prevDigit,
          animate: hasChanged,
          style: widget.style,
          duration: widget.duration,
        );
      }),
    );
  }
}

class _SingleDigitAnimation extends StatefulWidget {
  final String digit;
  final String previousDigit;
  final bool animate;
  final TextStyle? style;
  final Duration duration;

  const _SingleDigitAnimation({
    required this.digit,
    required this.previousDigit,
    required this.animate,
    this.style,
    required this.duration,
  });

  @override
  State<_SingleDigitAnimation> createState() => _SingleDigitAnimationState();
}

class _SingleDigitAnimationState extends State<_SingleDigitAnimation>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<Offset> _slideOutAnimation;
  late Animation<Offset> _slideInAnimation;
  late Animation<double> _fadeOutAnimation;
  late Animation<double> _fadeInAnimation;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: widget.duration,
    );

    _slideOutAnimation = Tween<Offset>(
      begin: Offset.zero,
      end: const Offset(0, -1),
    ).animate(CurvedAnimation(
      parent: _controller,
      curve: Curves.easeInOut,
    ));

    _slideInAnimation = Tween<Offset>(
      begin: const Offset(0, 1),
      end: Offset.zero,
    ).animate(CurvedAnimation(
      parent: _controller,
      curve: Curves.easeInOut,
    ));

    _fadeOutAnimation = Tween<double>(
      begin: 1.0,
      end: 0.0,
    ).animate(CurvedAnimation(
      parent: _controller,
      curve: const Interval(0.0, 0.5, curve: Curves.easeIn),
    ));

    _fadeInAnimation = Tween<double>(
      begin: 0.0,
      end: 1.0,
    ).animate(CurvedAnimation(
      parent: _controller,
      curve: const Interval(0.5, 1.0, curve: Curves.easeOut),
    ));

    if (widget.animate) {
      _controller.forward();
    }
  }

  @override
  void didUpdateWidget(_SingleDigitAnimation oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.animate && widget.digit != oldWidget.digit) {
      _controller.reset();
      _controller.forward();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.animate || widget.digit == widget.previousDigit) {
      return Text(widget.digit, style: widget.style);
    }

    return ClipRect(
      child: Stack(
        children: [
          // Outgoing digit (slides up and fades out)
          SlideTransition(
            position: _slideOutAnimation,
            child: FadeTransition(
              opacity: _fadeOutAnimation,
              child: Text(widget.previousDigit, style: widget.style),
            ),
          ),
          // Incoming digit (slides up from below and fades in)
          SlideTransition(
            position: _slideInAnimation,
            child: FadeTransition(
              opacity: _fadeInAnimation,
              child: Text(widget.digit, style: widget.style),
            ),
          ),
        ],
      ),
    );
  }
}
