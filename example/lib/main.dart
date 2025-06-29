import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:smartscale_reader/smartscale_reader.dart';
import 'package:auto_size_text/auto_size_text.dart';

void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Mi Scale 2 Reader',
      theme: ThemeData(
        primarySwatch: Colors.blue,
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF1976D2),
          brightness: Brightness.dark,
        ),
      ),
      home: const MiScaleHomePage(),
    );
  }
}

class MiScaleHomePage extends StatefulWidget {
  const MiScaleHomePage({super.key});

  @override
  State<MiScaleHomePage> createState() => _MiScaleHomePageState();
}

class _MiScaleHomePageState extends State<MiScaleHomePage> with TickerProviderStateMixin {
  final MiScale2Controller _controller = MiScale2Controller();
  final UserProfile _userProfile = UserProfile(
    gender: Gender.male,
    age: 30,
    height: 175.0,
    scaleUnit: ScaleUnit.kg,
  );

  bool _isInitialized = false;
  bool _isScanning = false;
  List<ScaleMeasurement> _measurements = [];
  ScaleMeasurement? _latestMeasurement;
  List<String> _statusLog = [];
  BleConnectionState _connectionState = BleConnectionState.disconnected;

  late AnimationController _pulseController;
  late AnimationController _weightController;
  late Animation<double> _pulseAnimation;
  late Animation<double> _weightAnimation;

  @override
  void initState() {
    super.initState();
    _pulseController = AnimationController(
      duration: const Duration(seconds: 2),
      vsync: this,
    )..repeat(reverse: true);
    
    _weightController = AnimationController(
      duration: const Duration(milliseconds: 800),
      vsync: this,
    );
    
    _pulseAnimation = Tween<double>(begin: 0.8, end: 1.2).animate(
      CurvedAnimation(parent: _pulseController, curve: Curves.easeInOut),
    );
    
    _weightAnimation = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(parent: _weightController, curve: Curves.elasticOut),
    );
    
