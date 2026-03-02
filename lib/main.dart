import 'dart:async';
import 'dart:convert';
import 'package:flutter/services.dart';
import 'dart:io';
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:cpay_sdk_plugin/cpay_sdk_plugin.dart';
import 'package:http/http.dart' as http;
import 'package:uuid/uuid.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:permission_handler/permission_handler.dart';
import 'models/transaction_model.dart';
import 'success_result_screen.dart';
import 'error_result_screen.dart';
import 'wifi_sync_screen.dart';
import 'services/wifi_sync_service.dart';
import 'services/location_service.dart';
import 'services/mqtt_service.dart';
import 'models/gps_data_model.dart';
import 'services/data_sync_service.dart';
import 'services/database_helper.dart';
import 'package:sqflite/sqflite.dart';

import 'package:mobile_scanner/mobile_scanner.dart';

import 'package:wakelock_plus/wakelock_plus.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await WakelockPlus.enable();
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'TapAndGo POC',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.deepPurple),
        useMaterial3: true,
      ),
      home: const WelcomeScreen(),
    );
  }
}

class WelcomeScreen extends StatefulWidget {
  const WelcomeScreen({super.key});

  @override
  State<WelcomeScreen> createState() => _WelcomeScreenState();
}

class _WelcomeScreenState extends State<WelcomeScreen>
    with WidgetsBindingObserver {
  final _cpaySdkPlugin = CpaySdkPlugin();

  // Prevent auto sync from running again when returning to this screen
  static bool _hasAutoSynced = false;

  // EMV Payment Channel
  static const MethodChannel _emvPaymentChannel = MethodChannel(
    'com.example.tapandgo_poc/emv_payment',
  );

  // Transaction State
  final Map<String, PendingTransaction> _pendingTransactions = {};
  final Uuid _uuid = const Uuid();
  static const String _storageKey = 'pending_transactions';
  bool _isProcessing = false;
  bool _isLoading = false;

  // Background Scanning State
  bool _isBackgroundScanningActive = false;
  bool _hasCamera = false;

  StreamSubscription<Object?>? _qrSubscription;
  StreamSubscription<bool>? _nfcSubscription;
  MobileScannerController? _mobileScannerController;

  // WiFi Sync for pending transactions
  final WifiSyncService _syncService = WifiSyncService();
  final LocationService _locationService = LocationService();
  final DatabaseHelper _dbHelper = DatabaseHelper();
  StreamSubscription<PendingTransactionSync>? _pendingSyncSubscription;

  // MQTT Service for GPS
  final MqttService _mqttService = MqttService();
  StreamSubscription<GpsData>? _gpsSubscription;
  GpsData? _currentGpsData;

  String _plateNumber = '';
  String _timeString = '00:00';
  String _currentStation = 'กำลังค้นหาสถานี...';
  Timer? _timer;

  Widget _buildLoadingUI() {
    return Container(
      width: double.infinity,
      color: Colors.white,
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Container(
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              color: Colors.blue.shade50,
              shape: BoxShape.circle,
            ),
            child: Icon(
              Icons.directions_bus_filled_rounded,
              size: 80,
              color: Colors.orange.shade800,
            ),
          ),
          const SizedBox(height: 24),
          const Text(
            'ขสมก. BMTA',
            style: TextStyle(
              color: Color(0xFF0D47A1),
              fontSize: 28,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 16),
          const Text(
            'กำลังประมวลผล...',
            style: TextStyle(
              color: Color(0xFF64B5F6),
              fontSize: 18,
              fontWeight: FontWeight.w500,
            ),
          ),
          const SizedBox(height: 40),
          const SizedBox(
            width: 40,
            height: 40,
            child: CircularProgressIndicator(
              strokeWidth: 4,
              valueColor: AlwaysStoppedAnimation<Color>(Color(0xFF0D47A1)),
            ),
          ),
        ],
      ),
    );
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      // Check camera availability before creating controller
      await _checkCameraAvailability();

      await _loadPlateNumber();
      _loadPendingTransactions();
      _requestAllPermissions();
      _setupPendingSyncListener();
      _updateTime();
      _timer = Timer.periodic(const Duration(seconds: 1), (_) => _updateTime());

      // Set up MQTT GPS listener
      _gpsSubscription = _mqttService.gpsStream.listen((gpsData) async {
        if (!mounted) return;

        setState(() {
          _currentGpsData = gpsData;
        });

        // Update current station based on new GPS data
        if (gpsData.lat != 0.0 && gpsData.lng != 0.0) {
          try {
            final nearestStop = await _dbHelper.getNearestBusStop(
              gpsData.lat,
              gpsData.lng,
            );

            if (mounted) {
              setState(() {
                _currentStation = nearestStop?.busstopDesc ?? 'ไม่พบข้อมูลป้าย';
              });
            }
          } catch (e) {
            debugPrint('[DEBUG] ❌ Error finding nearest stop for UI: $e');
            if (mounted) {
              setState(() {
                _currentStation = 'ระบุตำแหน่งไม่ได้';
              });
            }
          }
        }
      });

      // Initialize Data Sync only once per session
      if (!_hasAutoSynced) {
        _hasAutoSynced = true;
        await _syncData();
      }
    });
  }

  Future<void> _checkCameraAvailability() async {
    const cameraChannel = MethodChannel(
      'com.example.tapandgo_poc/camera_check',
    );
    try {
      final cameraCount = await cameraChannel.invokeMethod('checkCamera') ?? 0;
      _hasCamera = cameraCount > 0;
    } catch (e) {
      debugPrint('Camera check failed: $e');
      _hasCamera = false;
    }

    if (_hasCamera) {
      _mobileScannerController = MobileScannerController(
        detectionSpeed: DetectionSpeed.noDuplicates,
        facing: CameraFacing.front,
        formats: [BarcodeFormat.qrCode],
      );
    } else {
      debugPrint('[DEBUG] ⚠️ No camera found, MobileScanner disabled');
    }

    if (mounted) setState(() {});
  }

  Future<void> _syncData() async {
    final syncService = DataSyncService();
    // Use the stored plate number if available, otherwise empty string
    syncService.syncAllData(
      plateNo: _plateNumber.isNotEmpty ? _plateNumber : '',
    );
  }

  void _setupPendingSyncListener() {
    // Listen for status changes to update UI (WiFi icon)
    _syncService.onStatusChanged.listen((_) {
      if (mounted) setState(() {});
    });

    _pendingSyncSubscription = _syncService.onPendingSyncReceived.listen((
      sync,
    ) {
      debugPrint('📥 Received pending sync: ${sync.aid}');
      if (sync.isRemove) {
        // Remove from pending transactions (after Tap Out)
        setState(() {
          _pendingTransactions.remove(sync.aid);
        });
        _savePendingTransactions();
        debugPrint('🗑️ Removed pending transaction for ${sync.aid}');
      } else {
        // Add to pending transactions (after Tap In from another device)
        final pending = PendingTransaction(
          aid: sync.aid,
          tapInTime: sync.tapInTime,
          tapInLoc: TransactionLocation(lat: sync.tapInLat, lng: sync.tapInLng),
          routeId: sync.routeId,
        );
        setState(() {
          _pendingTransactions[sync.aid] = pending;
        });
        _savePendingTransactions();
        debugPrint('✅ Added pending transaction for ${sync.aid}');
      }
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    debugPrint('App Lifecycle State: $state');

    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      _stopBackgroundScanning();
    } else if (state == AppLifecycleState.resumed) {
      // Only start if not already active
      if (!_isBackgroundScanningActive) {
        _startBackgroundScanning();
      }
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _timer?.cancel();
    _pendingSyncSubscription?.cancel();
    _gpsSubscription?.cancel();
    _mqttService.disconnect();
    _stopBackgroundScanning();
    _mobileScannerController?.dispose();
    super.dispose();
  }

  // ============ Permission Handling ============
  Future<void> _requestAllPermissions() async {
    // Cleanup NFC only (camera lifecycle is managed by MobileScanner widget)
    debugPrint('Cleaning up any existing sessions...');
    try {
      await _cpaySdkPlugin.stopNfcPolling();
    } catch (e) {
      debugPrint('Cleanup error (can be ignored): $e');
    }

    await Future.delayed(const Duration(milliseconds: 300));

    // Request all permissions at once
    final statuses = await [
      Permission.camera,
      Permission.location,
      Permission.storage,
    ].request();

    debugPrint('Permissions status: $statuses');

    // Handle Camera Logic
    final cameraStatus = statuses[Permission.camera];
    if (cameraStatus != null && cameraStatus.isGranted) {
      await _startBackgroundScanning();
    } else if (cameraStatus != null && cameraStatus.isPermanentlyDenied) {
      if (mounted) _showPermissionDeniedDialog('กล้อง');
    } else {
      debugPrint('Camera denied, starting NFC only');
      await _startNfcPollingOnly();
    }

    // Handle Location Logic (Optional: just log for now as it is used on demand)
    final locationStatus = statuses[Permission.location];
    if (locationStatus != null && !locationStatus.isGranted) {
      debugPrint('Location permission denied');
    }
  }

  void _showPermissionDeniedDialog(String permissionName) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('ต้องการ Permission $permissionName'),
        content: Text(
          'แอปต้องการ Permission $permissionName เพื่อทำงาน กรุณาไปที่ Settings เพื่อเปิด Permission',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('ภายหลัง'),
          ),
          ElevatedButton(
            onPressed: () {
              Navigator.pop(context);
              openAppSettings();
            },
            child: const Text('ไปที่ Settings'),
          ),
        ],
      ),
    );
  }

  // ============ Background Scanning ============
  Future<void> _startBackgroundScanning() async {
    if (_isBackgroundScanningActive) {
      debugPrint('Background scanning already active, skipping...');
      return;
    }

    debugPrint('Starting background scanning...');
    _isBackgroundScanningActive = true;

    // Start Background QR Scan with retry logic
    await _startQrScanWithRetry();

    // Start Background NFC Polling
    await _startNfcPollingOnly();
  }

  Future<void> _startQrScanWithRetry({int retries = 3}) async {
    if (!_hasCamera || _mobileScannerController == null) {
      debugPrint('[DEBUG] ⚠️ No camera, skipping QR scan start');
      return;
    }
    try {
      await _mobileScannerController!.start();
      debugPrint('Mobile Scanner started');

      _qrSubscription?.cancel();
      _qrSubscription = _mobileScannerController!.barcodes.listen((capture) {
        for (final barcode in capture.barcodes) {
          if (barcode.rawValue != null) {
            print(
              '********** BEACON: QR Detected: ${barcode.rawValue} **********',
            );
            debugPrint('QR Code Detected: ${barcode.rawValue}');
            _handleQrDetected(barcode.rawValue!);
            break; // Handle only one at a time
          }
        }
      });
    } catch (e) {
      debugPrint('Failed to start Mobile Scanner: $e');
    }
  }

  Future<void> _startNfcPollingOnly() async {
    try {
      final nfcStarted = await _cpaySdkPlugin.startNfcPolling(intervalMs: 500);
      debugPrint('NFC Polling started: $nfcStarted');

      _nfcSubscription?.cancel();
      _nfcSubscription = _cpaySdkPlugin.onNfcCardDetected.listen((cardPresent) {
        if (cardPresent) {
          print('********** BEACON: NFC Card Detected! **********');
          debugPrint('NFC Card Detected!');
          _handleNfcDetected();
        }
      });
    } catch (e) {
      debugPrint('Failed to start NFC polling: $e');
    }
  }

  Future<void> _stopBackgroundScanning() async {
    if (!_isBackgroundScanningActive) return;

    debugPrint('Stopping background scanning...');
    _isBackgroundScanningActive = false;

    await _qrSubscription?.cancel();
    _qrSubscription = null;

    await _nfcSubscription?.cancel();
    _nfcSubscription = null;

    try {
      // await _cpaySdkPlugin.stopQrScan(); // Removed cpay QR stop
      await _mobileScannerController?.stop();
      await _cpaySdkPlugin.stopNfcPolling();
    } catch (e) {
      debugPrint('Error stopping background scanning: $e');
    }
  }

  // ============ Event Handlers ============
  Future<void> _handleQrDetected(String qrCode) async {
    if (_isProcessing || _isLoading) return;

    _isProcessing = true;

    try {
      await _cpaySdkPlugin.beep();
    } catch (e) {
      debugPrint('Beep Error: $e');
    }

    if (mounted) {
      setState(() {
        _isLoading = true;
      });
    }

    await _processQrString(qrCode);
  }

  Future<void> _handleNfcDetected() async {
    if (_isProcessing || _isLoading) return;

    _isProcessing = true;

    if (mounted) {
      setState(() {
        _isLoading = true;
      });
    }

    String cardId;
    try {
      final emvData = await _cpaySdkPlugin.readCardEmv().timeout(
        const Duration(milliseconds: 500),
        onTimeout: () => null,
      );
      if (emvData != null && emvData.isNotEmpty) {
        cardId = 'CARD-${emvData.hashCode}';
      } else {
        cardId = 'TEST-CARD-1234';
      }
    } catch (e) {
      debugPrint('Read EMV Failed: $e');
      cardId = 'TEST-CARD-1234';
    }

    final nfcData = QrData(aid: cardId, bal: 100.00);

    if (_pendingTransactions.containsKey(nfcData.aid)) {
      await _handleTapOut(nfcData);
    } else {
      _handleTapIn(nfcData);
    }
  }

  // ============ Shared Logic ============
  Future<void> _loadPlateNumber() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final savedPlate = prefs.getString('plate_number');
      if (savedPlate != null && mounted) {
        setState(() {
          _plateNumber = savedPlate;
        });
      }

      // Automatically show an alert if plate number is missing
      if ((savedPlate == null || savedPlate.isEmpty) && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('กรุณากำหนดทะเบียนรถ (Plate Number) ในหน้าตั้งค่า'),
            backgroundColor: Colors.orange,
            duration: Duration(seconds: 5),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }

      // Connect to MQTT when the app starts, regardless of plate number check
      // It will just maintain connection but not subscribe to GPS topic until plate number is set
      _mqttService.connect(_plateNumber);
    } catch (e) {
      debugPrint('Error loading plate number: $e');
      _mqttService.connect(_plateNumber);
    }
  }

  void _updateTime() {
    final now = DateTime.now();
    final hour = now.hour.toString().padLeft(2, '0');
    final minute = now.minute.toString().padLeft(2, '0');
    if (mounted) {
      setState(() {
        _timeString = '$hour:$minute';
      });
    }
  }

  Future<void> _loadPendingTransactions() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final String? jsonString = prefs.getString(_storageKey);
      if (jsonString != null) {
        final Map<String, dynamic> decoded = jsonDecode(jsonString);
        if (mounted) {
          setState(() {
            decoded.forEach((key, value) {
              _pendingTransactions[key] = PendingTransaction.fromJson(value);
            });
          });
        }
      }
    } catch (e) {
      debugPrint('Error loading pending transactions: $e');
    }
  }

  Future<void> _savePendingTransactions() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final data = _pendingTransactions.map(
        (key, value) => MapEntry(key, value.toJson()),
      );
      await prefs.setString(_storageKey, jsonEncode(data));
    } catch (e) {
      debugPrint('Error saving pending transactions: $e');
    }
  }

  Future<void> _processQrString(String rawString) async {
    try {
      QrData qrData;
      try {
        final Map<String, dynamic> data = jsonDecode(rawString);
        qrData = QrData.fromJson(data);
      } catch (_) {
        debugPrint('QR is not JSON, using raw string as ID');
        qrData = QrData(aid: rawString, bal: 0.0);
      }

      if (_pendingTransactions.containsKey(qrData.aid)) {
        await _handleTapOut(qrData);
      } else {
        await _handleTapIn(qrData);
      }
    } catch (e) {
      debugPrint('QR Processing Error: $e');
      _isProcessing = false;
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
      }
    }
  }

  // ============ Tap In / Tap Out Logic ============
  Future<void> _handleTapIn(QrData qrData) async {
    // Get current location (from MQTT GPS)
    var lat = _currentGpsData?.lat ?? 0.0;
    var lng = _currentGpsData?.lng ?? 0.0;

    if (lat != 0.0 && lng != 0.0) {
      debugPrint('[DEBUG] 📍 Using GPS from MQTT: lat=$lat, lng=$lng');
    } else {
      debugPrint('[DEBUG] ⚠️ GPS not found or 0.0, using Mock Location');
    }

    // Get routeId for consistent route filtering
    final routeId = await _dbHelper.getFirstRouteId();
    debugPrint('[DEBUG] 🛣️ Using RouteId: $routeId');

    // DEBUG: Check DB content
    final db = await _dbHelper.database;
    final routeCount = Sqflite.firstIntValue(
      await db.rawQuery('SELECT COUNT(*) FROM route_details'),
    );
    final routeCountForId = Sqflite.firstIntValue(
      await db.rawQuery(
        'SELECT COUNT(*) FROM route_details WHERE routeId = ?',
        [routeId ?? 0],
      ),
    );
    debugPrint(
      '[DEBUG] 📊 Route Details Total: $routeCount, For RouteId $routeId: $routeCountForId',
    );

    // DEBUG: Check if we have price ranges
    final count = Sqflite.firstIntValue(
      await db.rawQuery('SELECT COUNT(*) FROM price_ranges'),
    );
    debugPrint('[DEBUG] 📊 Price Ranges Count: $count');

    final tapInTime = _currentGpsData?.rec ?? DateTime.now().toUtc();

    final pending = PendingTransaction(
      aid: qrData.aid,
      tapInTime: tapInTime,
      tapInLoc: TransactionLocation(lat: lat, lng: lng),
      routeId: routeId,
    );

    setState(() {
      _pendingTransactions[qrData.aid] = pending;
    });
    await _savePendingTransactions();

    // Broadcast to other devices via WiFi Sync
    if (_syncService.isRunning) {
      final pendingSync = PendingTransactionSync(
        aid: qrData.aid,
        tapInTime: pending.tapInTime,
        tapInLat: pending.tapInLoc.lat,
        tapInLng: pending.tapInLoc.lng,
        isRemove: false,
        routeId: routeId,
      );
      await _syncService.sendPendingSync(pendingSync);
      debugPrint('[DEBUG] 📤 Broadcasted Tap In for ${qrData.aid}');
    }

    // Find nearest bus stop
    String busStopName = 'ไม่พบข้อมูลป้าย';
    try {
      final nearestStop = await _dbHelper.getNearestBusStop(
        lat,
        lng,
        routeId: routeId,
      );
      if (nearestStop != null) {
        busStopName = nearestStop.busstopDesc;
        debugPrint('[DEBUG] 📍 Nearest Stop (Tap In): $busStopName');
      }
    } catch (e) {
      debugPrint('[DEBUG] ❌ Error finding nearest stop: $e');
      busStopName = 'ระบุตำแหน่งไม่ได้';
    }

    _showResultDialog(
      busStopName,
      'บันทึกจุดขึ้นรถแล้ว',
      isSuccess: true,
      price: null,
      topStatus: 'เริ่มต้นเดินทาง',
      instruction: 'กรุณาแตะบัตรอีกครั้งเมื่อลงรถ',
    );
  }

  Future<void> _handleTapOut(QrData qrData) async {
    // Check internet connectivity before Tap Out
    final hasInternet = await _checkInternetConnection();
    if (!hasInternet) {
      _showResultDialog(
        'ไม่มีสัญญาณอินเทอร์เน็ต',
        'กรุณาเชื่อมต่ออินเทอร์เน็ตก่อนลงรถ',
        isSuccess: false,
      );
      return;
    }

    final pending = _pendingTransactions[qrData.aid]!;
    final tapOutTime = _currentGpsData?.rec ?? DateTime.now().toUtc();

    // Get current location for Tap Out (from MQTT GPS)
    var lat = _currentGpsData?.lat ?? 0.0;
    var lng = _currentGpsData?.lng ?? 0.0;

    if (lat != 0.0 && lng != 0.0) {
      debugPrint(
        '[DEBUG] 📍 Using GPS from MQTT (Tap Out): lat=$lat, lng=$lng',
      );
    } else {
      debugPrint('[DEBUG] ⚠️ GPS not found (Tap Out)');
    }

    debugPrint('[DEBUG] 🔎 TapOut Coords Used: $lat, $lng');
    debugPrint(
      '[DEBUG] 🔎 TapIn Coords from Pending: ${pending.tapInLoc.lat}, ${pending.tapInLoc.lng}',
    );

    final tapOutLoc = TransactionLocation(lat: lat, lng: lng);

    final txnItem = TransactionItem(
      txnId: _uuid.v4(),
      assetId: qrData.aid,
      assetType: 'QR',
      tapInTime: pending.tapInTime.toUtc().toIso8601String(),
      tapInLoc: pending.tapInLoc,
      tapOutTime: tapOutTime.toUtc().toIso8601String(),
      tapOutLoc: tapOutLoc,
    );

    final payload = TransactionRequest(
      deviceId: 'ANDROID_POS_01',
      plateNo: _plateNumber,
      transactions: [txnItem],
    );

    await _submitTransaction(payload, qrData.aid, routeId: pending.routeId);
  }

  /// Check if device has internet connection
  Future<bool> _checkInternetConnection() async {
    try {
      final result = await InternetAddress.lookup(
        'google.com',
      ).timeout(const Duration(seconds: 3));
      return result.isNotEmpty && result[0].rawAddress.isNotEmpty;
    } catch (_) {
      return false;
    }
  }

  Future<void> _submitTransaction(
    TransactionRequest payload,
    String aid, {
    int? routeId,
  }) async {
    final url = Uri.parse(
      'https://tng-platform-dev.atlasicloud.com/api/tng/tap/transactions',
    );
    try {
      final response = await http.post(
        url,
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode(payload.toJson()),
      );

      if (response.statusCode >= 200 && response.statusCode < 300) {
        setState(() {
          _pendingTransactions.remove(aid);
        });
        _savePendingTransactions();

        // Broadcast removal to other devices via WiFi Sync
        if (_syncService.isRunning) {
          final pendingSync = PendingTransactionSync(
            aid: aid,
            tapInTime: DateTime.now()
                .toUtc(), // Time doesn't matter for removal
            isRemove: true,
          );
          await _syncService.sendPendingSync(pendingSync);
          debugPrint('[DEBUG] 📤 Broadcasted Tap Out removal for $aid');
        }

        // Find nearest bus stop for Tap Out & Calculate Fare
        String busStopName = 'ไม่พบข้อมูลป้าย';
        String priceDisplay = 'ไม่พบราคา';

        try {
          // Use the location from the payload (which might be mocked)
          final firstTxn = payload.transactions.first;
          final lat = firstTxn.tapOutLoc.lat;
          final lng = firstTxn.tapOutLoc.lng;

          // 1. Get Tap Out Stop
          final tapOutStop = await _dbHelper.getNearestBusStop(
            lat,
            lng,
            routeId: routeId,
          );

          if (tapOutStop != null) {
            busStopName = tapOutStop.busstopDesc;
            debugPrint(
              '[DEBUG] 📍 Nearest Stop (Tap Out): $busStopName (Seq: ${tapOutStop.seq})',
            );

            // 2. Get Tap In Stop (using stored lat/lng from transaction payload)
            // We need to query DB again to get the sequence number
            final firstTxn = payload.transactions.first;
            final tapInStop = await _dbHelper.getNearestBusStop(
              firstTxn.tapInLoc.lat,
              firstTxn.tapInLoc.lng,
              routeId: routeId,
            );

            if (tapInStop != null) {
              debugPrint(
                '[DEBUG] 📍 Nearest Stop (Tap In): ${tapInStop.busstopDesc} (Seq: ${tapInStop.seq})',
              );

              // 3. Calculate Fare
              final fare = await _dbHelper.getFare(
                tapInStop.seq,
                tapOutStop.seq,
                routeId: routeId,
              );
              if (fare != null) {
                priceDisplay = '${fare.toStringAsFixed(2)} ฿';
                debugPrint('[DEBUG] 💰 Calculated Fare: $priceDisplay');

                // --- ARKE EMV PAYMENT INTEGRATION (BYPASSED) ---
                try {
                  debugPrint(
                    '[DEBUG] 💳 (BYPASSED) Skipping EMV Payment for $fare',
                  );
                  // FIXME: Uncomment When Ready to Enable Payment
                  /*
                  final result = await _emvPaymentChannel.invokeMethod(
                    'startPayment',
                    {
                      'amount': fare
                          .toDouble(), // Fare must be passed as Double
                    },
                  );
                  debugPrint('[DEBUG] ✅ Payment Success: $result');
                  */

                  _showResultDialog(
                    busStopName,
                    'ขอบคุณที่ใช้บริการ',
                    isSuccess: true,
                    isTapOut: true,
                    price: priceDisplay,
                    balance:
                        '475.00 ฿', // Should ideally come from real card/user balance
                    topStatus: 'ชำระเงินสำเร็จ (ทดสอบ)',
                    instruction: 'เดินทางปลอดภัย',
                  );
                } catch (e) {
                  debugPrint('[DEBUG] ❌ Payment Failed: $e');
                  _showResultDialog(
                    'ชำระเงินไม่สำเร็จ',
                    'เกิดข้อผิดพลาดในการตัดเงิน: ${e.toString()}',
                    isSuccess: false,
                  );
                }
                return; // End flow here since payment is handled
              } else {
                debugPrint(
                  '[DEBUG] ⚠️ No fare found for seq range: ${tapInStop.seq} - ${tapOutStop.seq}',
                );
              }
            } else {
              debugPrint('[DEBUG] ⚠️ Could not find Tap In stop details');
            }
          }
        } catch (e) {
          debugPrint('❌ Error finding nearest stop/fare: $e');
          busStopName = 'ระบุตำแหน่งไม่ได้';
        }

        // Fallback for when fare calculation fails
        _showResultDialog(
          busStopName,
          'ขอบคุณที่ใช้บริการ',
          isSuccess: true,
          isTapOut: true,
          price: priceDisplay,
          balance: '475.00 ฿',
          topStatus: 'บันทึกประวัติการเดินทาง',
          instruction: 'เดินทางปลอดภัย',
        );
      } else {
        _showResultDialog(
          'ทำรายการไม่สำเร็จ',
          'รหัสข้อผิดพลาด: ${response.statusCode}',
          isSuccess: false,
        );
      }
    } catch (e) {
      _showResultDialog('เกิดข้อผิดพลาด', '$e', isSuccess: false);
    }
  }

  void _showResultDialog(
    String title,
    String message, {
    required bool isSuccess,
    bool isTapOut = false,
    String? price,
    String? balance,
    String? topStatus,
    String? instruction,
  }) {
    if (!mounted) return;

    _stopBackgroundScanning();

    setState(() {
      _isLoading = false;
    });

    void handleDismiss(BuildContext ctx) {
      if (Navigator.of(ctx).canPop()) {
        Navigator.of(ctx).pop();
      }
      if (mounted) {
        setState(() {
          _isProcessing = false;
        });
        _startBackgroundScanning();
      }
    }

    if (isSuccess) {
      showDialog(
        context: context,
        barrierDismissible: false,
        useSafeArea: false,
        builder: (dialogContext) => Dialog.fullscreen(
          child: SuccessResultScreen(
            onDismiss: handleDismiss,
            title: title,
            message: message,
            price: price ?? (isTapOut ? '25.00 ฿' : null),
            balance: balance,
            isTapOut: isTapOut,
            topStatus: topStatus,
            instruction: instruction,
          ),
        ),
      );
    } else {
      showDialog(
        context: context,
        barrierDismissible: false,
        useSafeArea: false,
        builder: (dialogContext) => Dialog.fullscreen(
          child: ErrorResultScreen(
            onDismiss: handleDismiss,
            errorTitle: title,
            errorMessage: message,
          ),
        ),
      );
    }
  }

  // ============ UI Build ============
  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return Scaffold(
        backgroundColor: Colors.white,
        body: Stack(
          children: [
            // Hidden MobileScanner widget to keep controller active
            if (_hasCamera && _mobileScannerController != null)
              SizedBox(
                width: 1,
                height: 1,
                child: MobileScanner(
                  controller: _mobileScannerController!,
                  onDetect: (capture) {}, // Handled by listener
                ),
              ),
            _buildLoadingUI(),
          ],
        ),
      );
    }

    return Scaffold(
      body: Stack(
        children: [
          Container(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [const Color(0xFF1B5E20), const Color(0xFF0D47A1)],
              ),
            ),
            child: SafeArea(
              child: SizedBox(
                width: double.infinity,
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    return SingleChildScrollView(
                      child: ConstrainedBox(
                        constraints: BoxConstraints(
                          minHeight: constraints.maxHeight,
                        ),
                        child: IntrinsicHeight(
                          child: Column(
                            children: [
                              // Top Status Bar
                              Container(
                                width: double.infinity,
                                color: Colors.black.withOpacity(0.2),
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 16.0,
                                  vertical: 8.0,
                                ),
                                child: Row(
                                  children: [
                                    Expanded(
                                      child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          Text(
                                            'ขสมก. BMTA',
                                            style: const TextStyle(
                                              color: Colors.white,
                                              fontSize: 18,
                                              fontWeight: FontWeight.bold,
                                            ),
                                            overflow: TextOverflow.ellipsis,
                                          ),
                                          Text(
                                            _timeString,
                                            style: const TextStyle(
                                              color: Colors.white70,
                                              fontSize: 14,
                                              fontWeight: FontWeight.w500,
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                    Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        if (_syncService.isRunning) ...[
                                          Text(
                                            _syncService.currentRole ==
                                                    SyncRole.host
                                                ? 'Host'
                                                : 'Client',
                                            style: TextStyle(
                                              color: Colors.greenAccent,
                                              fontSize: 14,
                                              fontWeight: FontWeight.bold,
                                            ),
                                          ),
                                          SizedBox(width: 4),
                                          Icon(
                                            Icons.wifi,
                                            color: Colors.greenAccent,
                                            size: 20,
                                          ),
                                          SizedBox(width: 16),
                                        ],
                                        Text(
                                          'สัญญาณปกติ',
                                          style: TextStyle(
                                            color: Colors.greenAccent,
                                            fontSize: 14,
                                          ),
                                        ),
                                        SizedBox(width: 8),
                                        Icon(
                                          Icons.signal_cellular_4_bar,
                                          color: Colors.greenAccent,
                                          size: 20,
                                        ),
                                      ],
                                    ),
                                  ],
                                ),
                              ),

                              // Location Bar
                              Container(
                                width: double.infinity,
                                padding: const EdgeInsets.symmetric(
                                  vertical: 8,
                                  horizontal: 16,
                                ),
                                color: Colors.black.withOpacity(0.1),
                                child: Row(
                                  children: [
                                    Icon(
                                      Icons.location_on,
                                      color: Colors.pinkAccent,
                                      size: 20,
                                    ),
                                    SizedBox(width: 8),
                                    Text(
                                      'สถานีปัจจุบัน: $_currentStation',
                                      style: TextStyle(
                                        color: Colors.white,
                                        fontSize: 16,
                                        fontWeight: FontWeight.w500,
                                      ),
                                    ),
                                  ],
                                ),
                              ),

                              const Spacer(),

                              // Center Content - QR Preview
                              Container(
                                width: 200,
                                height: 200,
                                decoration: BoxDecoration(
                                  color: Colors.black,
                                  borderRadius: BorderRadius.circular(20),
                                  border: Border.all(
                                    color: Colors.white,
                                    width: 4,
                                  ),
                                  boxShadow: [
                                    BoxShadow(
                                      color: Colors.black.withOpacity(0.5),
                                      blurRadius: 10,
                                      spreadRadius: 2,
                                    ),
                                  ],
                                ),
                                child: ClipRRect(
                                  borderRadius: BorderRadius.circular(16),
                                  child: Stack(
                                    children: [
                                      if (_hasCamera &&
                                          _mobileScannerController != null)
                                        MobileScanner(
                                          controller: _mobileScannerController!,
                                          onDetect:
                                              (
                                                capture,
                                              ) {}, // Handled by listener
                                          fit: BoxFit.cover,
                                          errorBuilder: (context, error, child) {
                                            return Center(
                                              child: Column(
                                                mainAxisSize: MainAxisSize.min,
                                                children: [
                                                  const Icon(
                                                    Icons.error,
                                                    color: Colors.white,
                                                    size: 32,
                                                  ),
                                                  const SizedBox(height: 8),
                                                  Text(
                                                    'Error: ${error.errorCode}',
                                                    style: const TextStyle(
                                                      color: Colors.white,
                                                      fontSize: 12,
                                                    ),
                                                    textAlign: TextAlign.center,
                                                  ),
                                                ],
                                              ),
                                            );
                                          },
                                        )
                                      else
                                        Center(
                                          child: Icon(
                                            Icons.no_photography,
                                            color: Colors.white54,
                                            size: 64,
                                          ),
                                        ),
                                      Center(
                                        child: Icon(
                                          Icons.qr_code_scanner,
                                          size: 100,
                                          color: Colors.white.withOpacity(0.3),
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                              const SizedBox(height: 24),
                              const Text(
                                'กรุณาแตะบัตร',
                                style: TextStyle(
                                  color: Colors.white,
                                  fontSize: 32,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                              const SizedBox(height: 16),
                              const Text(
                                'แตะบัตรที่จุดอ่านเพื่อชำระเงิน',
                                style: TextStyle(
                                  color: Colors.white70,
                                  fontSize: 18,
                                ),
                              ),
                              const Spacer(),

                              // Bottom Status Indicators
                              Padding(
                                padding: const EdgeInsets.only(bottom: 16.0),
                                child: Row(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  children: [
                                    GestureDetector(
                                      onTap: _showEditPlateDialog,
                                      child: Container(
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 16,
                                          vertical: 8,
                                        ),
                                        decoration: BoxDecoration(
                                          color: Colors.black.withOpacity(0.3),
                                          borderRadius: BorderRadius.circular(
                                            20,
                                          ),
                                          border: Border.all(
                                            color: Colors.white54,
                                          ),
                                        ),
                                        child: Row(
                                          children: [
                                            const Icon(
                                              Icons.directions_bus,
                                              color: Colors.white,
                                              size: 20,
                                            ),
                                            const SizedBox(width: 8),
                                            Text(
                                              _plateNumber,
                                              style: const TextStyle(
                                                color: Colors.white,
                                                fontSize: 16,
                                                fontWeight: FontWeight.bold,
                                              ),
                                            ),
                                            const SizedBox(width: 8),
                                            const Icon(
                                              Icons.edit,
                                              color: Colors.white70,
                                              size: 16,
                                            ),
                                          ],
                                        ),
                                      ),
                                    ),
                                    const SizedBox(width: 16),

                                    Container(
                                      padding: const EdgeInsets.all(8),
                                      decoration: BoxDecoration(
                                        color: Colors.black.withOpacity(0.3),
                                        borderRadius: BorderRadius.circular(20),
                                      ),
                                      child: Row(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          _buildStatusIcon(
                                            Icons.qr_code_scanner,
                                            true,
                                          ),
                                          const SizedBox(width: 16),
                                          _buildStatusIcon(
                                            Icons.credit_card,
                                            true,
                                          ),
                                        ],
                                      ),
                                    ),
                                    const SizedBox(width: 16),
                                    // WiFi Sync Button
                                    GestureDetector(
                                      onTap: () {
                                        Navigator.of(context).push(
                                          MaterialPageRoute(
                                            builder: (_) =>
                                                const WifiSyncScreen(),
                                          ),
                                        );
                                      },
                                      child: Container(
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 12,
                                          vertical: 8,
                                        ),
                                        decoration: BoxDecoration(
                                          color: Colors.deepPurple.withOpacity(
                                            0.8,
                                          ),
                                          borderRadius: BorderRadius.circular(
                                            20,
                                          ),
                                          border: Border.all(
                                            color: Colors.white54,
                                          ),
                                        ),
                                        child: Row(
                                          mainAxisSize: MainAxisSize.min,
                                          children: const [
                                            Icon(
                                              Icons.wifi,
                                              color: Colors.white,
                                              size: 20,
                                            ),
                                            SizedBox(width: 6),
                                            Text(
                                              'Sync',
                                              style: TextStyle(
                                                color: Colors.white,
                                                fontSize: 14,
                                                fontWeight: FontWeight.bold,
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              const SizedBox(height: 10),
                            ],
                          ),
                        ),
                      ),
                    );
                  },
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildStatusIcon(IconData icon, bool isReady) {
    return Stack(
      alignment: Alignment.bottomRight,
      children: [
        Icon(icon, color: Colors.white70, size: 24),
        Container(
          width: 8,
          height: 8,
          decoration: BoxDecoration(
            color: isReady ? Colors.greenAccent : Colors.red,
            shape: BoxShape.circle,
            border: Border.all(color: Colors.black, width: 1),
          ),
        ),
      ],
    );
  }

  void _showEditPlateDialog() {
    final TextEditingController controller = TextEditingController(
      text: _plateNumber,
    );

    showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('แก้ไขหมายเลขทะเบียนรถ'),
          content: TextField(
            controller: controller,
            decoration: const InputDecoration(
              labelText: 'หมายเลขทะเบียน',
              hintText: 'ตัวอย่าง: 12-3456',
              border: OutlineInputBorder(),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('ยกเลิก'),
            ),
            ElevatedButton(
              onPressed: () async {
                if (controller.text.isNotEmpty &&
                    controller.text != _plateNumber) {
                  setState(() {
                    _plateNumber = controller.text;
                  });
                  final prefs = await SharedPreferences.getInstance();
                  await prefs.setString('plate_number', _plateNumber);

                  // Connect MQTT to the new plate number
                  _mqttService.connect(_plateNumber);

                  // Trigger a new data sync for the new plate number
                  if (mounted) {
                    Navigator.of(context).pop();
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: Text('กำลังอัปเดตข้อมูลสำหรับรถคันใหม่...'),
                      ),
                    );
                    await _syncData();
                  }
                } else {
                  if (mounted) Navigator.of(context).pop();
                }
              },
              child: const Text('บันทึก'),
            ),
          ],
        );
      },
    );
  }
}
