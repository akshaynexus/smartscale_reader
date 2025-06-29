import 'dart:async';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'ble_manager.dart';
import 'mi_scale2.dart';

/// Mi Scale 2 Controller - Complete rewrite following openScale exactly
class MiScale2Controller {
  final BleManager _bleManager = BleManager();
  final MiScale2 _miScale = MiScale2();
  
  final StreamController<ScaleMeasurement> _measurementController = 
      StreamController<ScaleMeasurement>.broadcast();
  final StreamController<String> _statusController = 
      StreamController<String>.broadcast();

  UserProfile? _currentUser;
  StreamSubscription<Uint8List>? _dataSubscription;
  StreamSubscription<BleConnectionState>? _stateSubscription;
  StreamSubscription<BleError>? _errorSubscription;
  
  Timer? _disconnectTimer;
  int _stepNr = 0;
  bool _stopped = false;
  int? _uniqueNumber;
  bool _isProtocolActive = false;

  /// Stream of scale measurements
  Stream<ScaleMeasurement> get measurementStream => 
      _measurementController.stream;
  
  /// Stream of status messages
  Stream<String> get statusStream => _statusController.stream;
  
  /// Stream of connection state changes
  Stream<BleConnectionState> get connectionStateStream => _bleManager.stateStream;
  
  /// Current connection state
  BleConnectionState get connectionState => _bleManager.currentState;
  
  /// Whether device is connected
  bool get isConnected => _bleManager.isConnected;

  /// Initialize the controller
  Future<bool> initialize() async {
    final success = await _bleManager.initialize();
    if (!success) {
      return false;
    }

    _setupBleListeners();
    return true;
  }

  /// Scan for Mi Scale 2 devices
  Future<List<BluetoothDevice>> scanForScales() async {
    _emitStatus('Scanning for Mi Scale 2 devices...');
    
    // Reset state before scanning
    _stepNr = 0;
    _stopped = false;
    _isProtocolActive = false;
    
    final devices = await _bleManager.scanForDevices();
    
    if (devices.isEmpty) {
      _emitStatus('No Mi Scale 2 devices found');
    } else {
      _emitStatus('Found ${devices.length} Mi Scale 2 device(s)');
      for (final device in devices) {
        debugPrint('Found scale: ${device.platformName} (${device.remoteId})');
      }
    }
    
    return devices;
  }

  /// Connect to a Mi Scale 2 device with user profile
  Future<bool> connectToScale(BluetoothDevice device, UserProfile userProfile) async {
    _currentUser = userProfile;
    _emitStatus('Connecting to ${device.platformName}...');
    
    final success = await _bleManager.connectToDevice(device);
    
    if (success) {
      _emitStatus('Connected successfully');
    } else {
      _emitStatus('Connection failed');
    }
    
    return success;
  }

  /// Disconnect from current device
  Future<void> disconnect() async {
    _emitStatus('Disconnecting...');
    
    _disconnectTimer?.cancel();
    _stepNr = 0;
    _stopped = false;
    _isProtocolActive = false;
    
    await _bleManager.disconnect();
    _emitStatus('Disconnected');
  }

  /// Connected event - start protocol immediately like openScale
  void _onConnected() {
    debugPrint('MiScale2Controller: Device connected, starting protocol');
    _emitStatus('Connected - starting communication protocol');
    _stepNr = 0;
    _stopped = false;
    _isProtocolActive = true;
    _resetDisconnectTimer();
    // Start protocol immediately like openScale does in onConnectedPeripheral
    _nextMachineStep();
  }

  /// Service discovery completed - resume if stopped
  void _onServicesDiscovered() {
    debugPrint('MiScale2Controller: Services discovered');
    // Only resume if we were stopped waiting for services
    if (_stopped && _isProtocolActive) {
      debugPrint('MiScale2Controller: Resuming protocol after service discovery');
      _resumeMachineState();
    }
  }

