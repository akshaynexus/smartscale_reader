import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:permission_handler/permission_handler.dart';

/// BLE connection states
enum BleConnectionState {
  disconnected,
  scanning,
  connecting,
  connected,
  disconnecting,
  error,
}

/// BLE connection errors
enum BleError {
  permissionDenied,
  bluetoothDisabled,
  deviceNotFound,
  connectionFailed,
  connectionTimeout,
  serviceNotFound,
  characteristicNotFound,
  writeError,
  readError,
  unknown,
}

/// Bluetooth Low Energy Manager for Mi Scale 2
/// 
/// Handles all BLE operations including:
/// - Device scanning and discovery
/// - Connection management
/// - Service and characteristic discovery
/// - Read/write operations
/// - Error handling and retries
class BleManager {
  static const String _miScale2DeviceName = "MI_SCALE";
  static const Duration _scanTimeout = Duration(seconds: 10);
  static const Duration _connectionTimeout = Duration(seconds: 15);
  static const Duration _operationTimeout = Duration(seconds: 5);
  static const int _maxRetries = 3;

  BluetoothDevice? _connectedDevice;
  BluetoothCharacteristic? _weightMeasurementCharacteristic;
  BluetoothCharacteristic? _weightCustomConfigCharacteristic;
  BluetoothCharacteristic? _currentTimeCharacteristic;
  
  final StreamController<BleConnectionState> _stateController = 
      StreamController<BleConnectionState>.broadcast();
  final StreamController<BleError> _errorController = 
      StreamController<BleError>.broadcast();
  final StreamController<Uint8List> _dataController = 
      StreamController<Uint8List>.broadcast();
  final StreamController<void> _writeSuccessController = 
      StreamController<void>.broadcast();
  final StreamController<void> _notificationSuccessController = 
      StreamController<void>.broadcast();
  final StreamController<void> _servicesDiscoveredController = 
      StreamController<void>.broadcast();

  BleConnectionState _currentState = BleConnectionState.disconnected;
  StreamSubscription<BluetoothConnectionState>? _connectionSubscription;
  StreamSubscription<List<int>>? _notificationSubscription;
  Timer? _connectionTimer;
  Timer? _scanTimer;

  /// Stream of connection state changes
  Stream<BleConnectionState> get stateStream => _stateController.stream;
  
  /// Stream of BLE errors
  Stream<BleError> get errorStream => _errorController.stream;
  
  /// Stream of measurement data from Mi Scale 2
  Stream<Uint8List> get dataStream => _dataController.stream;
  
  /// Stream of write success events
  Stream<void> get writeSuccessStream => _writeSuccessController.stream;
  
  /// Stream of notification setup success events
  Stream<void> get notificationSuccessStream => _notificationSuccessController.stream;
  
  /// Stream of services discovered events
  Stream<void> get servicesDiscoveredStream => _servicesDiscoveredController.stream;
  
  /// Current connection state
  BleConnectionState get currentState => _currentState;
  
  /// Whether device is connected
  bool get isConnected => _currentState == BleConnectionState.connected;

  /// Initialize BLE manager and request permissions
  Future<bool> initialize() async {
    try {
      debugPrint('Initializing BLE manager...');
      
      // Check if Bluetooth is supported
      if (await FlutterBluePlus.isSupported == false) {
        debugPrint('Bluetooth not supported on this device');
        _emitError(BleError.bluetoothDisabled);
        return false;
      }

      // Request permissions
      debugPrint('Requesting permissions...');
      if (!await _requestPermissions()) {
        debugPrint('Permissions denied');
        _emitError(BleError.permissionDenied);
        return false;
      }

      // Check if Bluetooth is enabled
      debugPrint('Checking Bluetooth adapter state...');
      final adapterState = await FlutterBluePlus.adapterState.first;
      debugPrint('Adapter state: $adapterState');
      
      if (adapterState != BluetoothAdapterState.on) {
        debugPrint('Bluetooth is not enabled');
        _emitError(BleError.bluetoothDisabled);
        return false;
      }

      debugPrint('BLE manager initialized successfully');
      return true;
    } catch (e) {
      debugPrint('BLE initialization error: $e');
      _emitError(BleError.unknown);
      return false;
    }
  }

