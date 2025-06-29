import 'dart:typed_data';
import 'dart:math';
import 'mi_scale_lib.dart';

/// Scale units
enum ScaleUnit {
  kg(0),
  lbs(1), 
  catty(2);
  
  const ScaleUnit(this.value);
  final int value;
}

/// Gender enumeration for body composition calculations
enum Gender {
  female(0),
  male(1);
  
  const Gender(this.value);
  final int value;
}

/// User profile for body composition calculations
class UserProfile {
  final Gender gender;
  final int age;
  final double height; // in cm
  final ScaleUnit scaleUnit;
  
  const UserProfile({
    required this.gender,
    required this.age,
    required this.height,
    this.scaleUnit = ScaleUnit.kg,
  });
}

/// Scale measurement data
class ScaleMeasurement {
  final double weight; // in kg
  final DateTime dateTime;
  final double? impedance;
  final double? bodyFat;
  final double? water;
  final double? muscle;
  final double? bone;
  final double? visceralFat;
  final double? leanBodyMass;
  
  const ScaleMeasurement({
    required this.weight,
    required this.dateTime,
    this.impedance,
    this.bodyFat,
    this.water,
    this.muscle,
    this.bone,
    this.visceralFat,
    this.leanBodyMass,
  });
  
  @override
  String toString() {
    return 'ScaleMeasurement{weight: ${weight}kg, dateTime: $dateTime, '
           'impedance: $impedance, bodyFat: $bodyFat%, water: $water%, '
           'muscle: $muscle%, bone: ${bone}kg, visceralFat: $visceralFat, '
           'leanBodyMass: ${leanBodyMass}kg}';
  }
}

/// MiScale2 Bluetooth Communication Bridge
/// 
/// This class provides a Dart bridge to the Xiaomi Mi Scale v2 Bluetooth protocol
/// based on the openScale implementation in Java.
/// 
/// Key Features:
/// - 5-step connection protocol
/// - 13-byte measurement data parsing
/// - Body composition calculations using impedance
/// - Multi-user support with unique identifiers
/// - Unit conversion (kg, lbs, catty)
/// 
/// Protocol Overview:
/// 1. Set scale units
/// 2. Set current time
/// 3. Enable notifications
/// 4. Configure scale with user identifier
/// 5. Request measurement data
class MiScale2 {
  /// Custom Xiaomi service UUIDs
  static const String weightMeasurementHistoryCharacteristic = 
      "00002a2f-0000-3512-2118-0009af100700";
  static const String weightCustomService = 
      "00001530-0000-3512-2118-0009af100700";
  static const String weightCustomConfig = 
      "00001542-0000-3512-2118-0009af100700";
  
  /// Standard Bluetooth GATT service UUIDs  
  static const String serviceBodyComposition = 
      "0000181d-0000-1000-8000-00805f9b34fb";  // Weight Scale service (181d) - your MiScale2 uses this
  static const String characteristicCurrentTime = 
      "00002a2b-0000-1000-8000-00805f9b34fb";

  /// Connection step commands
  List<Uint8List> getConnectionSteps(UserProfile userProfile) {
    final steps = <Uint8List>[];
    
    // Step 0: Set scale units
    steps.add(Uint8List.fromList([0x06, 0x04, 0x00, userProfile.scaleUnit.value]));
    
    // Step 1: Set current time
    final now = DateTime.now();
    steps.add(Uint8List.fromList([
      now.year & 0xFF,
      (now.year >> 8) & 0xFF,
      now.month,
      now.day,
      now.hour,
      now.minute,
      now.second,
      0x03,
      0x00,
      0x00,
    ]));
    
    // Step 2: Enable notifications (handled by BLE layer)
    
    // Step 3: Configure scale with user identifier
    final uniqueNumber = _generateUniqueNumber();
    steps.add(Uint8List.fromList([
      0x01,
      0xFF,
      0xFF,
      (uniqueNumber >> 8) & 0xFF,
      uniqueNumber & 0xFF,
    ]));
    
    // Step 4: Request measurement data
    steps.add(Uint8List.fromList([0x02]));
    
    return steps;
  }

  /// Generate unique number for user identification
  int _generateUniqueNumber() {
    final random = Random();
    return random.nextInt(65535 - 100 + 1) + 100;
  }