  /// Write success - continue to next step
  void _onWriteSuccess() {
    debugPrint('MiScale2Controller: Write success - stepNr=$_stepNr');
    if (_isProtocolActive) {
      _nextMachineStep();
    }
  }

  /// Notification enabled - resume protocol
  void _onNotificationSetupSuccess() {
    debugPrint('MiScale2Controller: Notifications enabled - stepNr=$_stepNr');
    if (_isProtocolActive) {
      _resumeMachineState();
    }
  }

  /// Main state machine - exactly like openScale
  void _nextMachineStep() {
    if (!_stopped && _isProtocolActive) {
      debugPrint('MiScale2Controller: Executing step $_stepNr');
      if (_onNextStep(_stepNr)) {
        _stepNr++;
        // Don't immediately recurse - let write callbacks trigger next step
        if (_stepNr == 1 || _stepNr == 4 || _stepNr == 5) {
          // These steps don't wait for write response
          _nextMachineStep();
        }
      } else {
        debugPrint('MiScale2Controller: Protocol complete, waiting for data...');
        _startDisconnectTimer();
      }
    } else {
      debugPrint('MiScale2Controller: Machine stopped or inactive - stepNr=$_stepNr, stopped=$_stopped, active=$_isProtocolActive');
    }
  }

  /// Execute protocol step - MiScale1 protocol for historical data
  bool _onNextStep(int stepNr) {
    debugPrint('MiScale2Controller: onNextStep($stepNr) - currentUser=${_currentUser != null}');
    
    if (_currentUser == null) {
      debugPrint('MiScale2Controller: No user profile set');
      return false;
    }

    switch (stepNr) {
      case 0:
        // Step 0: Set scale units (MiScale2 custom command)
        _emitStatus('Setting scale units...');
        final setUnitCmd = Uint8List.fromList([
          0x06, 
          0x04, 
          0x00, 
          _currentUser!.scaleUnit.value
        ]);
        _writeBytes(
          MiScale2.weightCustomService, 
          MiScale2.weightCustomConfig, 
          setUnitCmd
        );
        return true;
        
      case 1:
        // Step 1: Send magic bytes to prepare scale for history mode (MiScale1 protocol)
        _emitStatus('Preparing scale for history data...');
        _writeBytes(
          MiScale2.serviceBodyComposition,  // 181d service
          MiScale2.weightMeasurementHistoryCharacteristic,  // history characteristic
          Uint8List.fromList([0x01, 0x96, 0x8a, 0xbd, 0x62])  // Magic bytes
        );
        return true;
        
      case 2:
        // Step 2: Enable notifications on history characteristic
        _emitStatus('Enabling history notifications...');
        return _setNotificationOn(
          MiScale2.serviceBodyComposition, 
          MiScale2.weightMeasurementHistoryCharacteristic
        );
        
      case 3:
        // Step 3: Enable notifications on standard weight measurement
        _emitStatus('Enabling weight notifications...');
        return _setNotificationOn(
          MiScale2.serviceBodyComposition, 
          "00002a9d-0000-1000-8000-00805f9b34fb"  // Standard weight measurement
        );
        
      case 4:
        // Step 4: Send user identifier for historical data
        _emitStatus('Configuring user profile for history...');
        final uniqueNumber = _getUniqueNumber();
        final userIdentifier = Uint8List.fromList([
          0x01,
          0xFF,
          0xFF,
          (uniqueNumber >> 8) & 0xFF,
          uniqueNumber & 0xFF,
        ]);
        _writeBytes(
          MiScale2.serviceBodyComposition, 
          MiScale2.weightMeasurementHistoryCharacteristic, 
          userIdentifier
        );
        return true;
        
      case 5:
        // Step 5: Request historical data dump
        _emitStatus('Requesting stored measurement data...');
        _writeBytes(
          MiScale2.serviceBodyComposition, 
          MiScale2.weightMeasurementHistoryCharacteristic, 
          Uint8List.fromList([0x02])
        );
        _stopMachineState(); // Stop here and wait for historical data
        _emitStatus('✅ Requesting stored measurements from scale memory...');
        return true;
        
      default:
        return false;
    }
  }

