import 'dart:math';

/// Body composition calculation library for Mi Scale
/// 
/// Based on reverse engineering of the Mi Body Composition Scale protocol
/// as implemented in openScale project.
/// 
/// This library calculates various body composition metrics using weight,
/// impedance, and user parameters (gender, age, height).
/// 
/// Original research: https://github.com/prototux/MIBCS-reverse-engineering
class MiScaleLib {
  final int _sex; // 0 = female, 1 = male
  final int _age;
  final double _height; // in cm

  /// Create a new MiScaleLib instance
  /// 
  /// [gender] - User's gender (affects calculation coefficients)
  /// [age] - User's age in years
  /// [height] - User's height in centimeters
  MiScaleLib({
    required gender,
    required int age,
    required double height,
  }) : _sex = gender.value,
       _age = age,
       _height = height;

  /// Calculate Lean Body Mass coefficient
  /// 
  /// This is a core calculation used by other body composition metrics
  double _getLBMCoefficient(double weight, double impedance) {
    double lbm = (_height * 9.058 / 100.0) * (_height / 100.0);
    lbm += weight * 0.32 + 12.226;
    lbm -= impedance * 0.0068;
    lbm -= _age * 0.0542;
    
    return lbm;
  }

  /// Calculate Body Mass Index (BMI)
  /// 
  /// [weight] - Weight in kg
  /// Returns BMI value
  double getBMI(double weight) {
    return weight / (((_height * _height) / 100.0) / 100.0);
  }

  /// Calculate Lean Body Mass (LBM)
  /// 
  /// [weight] - Weight in kg
  /// [impedance] - Bioelectrical impedance in ohms
  /// Returns lean body mass in kg
  double getLBM(double weight, double impedance) {
    double leanBodyMass = weight - 
        ((getBodyFat(weight, impedance) * 0.01) * weight) - 
        getBoneMass(weight, impedance);

    // Apply gender-specific caps
    if (_sex == 0 && leanBodyMass >= 84.0) {
      leanBodyMass = 120.0;
    } else if (_sex == 1 && leanBodyMass >= 93.5) {
      leanBodyMass = 120.0;
    }

    return leanBodyMass;
  }

  /// Calculate muscle mass
  /// 
  /// Note: This returns the same value as LBM to match Mi Fit app behavior
  /// 
  /// [weight] - Weight in kg
  /// [impedance] - Bioelectrical impedance in ohms
  /// Returns muscle mass in kg
  double getMuscle(double weight, double impedance) {
    return getLBM(weight, impedance);
  }

  /// Calculate body water percentage
  /// 
  /// [weight] - Weight in kg
  /// [impedance] - Bioelectrical impedance in ohms
  /// Returns water percentage (0-100)
  double getWater(double weight, double impedance) {
    double water = (100.0 - getBodyFat(weight, impedance)) * 0.7;
    
    double coeff = water < 50 ? 1.02 : 0.98;
    
    return coeff * water;
  }

  /// Calculate bone mass
  /// 
  /// [weight] - Weight in kg
  /// [impedance] - Bioelectrical impedance in ohms
  /// Returns bone mass in kg
  double getBoneMass(double weight, double impedance) {
    double base = _sex == 0 ? 0.245691014 : 0.18016894;
    
    double boneMass = (base - (_getLBMCoefficient(weight, impedance) * 0.05158)) * -1.0;
    
    // Apply adjustment based on initial value
    if (boneMass > 2.2) {
      boneMass += 0.1;
    } else {
      boneMass -= 0.1;
    }
    
    // Apply gender-specific caps
    if (_sex == 0 && boneMass > 5.1) {
      boneMass = 8.0;
    } else if (_sex == 1 && boneMass > 5.2) {
      boneMass = 8.0;
    }
    
    return boneMass;
  }

  /// Calculate visceral fat rating
  /// 
  /// [weight] - Weight in kg
  /// Returns visceral fat rating (typically 1-59)
  double getVisceralFat(double weight) {
    double visceralFat = 0.0;
    
    if (_sex == 0) { // Female
      if (weight > (13.0 - (_height * 0.5)) * -1.0) {
        double subsubcalc = ((_height * 1.45) + (_height * 0.1158) * _height) - 120.0;
        double subcalc = weight * 500.0 / subsubcalc;
        visceralFat = (subcalc - 6.0) + (_age * 0.07);
      } else {
        double subcalc = 0.691 + (_height * -0.0024) + (_height * -0.0024);
        visceralFat = (((_height * 0.027) - (subcalc * weight)) * -1.0) + 
                     (_age * 0.07) - _age;
      }
    } else { // Male
      if (_height < weight * 1.6) {
        double subcalc = ((_height * 0.4) - (_height * (_height * 0.0826))) * -1.0;
        visceralFat = ((weight * 305.0) / (subcalc + 48.0)) - 2.9 + (_age * 0.15);
      } else {
        double subcalc = 0.765 + _height * -0.0015;
        visceralFat = (((_height * 0.143) - (weight * subcalc)) * -1.0) + 
                     (_age * 0.15) - 5.0;
      }
    }
    
    return visceralFat;
  }

  /// Calculate body fat percentage
  /// 
  /// [weight] - Weight in kg
  /// [impedance] - Bioelectrical impedance in ohms
  /// Returns body fat percentage (0-100)
  double getBodyFat(double weight, double impedance) {
    double lbmSub = 0.8;
    
    // Gender and age-specific adjustments
    if (_sex == 0 && _age <= 49) {
      lbmSub = 9.25;
    } else if (_sex == 0 && _age > 49) {
      lbmSub = 7.25;
    }
    
    double lbmCoeff = _getLBMCoefficient(weight, impedance);
    double coeff = 1.0;
    
    // Weight and gender-specific coefficient adjustments
    if (_sex == 1 && weight < 61.0) {
      coeff = 0.98;
    } else if (_sex == 0 && weight > 60.0) {
      coeff = 0.96;
      
      if (_height > 160.0) {
        coeff *= 1.03;
      }
    } else if (_sex == 0 && weight < 50.0) {
      coeff = 1.02;
      
      if (_height > 160.0) {
        coeff *= 1.03;
      }
    }
    
    double bodyFat = (1.0 - (((lbmCoeff - lbmSub) * coeff) / weight)) * 100.0;
    
    // Cap maximum body fat percentage
    if (bodyFat > 63.0) {
      bodyFat = 75.0;
    }
    
    return bodyFat;
  }
}