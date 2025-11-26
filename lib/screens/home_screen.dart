import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:permission_handler/permission_handler.dart';
import '../services/auth_state.dart';
import '../services/provisioning_service.dart';
import 'sign_in_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final _provisioningService = ProvisioningService();
  
  ProvisioningStatus _status = ProvisioningStatus.idle;
  final List<String> _logMessages = [];
  final List<ProvisioningResult> _results = [];
  final ScrollController _logScrollController = ScrollController();
  
  // Scan settings
  String _wifiSsid = defaultWifiSsid;
  String _wifiPassword = defaultWifiPassword;
  String _locationId = ''; // Required - no default
  
  // Bluetooth device list
  final Map<String, ScanResult> _discoveredDevices = {};
  StreamSubscription<List<ScanResult>>? _scanSubscription;
  Timer? _scanRefreshTimer;
  bool _isScanning = false;
  String? _connectedDeviceId;
  bool _isProvisioningRunning = false;
  
  StreamSubscription<ProvisioningStatus>? _statusSubscription;
  StreamSubscription<String>? _messageSubscription;
  StreamSubscription<ProvisioningResult>? _resultsSubscription;

  @override
  void initState() {
    super.initState();
    _setupListeners();
    _startDeviceScan();
  }

  @override
  void dispose() {
    _stopDeviceScan();
    _statusSubscription?.cancel();
    _messageSubscription?.cancel();
    _resultsSubscription?.cancel();
    _logScrollController.dispose();
    super.dispose();
  }

  void _startDeviceScan() async {
    final hasPermissions = await _checkPermissions();
    if (!hasPermissions) return;

    setState(() {
      _isScanning = true;
      _discoveredDevices.clear();
    });

    await FlutterBluePlus.startScan();

    _scanSubscription = FlutterBluePlus.scanResults.listen((results) {
      if (mounted) {
        setState(() {
          for (final result in results) {
            final deviceId = result.device.remoteId.toString();
            // Update device if it's new or has a newer RSSI reading
            _discoveredDevices[deviceId] = result;
          }
        });
        
        // Check if we should auto-provision a device
        _checkForAutoProvisioning();
      }
    });

    // Auto-refresh scan every second
    _scanRefreshTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted && _isScanning) {
        FlutterBluePlus.startScan();
      }
    });
  }

  void _stopDeviceScan() {
    _scanRefreshTimer?.cancel();
    _scanRefreshTimer = null;
    _scanSubscription?.cancel();
    _scanSubscription = null;
    FlutterBluePlus.stopScan();
    setState(() {
      _isScanning = false;
    });
  }

  void _refreshDeviceScan() {
    _stopDeviceScan();
    _startDeviceScan();
  }

  /// Check if any Haven device has strong signal and should be auto-provisioned
  void _checkForAutoProvisioning() {
    // Only check if provisioning mode is ON and we're not already provisioning
    if (!_isProvisioningRunning || _provisioningService.isRunning) {
      return;
    }

    // Find the first Haven device with strong signal (>= -25 dBm)
    for (final entry in _discoveredDevices.entries) {
      final result = entry.value;
      final deviceName = result.device.platformName.isNotEmpty 
          ? result.device.platformName 
          : result.advertisementData.advName;
      
      // Check if it's a Haven device with strong signal
      if (_provisioningService.isHavenDevice(deviceName) && result.rssi >= -25) {
        // Mark this device as being connected
        setState(() {
          _connectedDeviceId = entry.key;
        });
        
        // Get the bearer token
        final authState = AuthState();
        final bearerToken = authState.token;
        
        if (bearerToken == null || bearerToken.isEmpty) {
          return;
        }

        // Trigger provisioning for this device
        _provisioningService.provisionDevice(
          scanResult: result,
          bearerToken: bearerToken,
          ssid: _wifiSsid,
          wifiPassword: _wifiPassword,
          locationId: _locationId,
        );
        
        // Stop scanning while provisioning
        _stopDeviceScan();
        break;
      }
    }
  }

  void _setupListeners() {
    _statusSubscription = _provisioningService.statusStream.listen((status) {
      if (mounted) {
        setState(() {
          _status = status;
          
          // Stop scanning when we start connecting to a device
          if (status == ProvisioningStatus.connecting ||
              status == ProvisioningStatus.discoveringServices ||
              status == ProvisioningStatus.provisioning ||
              status == ProvisioningStatus.waitingForResponse) {
            _stopDeviceScan();
          }
          
          // Clear connected device and resume scanning when idle
          if (status == ProvisioningStatus.idle) {
            _connectedDeviceId = null;
            // Resume scanning if provisioning mode is still ON
            if (_isProvisioningRunning && !_isScanning) {
              _startDeviceScan();
            }
          }
          
          // Clear connected device on success/error (but keep scanning paused briefly)
          if (status == ProvisioningStatus.success || status == ProvisioningStatus.error) {
            _connectedDeviceId = null;
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
  }

  String _formatTime(DateTime time) {
    return '${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')}:${time.second.toString().padLeft(2, '0')}';
  }

  Future<bool> _checkPermissions() async {
    if (Platform.isIOS) {
      try {
        final adapterState = await FlutterBluePlus.adapterState.first;
        if (adapterState == BluetoothAdapterState.unauthorized) {
          if (mounted) {
            _showPermissionDialog('Please enable Bluetooth permission for this app in Settings.');
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
        return true;
      }
    } else {
      final bluetoothScanStatus = await Permission.bluetoothScan.status;
      final bluetoothConnectStatus = await Permission.bluetoothConnect.status;

      bool allGranted = (bluetoothScanStatus.isGranted || bluetoothScanStatus.isLimited) &&
          (bluetoothConnectStatus.isGranted || bluetoothConnectStatus.isLimited);

      if (allGranted) {
        return true;
      }

      List<Permission> permissionsToRequest = [];
      
      if (!bluetoothScanStatus.isGranted && !bluetoothScanStatus.isLimited) {
        permissionsToRequest.add(Permission.bluetoothScan);
      }
      if (!bluetoothConnectStatus.isGranted && !bluetoothConnectStatus.isLimited) {
        permissionsToRequest.add(Permission.bluetoothConnect);
      }

      if (permissionsToRequest.isNotEmpty) {
        await permissionsToRequest.request();
        
        final newBluetoothScanStatus = await Permission.bluetoothScan.status;
        final newBluetoothConnectStatus = await Permission.bluetoothConnect.status;

        allGranted = (newBluetoothScanStatus.isGranted || newBluetoothScanStatus.isLimited) &&
            (newBluetoothConnectStatus.isGranted || newBluetoothConnectStatus.isLimited);
      }

      if (!allGranted) {
        if (mounted) {
          _showPermissionDialog('Bluetooth permission is required to scan for Haven devices.');
        }
        return false;
      }
      return true;
    }
  }

  Future<void> _startProvisioning() async {
    // Check if location ID is provided
    if (_locationId.trim().isEmpty) {
      _showErrorDialog('Location ID is required. Please go to Scan Settings and enter a Location ID.');
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
    
    // Start/resume scanning - provisioning will auto-trigger when strong device found
    if (!_isScanning) {
      _startDeviceScan();
    }
    
    // Immediately check if there's already a device with strong signal
    _checkForAutoProvisioning();
  }

  void _stopProvisioning() {
    _provisioningService.stopProvisioningLoop();
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
    final locationIdController = TextEditingController(text: _locationId);
    bool obscurePassword = true;

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
                    prefixIcon: Icon(Icons.lock_outline, color: Colors.grey.shade400),
                    suffixIcon: IconButton(
                      icon: Icon(
                        obscurePassword ? Icons.visibility_outlined : Icons.visibility_off_outlined,
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
                
                // Location ID
                TextField(
                  controller: locationIdController,
                  style: const TextStyle(color: Colors.white),
                  decoration: InputDecoration(
                    labelText: 'Location ID *',
                    labelStyle: TextStyle(color: Colors.grey.shade400),
                    hintText: 'Enter location ID (required)',
                    hintStyle: TextStyle(color: Colors.grey.shade600),
                    prefixIcon: Icon(Icons.location_on_outlined, color: Colors.grey.shade400),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: BorderSide.none,
                    ),
                    filled: true,
                    fillColor: const Color(0xFF2A2A3C),
                  ),
                ),
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
                  _locationId = locationIdController.text;
                });
                Navigator.of(context).pop();
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: const Text('Settings saved'),
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
                padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
              ),
              child: const Text(
                'Save',
                style: TextStyle(color: Colors.white, fontWeight: FontWeight.w600),
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
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20),
        ),
        title: const Row(
          children: [
            Icon(Icons.bluetooth_disabled, color: Color(0xFFEF4444), size: 28),
            SizedBox(width: 12),
            Expanded(
              child: Text(
                'Permission Required',
                style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold),
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
            child: Text('Cancel', style: TextStyle(color: Colors.white.withOpacity(0.7))),
          ),
          TextButton(
            onPressed: () {
              Navigator.of(context).pop();
              openAppSettings();
            },
            style: TextButton.styleFrom(
              backgroundColor: const Color(0xFF8B5CF6),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            ),
            child: const Text('Settings', style: TextStyle(color: Colors.white)),
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
            Text('Bluetooth Off', style: TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.bold)),
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
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
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
            Text('Error', style: TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.bold)),
          ],
        ),
        content: Text(message, style: TextStyle(color: Colors.white.withOpacity(0.8), fontSize: 16)),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            style: TextButton.styleFrom(
              backgroundColor: const Color(0xFF8B5CF6),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            ),
            child: const Text('OK', style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );
  }

  void _logout(BuildContext context) {
    _provisioningService.stopProvisioningLoop();
    AuthState().logout();
    Navigator.of(context).pushAndRemoveUntil(
      MaterialPageRoute(builder: (context) => const SignInScreen()),
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
            Text('Log Out', style: TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.bold)),
          ],
        ),
        content: Text(
          'Are you sure you want to log out?',
          style: TextStyle(color: Colors.white.withOpacity(0.8), fontSize: 16),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: Text('Cancel', style: TextStyle(color: Colors.white.withOpacity(0.7))),
          ),
          TextButton(
            onPressed: () {
              Navigator.of(context).pop();
              _logout(context);
            },
            style: TextButton.styleFrom(
              backgroundColor: const Color(0xFFEF4444),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
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

  @override
  Widget build(BuildContext context) {
    final isRunning = _isProvisioningRunning;
    
    return Scaffold(
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Color(0xFF1A1A2E), Color(0xFF0F0F1E), Color(0xFF0A0A14)],
          ),
        ),
        child: SafeArea(
          child: Column(
            children: [
              // App Bar
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Image.asset('assets/logos/havenlogo.png', height: 32),
                    IconButton(
                      onPressed: () => _showLogoutConfirmation(context),
                      icon: const Icon(Icons.logout_rounded, color: Colors.white70, size: 24),
                      tooltip: 'Logout',
                    ),
                  ],
                ),
              ),

              // Title & Status
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Text(
                      'Provisioning',
                      style: TextStyle(fontSize: 28, fontWeight: FontWeight.bold, color: Colors.white),
                    ),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                      decoration: BoxDecoration(
                        color: _getStatusColor().withOpacity(0.2),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: _getStatusColor().withOpacity(0.5)),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (_status == ProvisioningStatus.scanning)
                            SizedBox(
                              width: 12,
                              height: 12,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: _getStatusColor(),
                              ),
                            )
                          else
                            Container(
                              width: 8,
                              height: 8,
                              decoration: BoxDecoration(
                                color: _getStatusColor(),
                                shape: BoxShape.circle,
                              ),
                            ),
                          const SizedBox(width: 8),
                          Text(
                            _getStatusText(),
                            style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                              color: _getStatusColor(),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),

              const SizedBox(height: 8),

              // Start/Stop Button
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                child: Column(
                  children: [
                    SizedBox(
                      width: double.infinity,
                      height: 56,
                      child: ElevatedButton.icon(
                        onPressed: isRunning 
                            ? _stopProvisioning 
                            : (_locationId.trim().isEmpty ? null : _startProvisioning),
                        icon: Icon(
                          isRunning ? Icons.stop_rounded : Icons.play_arrow_rounded,
                          size: 28,
                        ),
                        label: Text(
                          isRunning ? 'Stop Provisioning' : 'Start Provisioning',
                          style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
                        ),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: isRunning 
                              ? const Color(0xFFEF4444) 
                              : (_locationId.trim().isEmpty 
                                  ? Colors.grey.shade700 
                                  : const Color(0xFF22C55E)),
                          foregroundColor: Colors.white,
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                          elevation: 0,
                        ),
                      ),
                    ),
                    if (_locationId.trim().isEmpty && !isRunning)
                      Padding(
                        padding: const EdgeInsets.only(top: 8),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Icon(Icons.warning_amber_rounded, size: 16, color: Colors.amber.shade400),
                            const SizedBox(width: 6),
                            Text(
                              'Location ID required - Set in Scan Settings',
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
                      style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
                    ),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: const Color(0xFF8B5CF6),
                      side: BorderSide(
                        color: isRunning ? Colors.grey.shade700 : const Color(0xFF8B5CF6),
                      ),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                      disabledForegroundColor: Colors.grey.shade600,
                    ),
                  ),
                ),
              ),

              const SizedBox(height: 16),

              // Bluetooth Devices List
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 20),
                  child: Container(
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: const Color(0xFF1E1E2D),
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(color: Colors.white.withOpacity(0.1)),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Row(
                              children: [
                                Icon(
                                  Icons.bluetooth_searching,
                                  color: _isScanning ? const Color(0xFF8B5CF6) : Colors.white.withOpacity(0.7),
                                  size: 18,
                                ),
                                const SizedBox(width: 8),
                                Text(
                                  'Nearby Devices',
                                  style: TextStyle(
                                    color: Colors.white.withOpacity(0.9),
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                                if (_isScanning) ...[
                                  const SizedBox(width: 8),
                                  SizedBox(
                                    width: 12,
                                    height: 12,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                      color: const Color(0xFF8B5CF6),
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
                              // Filter to only Haven devices
                              final havenDevices = _discoveredDevices.entries
                                  .where((entry) {
                                    final result = entry.value;
                                    final deviceName = result.device.platformName.isNotEmpty 
                                        ? result.device.platformName 
                                        : result.advertisementData.advName;
                                    return _provisioningService.isHavenDevice(deviceName);
                                  })
                                  .toList()
                                ..sort((a, b) => b.value.rssi.compareTo(a.value.rssi));
                              
                              if (havenDevices.isEmpty) {
                                return Center(
                                  child: Column(
                                    mainAxisAlignment: MainAxisAlignment.center,
                                    children: [
                                      Icon(
                                        Icons.bluetooth_searching,
                                        size: 48,
                                        color: Colors.white.withOpacity(0.2),
                                      ),
                                      const SizedBox(height: 12),
                                      Text(
                                        'Scanning for Haven devices...',
                                        style: TextStyle(color: Colors.white.withOpacity(0.3)),
                                      ),
                                      const SizedBox(height: 4),
                                      Text(
                                        'Looking for devices starting with HVN or Haven',
                                        style: TextStyle(
                                          color: Colors.white.withOpacity(0.2),
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
                                  final deviceName = result.device.platformName.isNotEmpty 
                                      ? result.device.platformName 
                                      : result.advertisementData.advName.isNotEmpty
                                          ? result.advertisementData.advName
                                          : 'Unknown Device';
                                  final rssi = result.rssi;
                                  final isConnected = _connectedDeviceId == deviceId;
                                  final isStrongSignal = rssi >= -25 || isConnected;
                                  
                                  return Container(
                                    margin: const EdgeInsets.only(bottom: 8),
                                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                                    decoration: BoxDecoration(
                                      color: isStrongSignal 
                                          ? const Color(0xFF22C55E).withOpacity(0.15)
                                          : const Color(0xFF8B5CF6).withOpacity(0.15),
                                      borderRadius: BorderRadius.circular(8),
                                      border: Border.all(
                                        color: isStrongSignal 
                                            ? const Color(0xFF22C55E).withOpacity(0.5)
                                            : const Color(0xFF8B5CF6).withOpacity(0.3),
                                      ),
                                    ),
                                    child: Row(
                                      children: [
                                        Icon(
                                          isConnected ? Icons.lightbulb : Icons.lightbulb_outline,
                                          color: isStrongSignal ? const Color(0xFF22C55E) : const Color(0xFF8B5CF6),
                                          size: 18,
                                        ),
                                        const SizedBox(width: 10),
                                        Expanded(
                                          child: Column(
                                            crossAxisAlignment: CrossAxisAlignment.start,
                                            children: [
                                              Text(
                                                deviceName,
                                                style: const TextStyle(
                                                  color: Colors.white,
                                                  fontSize: 13,
                                                  fontWeight: FontWeight.w600,
                                                ),
                                                overflow: TextOverflow.ellipsis,
                                              ),
                                              Text(
                                                result.device.remoteId.toString(),
                                                style: TextStyle(
                                                  color: Colors.white.withOpacity(0.5),
                                                  fontSize: 10,
                                                ),
                                              ),
                                            ],
                                          ),
                                        ),
                                        _buildRssiIndicator(rssi, isConnected: isConnected),
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

              const SizedBox(height: 20),
            ],
          ),
        ),
      ),
      floatingActionButtonLocation: FloatingActionButtonLocation.startFloat,
      floatingActionButton: FloatingActionButton(
        mini: true,
        heroTag: 'activity_log_fab',
        backgroundColor: const Color(0xFF8B5CF6),
        onPressed: _showActivityLog,
        child: Badge(
          isLabelVisible: _logMessages.isNotEmpty,
          label: Text(_logMessages.length.toString()),
          child: const Icon(Icons.article_outlined, color: Colors.white, size: 20),
        ),
      ),
    );
  }

  void _showActivityLog() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) => Container(
        height: MediaQuery.of(context).size.height * 0.7,
        decoration: const BoxDecoration(
          color: Color(0xFF1E1E2D),
          borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
        ),
        child: Column(
          children: [
            // Handle bar
            Container(
              margin: const EdgeInsets.only(top: 12),
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: Colors.white.withOpacity(0.3),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            // Header
            Padding(
              padding: const EdgeInsets.all(16),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    'Activity Log',
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                      color: Colors.white.withOpacity(0.9),
                    ),
                  ),
                  Row(
                    children: [
                      if (_logMessages.isNotEmpty)
                        TextButton(
                          onPressed: () {
                            setState(() => _logMessages.clear());
                            Navigator.pop(context);
                          },
                          child: const Text('Clear', style: TextStyle(color: Color(0xFF8B5CF6))),
                        ),
                      IconButton(
                        onPressed: () => Navigator.pop(context),
                        icon: Icon(Icons.close, color: Colors.white.withOpacity(0.7)),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            // Log content
            Expanded(
              child: Container(
                margin: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: const Color(0xFF0A0A14),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: Colors.white.withOpacity(0.1)),
                ),
                child: _logMessages.isEmpty
                    ? Center(
                        child: Text(
                          'Press Start to begin provisioning...',
                          style: TextStyle(color: Colors.white.withOpacity(0.3)),
                        ),
                      )
                    : ListView.builder(
                        controller: _logScrollController,
                        itemCount: _logMessages.length,
                        itemBuilder: (context, index) {
                          final msg = _logMessages[index];
                          Color textColor = Colors.white.withOpacity(0.7);
                          if (msg.contains('✓')) {
                            textColor = const Color(0xFF22C55E);
                          } else if (msg.contains('Error') || msg.contains('Failed')) {
                            textColor = const Color(0xFFEF4444);
                          } else if (msg.contains('Found device')) {
                            textColor = const Color(0xFFFBBF24);
                          }
                          return Padding(
                            padding: const EdgeInsets.symmetric(vertical: 2),
                            child: Text(
                              msg,
                              style: TextStyle(
                                fontFamily: 'monospace',
                                fontSize: 11,
                                color: textColor,
                              ),
                            ),
                          );
                        },
                      ),
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
          const Icon(
            Icons.check_circle,
            color: Color(0xFF22C55E),
            size: 16,
          ),
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
    
    if (rssi >= -25) {
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