  /// Scan for Mi Scale 2 devices
  Future<List<BluetoothDevice>> scanForDevices() async {
    if (_currentState == BleConnectionState.scanning) {
      return [];
    }

    // Clean up any existing connections first
    await _cleanupConnections();
    
    _setState(BleConnectionState.scanning);
    
    final foundDevices = <BluetoothDevice>[];

    try {
      debugPrint('Starting BLE scan for Mi Scale 2 devices...');
      
      // Start scanning with filter
      await FlutterBluePlus.startScan(
        timeout: _scanTimeout,
        androidUsesFineLocation: true,
      );

      // Listen for scan results during the scan
      final scanSubscription = FlutterBluePlus.scanResults.listen((results) {
        for (final result in results) {
          final device = result.device;
          final name = device.platformName;
          
          debugPrint('Found device: $name (${device.remoteId})');
          
          // Look for Mi Scale devices - prioritize MiScale2 naming (MIBCS/MIBFS)
          if (name.isNotEmpty) {
            debugPrint('Checking device: "$name"');
            if (name.contains('MIBCS') || name.contains('MIBFS') || 
                name.contains('MI SCALE') || name.contains('SCALE')) {
              if (!foundDevices.any((d) => d.remoteId == device.remoteId)) {
                foundDevices.add(device);
                debugPrint('✓ ADDED Mi Scale device: ${device.remoteId} - "$name"');
              }
            }
          }
        }
      });

      // Wait for scan to complete
      await FlutterBluePlus.isScanning.where((scanning) => scanning == false).first;
      
      await scanSubscription.cancel();
      
      debugPrint('Scan completed. Found ${foundDevices.length} potential devices');
      
      _setState(BleConnectionState.disconnected);
      return foundDevices;
      
    } catch (e) {
      debugPrint('Scan error: $e');
      _emitError(BleError.unknown);
      _setState(BleConnectionState.disconnected);
      return [];
    }
  }

  /// Connect to a Mi Scale 2 device
  Future<bool> connectToDevice(BluetoothDevice device) async {
    debugPrint('Attempting to connect to: ${device.platformName}');
    
    _setState(BleConnectionState.connecting);
    
    // Listen to connection state changes
    _connectionSubscription = device.connectionState.listen((state) async {
      debugPrint('BleManager: Connection state changed: $state');
      if (state == BluetoothConnectionState.connected) {
        _onDeviceConnected(device);
        // Trigger service discovery immediately but don't block the connection callback
        _triggerServiceDiscovery(device);
      } else if (state == BluetoothConnectionState.disconnected) {
        _onDeviceDisconnected();
      }
    });
    
    try {
      // Simple direct connection
      await device.connect();
      debugPrint('Connection initiated successfully');
      
      // Force trigger connected logic if state listener doesn't work
      await Future.delayed(const Duration(milliseconds: 500));
      if (device.isConnected) {
        debugPrint('BleManager: Device is connected, forcing connected logic');
        _onDeviceConnected(device);
        _triggerServiceDiscovery(device);
      }
      
      return true;
      
    } catch (e) {
      debugPrint('Connection failed: $e');
      _emitError(BleError.connectionFailed);
      _setState(BleConnectionState.error);
      return false;
    }
  }

  /// Disconnect from current device
  Future<void> disconnect() async {
    if (_currentState == BleConnectionState.disconnected) {
      return;
    }

    _setState(BleConnectionState.disconnecting);
    
    try {
      // Cancel subscriptions
      await _notificationSubscription?.cancel();
      await _connectionSubscription?.cancel();
      
      // Cancel timers
      _connectionTimer?.cancel();
      _scanTimer?.cancel();
      
      // Disconnect device
      if (_connectedDevice != null) {
        await _connectedDevice!.disconnect();
      }
      
      _onDeviceDisconnected();
      
    } catch (e) {
      debugPrint('Disconnect error: $e');
      _onDeviceDisconnected();
    }
  }

  /// Write data to a characteristic
  Future<bool> writeCharacteristic(String serviceUuid, String characteristicUuid, 
                                 Uint8List data) async {
    if (!isConnected || _connectedDevice == null) {
      _emitError(BleError.connectionFailed);
      return false;
    }

    try {
      final services = await _connectedDevice!.discoverServices();
      
      for (final service in services) {
        debugPrint('BleManager: Checking service ${service.uuid} against $serviceUuid');
        if (_uuidMatches(service.uuid.toString(), serviceUuid)) {
          for (final characteristic in service.characteristics) {
            debugPrint('BleManager:   Checking characteristic ${characteristic.uuid} against $characteristicUuid');
            if (_uuidMatches(characteristic.uuid.toString(), characteristicUuid)) {
              
              debugPrint('Writing to ${characteristicUuid}: ${data.map((b) => b.toRadixString(16).padLeft(2, '0')).join(' ')}');
              await characteristic.write(data, withoutResponse: false);
              debugPrint('Write completed successfully to ${characteristicUuid}');
              // Notify write success
              _writeSuccessController.add(null);
              return true;
            }
          }
        }
      }
      
      _emitError(BleError.characteristicNotFound);
      return false;
      
    } catch (e) {
      debugPrint('Write error: $e');
      _emitError(BleError.writeError);
      return false;
    }
  }

  /// Read data from a characteristic
  Future<Uint8List?> readCharacteristic(String serviceUuid, String characteristicUuid) async {
    if (!isConnected || _connectedDevice == null) {
      _emitError(BleError.connectionFailed);
      return null;
    }

    try {
      final services = await _connectedDevice!.discoverServices();
      
      for (final service in services) {
        debugPrint('BleManager: Checking service ${service.uuid} against $serviceUuid');
        if (_uuidMatches(service.uuid.toString(), serviceUuid)) {
          for (final characteristic in service.characteristics) {
            debugPrint('BleManager:   Checking characteristic ${characteristic.uuid} against $characteristicUuid');
            if (_uuidMatches(characteristic.uuid.toString(), characteristicUuid)) {
              
              final data = await characteristic.read();
              return Uint8List.fromList(data);
            }
          }
        }
      }
      
      _emitError(BleError.characteristicNotFound);
      return null;
      
    } catch (e) {
      debugPrint('Read error: $e');
      _emitError(BleError.readError);
      return null;
    }
  }