  /// Write data to characteristic
  void _writeBytes(String serviceUuid, String characteristicUuid, Uint8List data) {
    debugPrint('MiScale2Controller: Writing [${data.map((b) => b.toRadixString(16).padLeft(2, '0')).join(' ')}] to $characteristicUuid');
    _bleManager.writeCharacteristic(serviceUuid, characteristicUuid, data);
  }

  /// Enable notifications - critical for receiving data
  bool _setNotificationOn(String serviceUuid, String characteristicUuid) {
    debugPrint('MiScale2Controller: Enabling notifications on $characteristicUuid');
    _bleManager.enableNotifications(serviceUuid, characteristicUuid);
    _stopMachineState(); // Stop and wait for notification confirmation
    return true;
  }

  /// Stop machine state
  void _stopMachineState() {
    debugPrint('MiScale2Controller: Stopping machine state at step $_stepNr');
    _stopped = true;
  }

  /// Resume machine state
  void _resumeMachineState() {
    debugPrint('MiScale2Controller: Resuming machine state at step $_stepNr');
    _stopped = false;
    _nextMachineStep();
  }

  /// Get unique number for user identification
  int _getUniqueNumber() {
    _uniqueNumber ??= 100 + (DateTime.now().millisecondsSinceEpoch % 65435);
    return _uniqueNumber! + (_currentUser?.age ?? 0);
  }