    _initializeController();
  }

  @override
  void dispose() {
    _pulseController.dispose();
    _weightController.dispose();
    _controller.dispose();
    super.dispose();
  }

  Future<void> _initializeController() async {
    _addStatus('🚀 Initializing Mi Scale 2 Reader...');
    
    final success = await _controller.initialize();
    
    if (success) {
      setState(() {
        _isInitialized = true;
      });
      
      // Listen to status updates
      _controller.statusStream.listen((status) {
        _addStatus(status);
      });
      
      // Listen to measurements
      _controller.measurementStream.listen((measurement) {
        setState(() {
          _measurements.insert(0, measurement);
          _latestMeasurement = measurement;
          if (_measurements.length > 50) {
            _measurements.removeRange(50, _measurements.length);
          }
        });
        _weightController.forward();
        _addStatus('📊 New measurement: ${measurement.weight.toStringAsFixed(2)} kg');
      });
      
      // Listen to connection state changes
      _controller.connectionStateStream.listen((state) {
        setState(() {
          _connectionState = state;
        });
      });
      
      _addStatus('✅ Ready to scan for Mi Scale 2');
    } else {
      _addStatus('❌ Bluetooth initialization failed');
    }
  }

  Future<void> _scanAndConnect() async {
    if (!_isInitialized) return;
    
    setState(() {
      _isScanning = true;
    });
    
    try {
      _addStatus('🔍 Scanning for Mi Scale 2 devices...');
      final devices = await _controller.scanForScales();
      
      if (devices.isNotEmpty) {
        final device = devices.first;
        _addStatus('📱 Found: ${_controller.getDeviceInfo(device)}');
        _addStatus('🔗 Connecting...');
        
        await _controller.connectToScale(device, _userProfile);
      } else {
        _addStatus('❌ No Mi Scale 2 devices found');
      }
    } catch (e) {
      _addStatus('❌ Scan error: $e');
    } finally {
      setState(() {
        _isScanning = false;
      });
    }
  }

  Future<void> _disconnect() async {
    _addStatus('🔌 Disconnecting...');
    await _controller.disconnect();
    setState(() {
      _latestMeasurement = null;
    });
    _weightController.reset();
  }

  void _addStatus(String message) {
    setState(() {
      _statusLog.insert(0, '${DateTime.now().toString().substring(11, 19)} $message');
      if (_statusLog.length > 100) {
        _statusLog.removeRange(100, _statusLog.length);
      }
    });
  }

  Widget _buildConnectionCard() {
    Color connectionColor;
    IconData connectionIcon;
    String connectionText;
    
    switch (_connectionState) {
      case BleConnectionState.connected:
        connectionColor = Colors.green;
        connectionIcon = Icons.bluetooth_connected;
        connectionText = 'Connected';
        break;
      case BleConnectionState.connecting:
        connectionColor = Colors.orange;
        connectionIcon = Icons.bluetooth_searching;
        connectionText = 'Connecting...';
        break;
      case BleConnectionState.scanning:
        connectionColor = Colors.blue;
        connectionIcon = Icons.search;
        connectionText = 'Scanning...';
        break;
      case BleConnectionState.disconnecting:
        connectionColor = Colors.red;
        connectionIcon = Icons.bluetooth_disabled;
        connectionText = 'Disconnecting...';
        break;
      case BleConnectionState.error:
        connectionColor = Colors.red;
        connectionIcon = Icons.error;
        connectionText = 'Error';
        break;
      default:
        connectionColor = Colors.grey;
        connectionIcon = Icons.bluetooth;
        connectionText = 'Disconnected';
    }

    return Card(
      elevation: 8,
      margin: const EdgeInsets.all(16),
      child: Container(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(12),
          gradient: LinearGradient(
            colors: [connectionColor.withOpacity(0.2), connectionColor.withOpacity(0.1)],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
        ),
        padding: const EdgeInsets.all(20),
        child: Column(
          children: [
            AnimatedBuilder(
              animation: _connectionState == BleConnectionState.connecting || _connectionState == BleConnectionState.scanning 
                  ? _pulseAnimation : const AlwaysStoppedAnimation(1.0),
              builder: (context, child) {
                return Transform.scale(
                  scale: _connectionState == BleConnectionState.connecting || _connectionState == BleConnectionState.scanning 
                      ? _pulseAnimation.value : 1.0,
                  child: Icon(
                    connectionIcon,
                    size: 48,
                    color: connectionColor,
                  ),
                );
              },
            ),
            const SizedBox(height: 12),
            AutoSizeText(
              connectionText,
              style: TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.bold,
                color: connectionColor,
              ),
              maxLines: 1,
            ),
            const SizedBox(height: 16),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                Expanded(
                  child: ElevatedButton.icon(
                    onPressed: _isScanning || _connectionState == BleConnectionState.connected ? null : _scanAndConnect,
                    icon: _isScanning ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ) : const Icon(Icons.search),
                    label: Text(_isScanning ? 'Scanning...' : 'Connect'),
                    style: ElevatedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                    ),
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: ElevatedButton.icon(
                    onPressed: _connectionState == BleConnectionState.connected ? _disconnect : null,
                    icon: const Icon(Icons.bluetooth_disabled),
                    label: const Text('Disconnect'),
                    style: ElevatedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildMeasurementCard() {
    if (_latestMeasurement == null) {
      return Card(
        elevation: 8,
        margin: const EdgeInsets.symmetric(horizontal: 16),
        child: Container(
          height: 200,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            gradient: LinearGradient(
              colors: [Colors.grey.withOpacity(0.2), Colors.grey.withOpacity(0.1)],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ),
          ),
          child: const Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.monitor_weight, size: 64, color: Colors.grey),
                SizedBox(height: 16),
                AutoSizeText(
                  'No measurement data',
                  style: TextStyle(fontSize: 18, color: Colors.grey),
                  maxLines: 1,
                ),
                AutoSizeText(
                  'Step on the scale when connected',
                  style: TextStyle(fontSize: 14, color: Colors.grey),
                  maxLines: 1,
                ),
              ],
            ),
          ),
        ),
      );
    }

    final measurement = _latestMeasurement!;
    
    return Card(
      elevation: 8,
      margin: const EdgeInsets.symmetric(horizontal: 16),
      child: Container(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(12),
          gradient: const LinearGradient(
            colors: [Color(0xFF1976D2), Color(0xFF42A5F5)],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
        ),
        padding: const EdgeInsets.all(20),
        child: Column(
          children: [
            // Weight Display
            AnimatedBuilder(
              animation: _weightAnimation,
              builder: (context, child) {
                return Transform.scale(
                  scale: _weightAnimation.value,
                  child: Column(
                    children: [
                      const Icon(Icons.monitor_weight, size: 40, color: Colors.white),
                      const SizedBox(height: 8),
                      AutoSizeText(
                        '${measurement.weight.toStringAsFixed(2)}',
                        style: const TextStyle(
                          fontSize: 48,
                          fontWeight: FontWeight.bold,
                          color: Colors.white,
                        ),
                        maxLines: 1,
                      ),
                      const AutoSizeText(
                        'kg',
                        style: TextStyle(
                          fontSize: 24,
                          color: Colors.white70,
                        ),
                        maxLines: 1,
                      ),
                    ],
                  ),
                );
              },
            ),
            const SizedBox(height: 20),
            
            // Body Composition Grid
            if (measurement.bodyFat != null || measurement.water != null || 
                measurement.muscle != null || measurement.bone != null)
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: Colors.white.withOpacity(0.1),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Column(
                  children: [
                    const AutoSizeText(
                      'Body Composition',
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                        color: Colors.white,
                      ),
                      maxLines: 1,
                    ),
                    const SizedBox(height: 16),
                    GridView.count(
                      shrinkWrap: true,
                      physics: const NeverScrollableScrollPhysics(),
                      crossAxisCount: 2,
                      childAspectRatio: 2.5,
                      mainAxisSpacing: 8,
                      crossAxisSpacing: 8,
                      children: [
                        if (measurement.bodyFat != null)
                          _buildMetricTile('Body Fat', '${measurement.bodyFat!.toStringAsFixed(1)}%', Icons.fitness_center),
                        if (measurement.water != null)
                          _buildMetricTile('Water', '${measurement.water!.toStringAsFixed(1)}%', Icons.water_drop),
                        if (measurement.muscle != null)
                          _buildMetricTile('Muscle', '${measurement.muscle!.toStringAsFixed(1)}%', Icons.sports_gymnastics),
                        if (measurement.bone != null)
                          _buildMetricTile('Bone', '${measurement.bone!.toStringAsFixed(1)} kg', Icons.straighten),
                        if (measurement.visceralFat != null)
                          _buildMetricTile('Visceral Fat', '${measurement.visceralFat!.toStringAsFixed(1)}', Icons.warning),
                        if (measurement.impedance != null)
                          _buildMetricTile('Impedance', '${measurement.impedance!.toStringAsFixed(0)} Ω', Icons.electrical_services),
                      ],
                    ),
                  ],
                ),
              ),
            
            const SizedBox(height: 16),
            AutoSizeText(
              'Measured at ${measurement.dateTime.toString().substring(0, 19)}',
              style: const TextStyle(
                fontSize: 12,
                color: Colors.white70,
              ),
              maxLines: 1,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildMetricTile(String label, String value, IconData icon) {
    return Container(
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.1),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(icon, size: 16, color: Colors.white70),
          const SizedBox(height: 4),
          AutoSizeText(
            value,
            style: const TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.bold,
              color: Colors.white,
            ),
            maxLines: 1,
          ),
          AutoSizeText(
            label,
            style: const TextStyle(
              fontSize: 10,
              color: Colors.white70,
            ),
            maxLines: 1,
          ),
        ],
      ),
    );
  }

  Widget _buildHistoryCard() {
    return Card(
      elevation: 8,
      margin: const EdgeInsets.all(16),
      child: Container(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(12),
          gradient: LinearGradient(
            colors: [Colors.purple.withOpacity(0.2), Colors.purple.withOpacity(0.1)],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
        ),
        child: Column(
          children: [
            const Padding(
              padding: EdgeInsets.all(16),
              child: Row(
                children: [
                  Icon(Icons.history, color: Colors.purple),
                  SizedBox(width: 8),
                  AutoSizeText(
                    'Measurement History',
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                      color: Colors.purple,
                    ),
                    maxLines: 1,
                  ),
                ],
              ),
            ),
            SizedBox(
              height: 200,
              child: _measurements.isEmpty
                  ? const Center(
                      child: AutoSizeText(
                        'No measurements yet',
                        style: TextStyle(color: Colors.grey),
                        maxLines: 1,
                      ),
                    )
                  : ListView.builder(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      itemCount: _measurements.length,
                      itemBuilder: (context, index) {
                        final measurement = _measurements[index];
                        return Card(
                          margin: const EdgeInsets.only(bottom: 8),
                          child: ListTile(
                            leading: const CircleAvatar(
                              child: Icon(Icons.monitor_weight),
                            ),
                            title: AutoSizeText(
                              '${measurement.weight.toStringAsFixed(2)} kg',
                              style: const TextStyle(fontWeight: FontWeight.bold),
                              maxLines: 1,
                            ),
                            subtitle: AutoSizeText(
                              measurement.dateTime.toString().substring(0, 19),
                              maxLines: 1,
                            ),
                            trailing: measurement.bodyFat != null
                                ? AutoSizeText(
                                    '${measurement.bodyFat!.toStringAsFixed(1)}% fat',
                                    style: const TextStyle(color: Colors.grey),
                                    maxLines: 1,
                                  )
                                : null,
                          ),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildStatusCard() {
    return Card(
      elevation: 8,
      margin: const EdgeInsets.all(16),
      child: Container(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(12),
          gradient: LinearGradient(
            colors: [Colors.green.withOpacity(0.2), Colors.green.withOpacity(0.1)],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
        ),
        child: Column(
          children: [
            const Padding(
              padding: EdgeInsets.all(16),
              child: Row(
                children: [
                  Icon(Icons.info_outline, color: Colors.green),
                  SizedBox(width: 8),
                  AutoSizeText(
                    'Status Log',
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                      color: Colors.green,
                    ),
                    maxLines: 1,
                  ),
                ],
              ),
            ),
            SizedBox(
              height: 150,
              child: _statusLog.isEmpty
                  ? const Center(
                      child: AutoSizeText(
                        'No status messages',
                        style: TextStyle(color: Colors.grey),
                        maxLines: 1,
                      ),
                    )
                  : ListView.builder(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      itemCount: _statusLog.length,
                      itemBuilder: (context, index) {
                        return Padding(
                          padding: const EdgeInsets.only(bottom: 4),
                          child: AutoSizeText(
                            _statusLog[index],
                            style: const TextStyle(fontSize: 12),
                            maxLines: 2,
                          ),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const AutoSizeText(
          'Mi Scale 2 Reader',
          style: TextStyle(fontWeight: FontWeight.bold),
          maxLines: 1,
        ),
        centerTitle: true,
        elevation: 0,
        flexibleSpace: Container(
          decoration: const BoxDecoration(
            gradient: LinearGradient(
              colors: [Color(0xFF1976D2), Color(0xFF42A5F5)],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ),
          ),
        ),
      ),
      body: Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            colors: [
              Theme.of(context).colorScheme.surface,
              Theme.of(context).colorScheme.surface.withOpacity(0.8),
            ],
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
          ),
        ),
        child: SingleChildScrollView(
          child: Column(
            children: [
              _buildConnectionCard(),
              _buildMeasurementCard(),
              _buildHistoryCard(),
              _buildStatusCard(),
              const SizedBox(height: 20),
            ],
          ),
        ),
      ),
    );
  }
}