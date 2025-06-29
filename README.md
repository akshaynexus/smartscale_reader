# Smart Scale Reader

A Dart package for reading data from Xiaomi Mi Scale v2 via Bluetooth Low Energy (BLE). This package provides a bridge to the Mi Scale 2 protocol and body composition calculations based on the reverse-engineered implementation from the openScale project.

## Features

- **Mi Scale 2 Protocol Support**: Complete implementation of the 5-step connection protocol
- **Body Composition Calculations**: Advanced metrics including body fat, water, muscle, bone mass, and visceral fat
- **Multi-Unit Support**: Handles kg, lbs, and catty weight units
- **User Profiles**: Gender, age, and height-specific calculations
- **Data Validation**: Robust parsing with date validation and error handling

## Installation

Add this to your package's `pubspec.yaml` file:

```yaml
dependencies:
  smartscale_reader: ^1.0.0
```

## Usage

### Basic Setup

```dart
import 'package:smartscale_reader/smartscale_reader.dart';

// Create a user profile
const userProfile = MiScale2.UserProfile(
  gender: MiScale2.Gender.male,
  age: 30,
  height: 175.0, // cm
  scaleUnit: MiScale2.ScaleUnit.kg,
);

// Initialize MiScale2 instance
final miScale = MiScale2();
```

### BLE Connection Protocol

The Mi Scale 2 uses a 5-step connection protocol:

```dart
// Get connection steps for BLE communication
final connectionSteps = miScale.getConnectionSteps(userProfile);

// Step 0: Set scale units
// Step 1: Set current time  
// Step 2: Enable notifications (handled by your BLE layer)
// Step 3: Configure scale with user identifier
// Step 4: Request measurement data
```

### Parsing Measurement Data

```dart
// Parse 13-byte measurement data from BLE notification
final measurement = miScale.parseMeasurementData(bleData, userProfile);

if (measurement != null) {
  print('Weight: ${measurement.weight} kg');
  print('Date: ${measurement.dateTime}');
  print('Body Fat: ${measurement.bodyFat}%');
  print('Water: ${measurement.water}%');
  print('Muscle: ${measurement.muscle}%');
  print('Bone: ${measurement.bone} kg');
  print('Visceral Fat: ${measurement.visceralFat}');
}
```

### Direct Body Composition Calculations

```dart
final miScaleLib = MiScaleLib(
  gender: MiScale2.Gender.male,
  age: 30,
  height: 175.0,
);

const weight = 70.0; // kg
const impedance = 400.0; // ohms

final bmi = miScaleLib.getBMI(weight);
final bodyFat = miScaleLib.getBodyFat(weight, impedance);
final water = miScaleLib.getWater(weight, impedance);
final muscle = miScaleLib.getMuscle(weight, impedance);
final bone = miScaleLib.getBoneMass(weight, impedance);
final visceralFat = miScaleLib.getVisceralFat(weight);
```

## Protocol Details

### Bluetooth UUIDs

- **Weight Measurement History**: `00002a2f-0000-3512-2118-0009af100700`
- **Weight Custom Service**: `00001530-0000-3512-2118-0009af100700`  
- **Weight Custom Config**: `00001542-0000-3512-2118-0009af100700`
- **Body Composition Service**: `0000181b-0000-1000-8000-00805f9b34fb`
- **Current Time**: `00002a2b-0000-1000-8000-00805f9b34fb`

### Data Format

The Mi Scale 2 sends 13-byte measurement packets:

| Bytes | Description |
|-------|-------------|
| 0-1   | Control bytes (unit flags, stabilization, impedance) |
| 2-8   | Date and time (year, month, day, hour, minute, second) |
| 9-10  | Impedance value (if available) |
| 11-12 | Weight value |

### Control Byte Flags

- **Bit 0 (Byte 0)**: LBS unit flag
- **Bit 6 (Byte 1)**: Catty unit flag  
- **Bit 1 (Byte 1)**: Impedance available
- **Bit 5 (Byte 1)**: Weight stabilized
- **Bit 7 (Byte 1)**: Weight removed

## Body Composition Algorithms

The body composition calculations are based on reverse engineering of the Mi Body Composition Scale protocol. The algorithms take into account:

- **Gender**: Different coefficients for male/female
- **Age**: Age-specific adjustments for accuracy
- **Height**: Height-based calculations for lean body mass
- **Weight**: Current weight measurement
- **Impedance**: Bioelectrical impedance for body composition

### Calculated Metrics

- **BMI**: Body Mass Index
- **Body Fat %**: Percentage of body fat
- **Water %**: Body water percentage  
- **Muscle Mass**: Lean muscle mass in kg
- **Bone Mass**: Bone mass in kg
- **Visceral Fat**: Visceral fat rating (1-59)
- **LBM**: Lean Body Mass in kg

## Implementation Notes

- The package is based on the Java implementation from the [openScale](https://github.com/oliexdev/openScale) project
- Body composition algorithms are reverse-engineered from the Mi Fit app
- Date validation ensures measurements are within a reasonable time range
- Multi-user support through unique identifier generation
- Unit conversion handles kg, lbs, and catty measurements

## Requirements

- Dart SDK >=2.17.0
- Bluetooth Low Energy (BLE) support on target platform
- Compatible with Android/iOS through flutter_blue_plus or similar BLE packages

## License

This package is released under the GPL-3.0 license, maintaining compatibility with the original openScale implementation.

## Contributing

Contributions are welcome! Please ensure any changes maintain compatibility with the Mi Scale 2 protocol and follow the existing code style.

## Acknowledgments

- [openScale project](https://github.com/oliexdev/openScale) for the original Java implementation
- [prototux](https://github.com/prototux/MIBCS-reverse-engineering) for reverse engineering the Mi Body Composition Scale protocol