  /// Handle measurement data from scale - THE CORE DATA PROCESSING
  void _handleMeasurementData(Uint8List data) {
    if (_currentUser == null) return; // Allow data even if protocol not active (for live measurements)

    _resetDisconnectTimer(); // Reset timeout on any data

    debugPrint('MiScale2Controller: Received data [${data.map((b) => b.toRadixString(16).padLeft(2, '0')).join(' ')}]');

    // Handle stop command from scale
    if (data.length > 0 && data[0] == 0x03) {
      debugPrint('MiScale2Controller: Scale stop command received');
      _emitStatus('Scale finished sending data');
      
      // Send stop acknowledgment
      _writeBytes(
        MiScale2.serviceBodyComposition,
        MiScale2.weightMeasurementHistoryCharacteristic,
        Uint8List.fromList([0x03])
      );
      
      // Send final acknowledgment with user ID
      final uniqueNumber = _getUniqueNumber();
      final userIdentifier = Uint8List.fromList([
        0x04,
        0xFF,
        0xFF,
        (uniqueNumber >> 8) & 0xFF,
        uniqueNumber & 0xFF,
      ]);
      _writeBytes(
        MiScale2.serviceBodyComposition,
        MiScale2.weightMeasurementHistoryCharacteristic,
        userIdentifier
      );
      
      return;
    }

    // Parse ANY measurement data - from 6 bytes up (not just 13)
    if (data.length >= 6) {
      debugPrint('🔍 SCALE DATA RECEIVED (${data.length} bytes):');
      debugPrint('🔍 Raw bytes: ${data.map((b) => '0x${b.toRadixString(16).padLeft(2, '0')}').join(' ')}');
      debugPrint('🔍 Decimal: ${data.join(' ')}');
      
      // Check for standard BLE weight measurement format (8-10 bytes typically)
      if (data.length >= 8 && data.length <= 12) {
        debugPrint('🔍 Standard BLE weight measurement (${data.length} bytes):');
        debugPrint('  [0] Flags: 0x${data[0].toRadixString(16)}');
        if (data.length >= 3) {
          final weightRaw = ((data[2] << 8) | data[1]);
          final weightKg = weightRaw / 200.0; // Standard BLE weight format
          debugPrint('  [1-2] Weight: $weightRaw -> ${weightKg.toStringAsFixed(2)} kg');
          
          // Create measurement from standard BLE format
          final measurement = ScaleMeasurement(
            weight: weightKg,
            dateTime: DateTime.now(),
            impedance: null,
            bodyFat: null,
            water: null,
            muscle: null,
            bone: null,
            visceralFat: null,
            leanBodyMass: null,
          );
          
          _emitStatus('📊 LIVE MEASUREMENT: ${weightKg.toStringAsFixed(2)} kg');
          debugPrint('🎉 LIVE WEIGHT MEASUREMENT: ${weightKg.toStringAsFixed(2)} kg');
          _measurementController.add(measurement);
          return; // Successfully processed
        }
      }
      
      // Enhanced parsing for full 13-byte MiScale format
      else if (data.length >= 13) {
        debugPrint('🔍 Full 13-byte measurement breakdown:');
        debugPrint('  [0-1] Control: 0x${data[0].toRadixString(16)} 0x${data[1].toRadixString(16)}');
        final isWeightRemoved = (data[1] & 0x80) != 0;
        final isStabilized = (data[1] & 0x20) != 0;
        final isLBSUnit = (data[0] & 0x01) != 0;
        final isCattyUnit = (data[1] & 0x40) != 0;
        final isImpedance = (data[1] & 0x02) != 0;
        debugPrint('  Flags: weightRemoved=$isWeightRemoved, stabilized=$isStabilized, lbs=$isLBSUnit, catty=$isCattyUnit, impedance=$isImpedance');
        debugPrint('  [2-3] Year: ${((data[3] << 8) | data[2])} (0x${data[2].toRadixString(16)} 0x${data[3].toRadixString(16)})');
        debugPrint('  [4-8] Date: ${data[4]}/${data[5]} ${data[6]}:${data[7]}:${data[8]}');
        debugPrint('  [9-10] Impedance: ${((data[10] << 8) | data[9])} (0x${data[9].toRadixString(16)} 0x${data[10].toRadixString(16)})');
        debugPrint('  [11-12] Weight raw: ${((data[12] << 8) | data[11])} (0x${data[11].toRadixString(16)} 0x${data[12].toRadixString(16)})');
        final weightRaw = ((data[12] << 8) | data[11]);
        final weightKg1 = weightRaw / 200.0; // Standard kg calculation
        final weightKg2 = weightRaw / 100.0; // Alternative calculation
        debugPrint('  Weight calc 1 (÷200): ${weightKg1.toStringAsFixed(2)} kg');
        debugPrint('  Weight calc 2 (÷100): ${weightKg2.toStringAsFixed(2)} kg');
        
        // Try to parse with openScale algorithm
        final measurement = _miScale.parseMeasurementData(data, _currentUser!);
        
        if (measurement != null) {
          _emitStatus('📊 NEW MEASUREMENT: ${measurement.weight.toStringAsFixed(2)} kg');
          debugPrint('🎉 VALID MEASUREMENT: weight=${measurement.weight} kg, fat=${measurement.bodyFat?.toStringAsFixed(1)}%, impedance=${measurement.impedance}');
          _measurementController.add(measurement);
          return; // Successfully processed
        }
      } else if (data.length >= 6) {
        // Try parsing shorter data as potential live weight updates
        debugPrint('🔍 Short data analysis:');
        for (int i = 0; i < data.length - 1; i++) {
          final weightRaw = ((data[i+1] << 8) | data[i]);
          final weightKg1 = weightRaw / 200.0;
          final weightKg2 = weightRaw / 100.0;
          debugPrint('  Bytes [$i-${i+1}]: raw=$weightRaw -> ${weightKg1.toStringAsFixed(2)} kg (÷200) / ${weightKg2.toStringAsFixed(2)} kg (÷100)');
        }
      }
      
      _emitStatus('❓ Received data but parsing failed - may be intermediate measurement');
      debugPrint('❓ Could not parse as valid measurement - may be live weight update');
    } else {
      debugPrint('MiScale2Controller: Received ${data.length} bytes (too short for any measurement)');
      if (data.length > 0) {
        debugPrint('MiScale2Controller: Short data: ${data.map((b) => '0x${b.toRadixString(16).padLeft(2, '0')}').join(' ')}');
      }
    }
  }