  /// Enable notifications for a characteristic
  Future<bool> enableNotifications(String serviceUuid, String characteristicUuid) async {
    if (!isConnected || _connectedDevice == null) {
      _emitError(BleError.connectionFailed);
      return false;
    }

    try {
      final services = await _connectedDevice!.discoverServices();
      
      for (final service in services) {
        debugPrint('BleManager: Checking service ${service.uuid} against $serviceUuid');
        if (_uuidMatches(service.uuid.toString(), serviceUuid)) {
          for (final characteristic in service.characteristics) {
            debugPrint('BleManager:   Checking characteristic ${characteristic.uuid} against $characteristicUuid');
            if (_uuidMatches(characteristic.uuid.toString(), characteristicUuid)) {
              
              // Enable notifications
              await characteristic.setNotifyValue(true);
              
              // Listen for notifications
              _notificationSubscription = characteristic.lastValueStream.listen((data) {
                if (data.isNotEmpty) {
                  _dataController.add(Uint8List.fromList(data));
                }
              });
              
              debugPrint('Enabled notifications for $characteristicUuid');
              // Notify notification setup success
              _notificationSuccessController.add(null);
              return true;
            }
          }
        }
      }
      
      _emitError(BleError.characteristicNotFound);
      return false;
      
    } catch (e) {
      debugPrint('Notification setup error: $e');
      _emitError(BleError.unknown);
      return false;
    }
  }

  /// Handle device connected
  void _onDeviceConnected(BluetoothDevice device) async {
    _connectedDevice = device;
    _setState(BleConnectionState.connected);
    debugPrint('BleManager: Connected to ${device.platformName} (${device.remoteId})');
  }

  /// Trigger service discovery
  void _triggerServiceDiscovery(BluetoothDevice device) async {
    try {
      debugPrint('BleManager: Starting service discovery...');
      final services = await device.discoverServices();
      debugPrint('BleManager: Service discovery completed - found ${services.length} services');
      for (final service in services) {
        debugPrint('BleManager: Service: ${service.uuid}');
        for (final char in service.characteristics) {
          debugPrint('BleManager:   Characteristic: ${char.uuid}');
        }
      }
      _servicesDiscoveredController.add(null);
    } catch (e) {
      debugPrint('BleManager: Service discovery failed: $e');
    }
  }

  /// Handle device disconnected
  void _onDeviceDisconnected() {
    _connectedDevice = null;
    _weightMeasurementCharacteristic = null;
    _weightCustomConfigCharacteristic = null;
    _currentTimeCharacteristic = null;
    
    _notificationSubscription?.cancel();
    _connectionSubscription?.cancel();
    
    _setState(BleConnectionState.disconnected);
    debugPrint('Device disconnected');
  }

  /// Request necessary permissions
  Future<bool> _requestPermissions() async {
    if (Platform.isAndroid) {
      final permissions = <Permission>[
        Permission.bluetooth,
        Permission.bluetoothScan,
        Permission.bluetoothConnect,
        Permission.location,
      ];

      for (final permission in permissions) {
        final status = await permission.request();
        if (!status.isGranted) {
          return false;
        }
      }
    }
    
    return true;
  }

  /// Emit connection state change
  void _setState(BleConnectionState state) {
    _currentState = state;
    _stateController.add(state);
  }

  /// Emit error
  void _emitError(BleError error) {
    _errorController.add(error);
  }

  /// Check if UUIDs match (handles both short and long form)
  bool _uuidMatches(String actualUuid, String targetUuid) {
    final actual = actualUuid.toLowerCase();
    final target = targetUuid.toLowerCase();
    
    // Direct match
    if (actual == target) return true;
    
    // Check if target is short form and actual is long form
    if (target.length == 4 && actual.contains(target)) {
      return actual.startsWith('0000$target-0000-1000-8000-00805f9b34fb');
    }
    
    // Check if actual is short form and target is long form  
    if (actual.length == 4 && target.contains(actual)) {
      return target.startsWith('0000$actual-0000-1000-8000-00805f9b34fb');
    }
    
    return false;
  }

  /// Clean up any existing connections
  Future<void> _cleanupConnections() async {
    try {
      _connectionTimer?.cancel();
      _scanTimer?.cancel();
      await _notificationSubscription?.cancel();
      await _connectionSubscription?.cancel();
      
      if (_connectedDevice != null) {
        await _connectedDevice!.disconnect();
      }
      
      _onDeviceDisconnected();
    } catch (e) {
      debugPrint('Cleanup error: $e');
    }
  }

  /// Dispose resources
  void dispose() {
    _stateController.close();
    _errorController.close();
    _dataController.close();
    _writeSuccessController.close();
    _notificationSuccessController.close();
    _servicesDiscoveredController.close();
    _notificationSubscription?.cancel();
    _connectionSubscription?.cancel();
    _connectionTimer?.cancel();
    _scanTimer?.cancel();
  }
}