  /// Parse 13-byte measurement data from Mi Scale 2
  /// 
  /// Data format:
  /// - Bytes 0-1: Control bytes (unit flags, stabilization, impedance)
  /// - Bytes 2-8: Date and time
  /// - Bytes 9-10: Impedance value
  /// - Bytes 11-12: Weight value
  ScaleMeasurement? parseMeasurementData(Uint8List data, UserProfile userProfile) {
    if (data.length != 13) {
      return null;
    }
    
    final ctrlByte0 = data[0];
    final ctrlByte1 = data[1];
    
    // Parse control flags
    final isWeightRemoved = _isBitSet(ctrlByte1, 7);
    final isStabilized = _isBitSet(ctrlByte1, 5);
    final isLBSUnit = _isBitSet(ctrlByte0, 0);
    final isCattyUnit = _isBitSet(ctrlByte1, 6);
    final isImpedance = _isBitSet(ctrlByte1, 1);
    
    // Only process stabilized measurements when weight is on scale
    if (!isStabilized || isWeightRemoved) {
      return null;
    }
    
    // Parse date and time
    final year = (data[3] << 8) | data[2];
    final month = data[4];
    final day = data[5];
    final hour = data[6];
    final minute = data[7];
    final second = data[8];
    
    // Validate date (within 20 years of current date)
    final dateTime = DateTime(year, month, day, hour, minute, second);
    if (!_validateDate(dateTime, 20)) {
      return null;
    }
    
    // Parse weight based on unit
    double weight;
    if (isLBSUnit || isCattyUnit) {
      weight = ((data[12] << 8) | data[11]) / 100.0;
    } else {
      weight = ((data[12] << 8) | data[11]) / 200.0;
    }
    
    // Convert to kg if necessary
    weight = _convertToKg(weight, userProfile.scaleUnit);
    
    // Parse impedance if available
    double? impedance;
    if (isImpedance) {
      impedance = ((data[10] << 8) | data[9]).toDouble();
    }
    
    // Calculate body composition if impedance is available
    double? bodyFat, water, muscle, bone, visceralFat, leanBodyMass;
    
    if (impedance != null && impedance > 0) {
      final miScaleLib = MiScaleLib(
        gender: userProfile.gender,
        age: userProfile.age,
        height: userProfile.height,
      );
      
      bodyFat = miScaleLib.getBodyFat(weight, impedance);
      water = miScaleLib.getWater(weight, impedance);
      muscle = miScaleLib.getMuscle(weight, impedance);
      bone = miScaleLib.getBoneMass(weight, impedance);
      visceralFat = miScaleLib.getVisceralFat(weight);
      leanBodyMass = miScaleLib.getLBM(weight, impedance);
      
      // Convert muscle from kg to percentage
      muscle = (muscle / weight) * 100.0;
    }
    
    return ScaleMeasurement(
      weight: weight,
      dateTime: dateTime,
      impedance: impedance,
      bodyFat: bodyFat,
      water: water,
      muscle: muscle,
      bone: bone,
      visceralFat: visceralFat,
      leanBodyMass: leanBodyMass,
    );
  }

  /// Handle stop command acknowledgment
  Uint8List getStopAcknowledgment() {
    return Uint8List.fromList([0x03]);
  }

  /// Handle final acknowledgment with user identifier
  Uint8List getFinalAcknowledgment() {
    final uniqueNumber = _generateUniqueNumber();
    return Uint8List.fromList([
      0x04,
      0xFF,
      0xFF,
      (uniqueNumber >> 8) & 0xFF,
      uniqueNumber & 0xFF,
    ]);
  }

  /// Check if bit is set in byte
  bool _isBitSet(int byte, int bit) {
    return (byte & (1 << bit)) != 0;
  }

  /// Validate date within specified year range
  bool _validateDate(DateTime date, int yearRange) {
    final now = DateTime.now();
    final minDate = DateTime(now.year - yearRange);
    final maxDate = DateTime(now.year + yearRange);
    
    return date.isAfter(minDate) && date.isBefore(maxDate);
  }

  /// Convert weight to kg based on scale unit
  double _convertToKg(double weight, ScaleUnit unit) {
    switch (unit) {
      case ScaleUnit.kg:
        return weight;
      case ScaleUnit.lbs:
        return weight * 0.453592; // 1 lb = 0.453592 kg
      case ScaleUnit.catty:
        return weight * 0.5; // 1 catty = 0.5 kg
    }
  }
}