  /// Setup BLE event listeners
  void _setupBleListeners() {
    // Connection state changes
    _stateSubscription = _bleManager.stateStream.listen((state) {
      debugPrint('MiScale2Controller: BLE state = $state');
      switch (state) {
        case BleConnectionState.connected:
          _onConnected();
          break;
        case BleConnectionState.disconnected:
          _emitStatus('Disconnected from scale');
          _stepNr = 0;
          _stopped = false;
          _isProtocolActive = false;
          break;
        case BleConnectionState.scanning:
          _emitStatus('Scanning...');
          break;
        case BleConnectionState.connecting:
          _emitStatus('Connecting...');
          break;
        case BleConnectionState.disconnecting:
          _emitStatus('Disconnecting...');
          break;
        case BleConnectionState.error:
          _emitStatus('Connection error');
          break;
      }
    });

    // BLE errors
    _errorSubscription = _bleManager.errorStream.listen((error) {
      String message;
      switch (error) {
        case BleError.permissionDenied:
          message = 'Bluetooth permissions denied';
          break;
        case BleError.bluetoothDisabled:
          message = 'Bluetooth is disabled';
          break;
        case BleError.deviceNotFound:
          message = 'Device not found';
          break;
        case BleError.connectionFailed:
          message = 'Connection failed';
          break;
        case BleError.connectionTimeout:
          message = 'Connection timeout';
          break;
        case BleError.serviceNotFound:
          message = 'Service not found';
          break;
        case BleError.characteristicNotFound:
          message = 'Characteristic not found';
          break;
        case BleError.writeError:
          message = 'Write operation failed';
          break;
        case BleError.readError:
          message = 'Read operation failed';
          break;
        case BleError.unknown:
          message = 'Unknown error occurred';
          break;
      }
      _emitStatus('Error: $message');
    });

    // CRITICAL: Measurement data listener
    _dataSubscription = _bleManager.dataStream.listen((data) {
      _handleMeasurementData(data);
    });

    // Write success - triggers next step
    _bleManager.writeSuccessStream.listen((_) {
      _onWriteSuccess();
    });

    // Notification setup success - resumes machine state
    _bleManager.notificationSuccessStream.listen((_) {
      _onNotificationSetupSuccess();
    });

    // Services discovered
    _bleManager.servicesDiscoveredStream.listen((_) {
      _onServicesDiscovered();
    });
  }

  /// Reset disconnect timer
  void _resetDisconnectTimer() {
    _disconnectTimer?.cancel();
    _startDisconnectTimer();
  }
  
  /// Start disconnect timer
  void _startDisconnectTimer() {
    _disconnectTimer = Timer(const Duration(seconds: 60), () {
      debugPrint('MiScale2Controller: 60s timeout - disconnecting');
      disconnect();
    });
  }

  /// Emit status message
  void _emitStatus(String message) {
    debugPrint('MiScale2Controller: $message');
    _statusController.add(message);
  }

  /// Get device information
  String getDeviceInfo(BluetoothDevice device) {
    return '${device.platformName} (${device.remoteId})';
  }

  /// Check if device is a Mi Scale 2
  bool isMiScale2(BluetoothDevice device) {
    final name = device.platformName.toUpperCase();
    return name.isNotEmpty && (
      name.contains('MIBCS') ||     // MiScale2 v2 naming (priority)
      name.contains('MIBFS') ||     // MiScale2 v2 naming (priority)
      name.contains('MI SCALE') || 
      name == 'MI_SCALE' ||
      name.contains('MISCALE')
    );
  }

  /// Dispose resources
  void dispose() {
    _measurementController.close();
    _statusController.close();
    _dataSubscription?.cancel();
    _stateSubscription?.cancel();
    _errorSubscription?.cancel();
    _disconnectTimer?.cancel();
    _bleManager.dispose();
  }
}