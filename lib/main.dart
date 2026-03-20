import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'package:flutter/services.dart';
import 'dart:io';
import 'dart:ui';
import 'package:flutter/material.dart';
// import 'package:cpay_sdk_plugin/cpay_sdk_plugin.dart'; // Handled by PosService
import 'package:http/http.dart' as http;
import 'package:uuid/uuid.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:permission_handler/permission_handler.dart';
import 'models/transaction_model.dart';
import 'success_result_screen.dart';
import 'services/pos_service.dart';
import 'error_result_screen.dart';
import 'wifi_sync_screen.dart'; // SettingsScreen
import 'services/wifi_sync_service.dart';
import 'services/location_service.dart';
import 'services/mqtt_service.dart';
import 'models/gps_data_model.dart';
import 'services/data_sync_service.dart';
import 'services/database_helper.dart';
import 'services/emv_transaction_service.dart';
import 'models/emv_transaction_model.dart';
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
  final _posService = PosService();
  // final _cpaySdkPlugin = CpaySdkPlugin(); // Refactored into PosService

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
  final EmvTransactionService _emvTransactionService = EmvTransactionService();
  StreamSubscription<PendingTransactionSync>? _pendingSyncSubscription;

  // MQTT Service for GPS
  final MqttService _mqttService = MqttService();
  StreamSubscription<GpsData>? _gpsSubscription;
  GpsData? _currentGpsData;

  // GPS History — เก็บ record ล่าสุดเพื่อ lookup ด้วยเวลา
  static const int _maxGpsHistory = 500;
  final List<GpsData> _gpsHistory = [];

  // Pending EMV Requests — รอ GPS ที่เวลาเลย tapOutTime ก่อนส่ง
  final List<_PendingEmvRequest> _pendingEmvRequests = [];

  // Pending TapIn GPS — รอ GPS ที่เวลาเลย tapInTime ก่อน resolve
  final List<_PendingTapInGps> _pendingTapInGpsQueue = [];
  // Resolved TapIn GPS — เก็บ GPS ที่ resolve แล้วไว้ใช้ตอนส่ง EMV
  final Map<String, GpsData> _resolvedTapInGps = {};

  /// หา GPS record ที่ใกล้เคียง targetTime ที่สุดจาก history
  GpsData? _findClosestGps(DateTime targetTime) {
    if (_gpsHistory.isEmpty) return null;

    GpsData? closest;
    int smallestDiff = 0x7FFFFFFFFFFFFFFF; // max int

    for (final gps in _gpsHistory) {
      if (gps.rec == null) continue;
      final diff =
          (gps.rec!.millisecondsSinceEpoch - targetTime.millisecondsSinceEpoch)
              .abs();
      if (diff < smallestDiff) {
        smallestDiff = diff;
        closest = gps;
      }
    }
    return closest;
  }

  /// คำนวณระยะห่างระหว่าง 2 จุด (เมตร) ด้วย Haversine formula
  double _haversineDistance(
    double lat1,
    double lng1,
    double lat2,
    double lng2,
  ) {
    const R = 6371000.0; // รัศมีโลก (เมตร)
    final dLat = (lat2 - lat1) * 3.141592653589793 / 180;
    final dLng = (lng2 - lng1) * 3.141592653589793 / 180;
    final a =
        sin(dLat / 2) * sin(dLat / 2) +
        cos(lat1 * 3.141592653589793 / 180) *
            cos(lat2 * 3.141592653589793 / 180) *
            sin(dLng / 2) *
            sin(dLng / 2);
    final c = 2 * atan2(sqrt(a), sqrt(1 - a));
    return R * c;
  }

  /// Format DateTime to UTC ISO 8601
  String _formatDateTime(DateTime dt) {
    return dt.toUtc().toIso8601String();
  }

  String _plateNumber = '';
  String _timeString = '00:00';
  String _currentStation = 'กำลังค้นหาสถานี...';
  int? _currentStationSeq;
  double? _currentStationDistance;
  String _nextStation = '';
  int? _nextStationSeq;
  double? _nextStationDistance;
  int? _activeRouteId;
  bool _isGpsUpdating = false;
  Timer? _gpsUpdateTimer;
  bool _isPlateChanging = false;
  String _plateChangeStatus = '';
  List<String> _plateChangeErrors = [];
  bool _isAppDisabled = false;
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

      // Initialize POS Service FIRST (Detect Device: Arke or CPay)
      await _posService.init();

      // Then start scanning (uses device type from PosService)
      await _requestAllPermissions();
      _setupPendingSyncListener();
      _updateTime();
      _timer = Timer.periodic(const Duration(seconds: 1), (_) => _updateTime());

      // Set up MQTT GPS listener
      _gpsSubscription = _mqttService.gpsStream.listen((gpsData) async {
        if (!mounted) return;

        setState(() {
          _currentGpsData = gpsData;
        });

        // บันทึก GPS history
        _gpsHistory.add(gpsData);
        if (_gpsHistory.length > _maxGpsHistory) {
          _gpsHistory.removeAt(0);
        }
        debugPrint(
          '[EMV] 📡 GPS received: rec=${gpsData.rec}, lat=${gpsData.lat}, lng=${gpsData.lng}, '
          'box=${gpsData.box}, spd=${gpsData.spd} | history size=${_gpsHistory.length}',
        );

        // ตรวจสอบ pending EMV requests — ถ้า GPS rec เลยเวลา tapOut แล้วให้ส่ง EMV transaction
        if (_pendingEmvRequests.isNotEmpty && gpsData.rec != null) {
          debugPrint(
            '[EMV] 🔍 Checking ${_pendingEmvRequests.length} pending EMV request(s)...',
          );
          final toRemove = <_PendingEmvRequest>[];
          for (final pending in _pendingEmvRequests) {
            final isPast = gpsData.rec!.isAfter(pending.tapOutTime);
            debugPrint(
              '[EMV]   └─ tapOutTime=${pending.tapOutTime}, gpsRec=${gpsData.rec}, isPast=$isPast',
            );
            if (isPast) {
              debugPrint(
                '[EMV] ✅ GPS time passed tapOutTime! Firing EMV transaction...',
              );
              _submitEmvTransaction(pending.payload, routeId: pending.routeId);
              toRemove.add(pending);
            }
          }
          for (final r in toRemove) {
            _pendingEmvRequests.remove(r);
            final aid = r.payload.transactions.first.assetId;
            _resolvedTapInGps.remove(aid);
            debugPrint(
              '[EMV] 🗑️ Cleaned up resolved TapIn GPS for $aid | remaining pending=${_pendingEmvRequests.length}',
            );
          }
        }

        // ตรวจสอบ pending TapIn GPS — ถ้า GPS rec เลยเวลา tapInTime แล้วให้ resolve
        if (_pendingTapInGpsQueue.isNotEmpty && gpsData.rec != null) {
          debugPrint(
            '[EMV] 🔍 Checking ${_pendingTapInGpsQueue.length} pending TapIn GPS resolution(s)...',
          );
          final toRemove = <_PendingTapInGps>[];
          for (final pending in _pendingTapInGpsQueue) {
            final isPast = gpsData.rec!.isAfter(pending.tapInTime);
            debugPrint(
              '[EMV]   └─ aid=${pending.aid}, tapInTime=${pending.tapInTime}, gpsRec=${gpsData.rec}, isPast=$isPast',
            );
            if (isPast) {
              final closestGps = _findClosestGps(pending.tapInTime);
              if (closestGps != null) {
                _resolvedTapInGps[pending.aid] = closestGps;
                debugPrint(
                  '[EMV] ✅ TapIn GPS resolved for ${pending.aid}: '
                  'closestGpsTime=${closestGps.rec}, lat=${closestGps.lat}, lng=${closestGps.lng}, '
                  'box=${closestGps.box}, spd=${closestGps.spd}',
                );
              } else {
                debugPrint(
                  '[EMV] ⚠️ No GPS found in history for TapIn ${pending.aid}',
                );
              }
              toRemove.add(pending);
            }
          }
          _pendingTapInGpsQueue.removeWhere((e) => toRemove.contains(e));
          if (toRemove.isNotEmpty) {
            debugPrint(
              '[EMV] 📋 Resolved ${toRemove.length} TapIn GPS | remaining queue=${_pendingTapInGpsQueue.length} | total resolved=${_resolvedTapInGps.length}',
            );
          }
        }

        // Update current station based on new GPS data
        if (gpsData.lat != 0.0 && gpsData.lng != 0.0) {
          // Flash GPS update indicator
          if (mounted) {
            setState(() => _isGpsUpdating = true);
            _gpsUpdateTimer?.cancel();
            _gpsUpdateTimer = Timer(const Duration(seconds: 2), () {
              if (mounted) setState(() => _isGpsUpdating = false);
            });
          }
          try {
            final nearestStop = await _dbHelper.getNearestBusStop(
              gpsData.lat,
              gpsData.lng,
            );

            if (mounted) {
              setState(() {
                if (nearestStop != null) {
                  _currentStation = nearestStop.busstopDesc;
                  _currentStationSeq = nearestStop.seq;
                  _currentStationDistance = _haversineDistance(
                    gpsData.lat,
                    gpsData.lng,
                    nearestStop.latitude,
                    nearestStop.longitude,
                  );
                } else {
                  _currentStation = 'ไม่พบข้อมูลป้าย';
                  _currentStationSeq = null;
                  _currentStationDistance = null;
                }
              });
            }

            // Fetch next station
            if (nearestStop != null) {
              final routeId = await _dbHelper.getFirstRouteId();
              final nextStop = await _dbHelper.getNextBusStop(
                nearestStop.seq,
                routeId: routeId,
              );
              if (mounted) {
                setState(() {
                  if (nextStop != null) {
                    _nextStation = nextStop.busstopDesc;
                    _nextStationSeq = nextStop.seq;
                    _nextStationDistance = _haversineDistance(
                      gpsData.lat,
                      gpsData.lng,
                      nextStop.latitude,
                      nextStop.longitude,
                    );
                  } else {
                    _nextStation = 'สิ้นสุดเส้นทาง';
                    _nextStationSeq = null;
                    _nextStationDistance = null;
                  }
                });
              }
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
    final result = await syncService.syncAllData(
      plateNo: _plateNumber.isNotEmpty ? _plateNumber : '',
    );
    if (mounted) {
      setState(() {
        _activeRouteId = result.activeRouteId;
      });
    }
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
    _posService.dispose();
    _mobileScannerController?.dispose();
    super.dispose();
  }

  // ============ Permission Handling ============
  Future<void> _requestAllPermissions() async {
    // Cleanup NFC only (camera lifecycle is managed by MobileScanner widget)
    debugPrint('Cleaning up any existing sessions...');
    try {
      await _posService.stopNfcPolling();
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
    await _startNfcPollingUnified();
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

  Future<void> _startNfcPollingUnified() async {
    try {
      await _posService.startNfcPolling();
      debugPrint('Unified NFC Polling started');

      _nfcSubscription?.cancel();
      _nfcSubscription = _posService.onNfcCardDetected.listen((cardPresent) {
        if (cardPresent) {
          debugPrint('NFC Card Detected via PosService!');
          _handleNfcDetected();
        }
      });
    } catch (e) {
      debugPrint('Failed to start NFC polling: $e');
    }
  }

  Future<void> _startNfcPollingOnly() async {
    // Legacy method - redirecting to unified
    await _startNfcPollingUnified();
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
      await _posService.stopNfcPolling();
    } catch (e) {
      debugPrint('Error stopping background scanning: $e');
    }
  }

  // ============ Event Handlers ============
  Future<void> _handleQrDetected(String qrCode) async {
    if (_isProcessing || _isLoading) return;

    _isProcessing = true;

    try {
      await _posService.beep();
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
      final id = await _posService.readCardId().timeout(
        const Duration(milliseconds: 1500),
        onTimeout: () => null,
      );
      if (id != null && id.isNotEmpty) {
        cardId = id;
        debugPrint('[NFC] ✅ Card ID detected: $cardId');
      } else {
        cardId = 'UNKNOWN-CARD';
        debugPrint('[NFC] ⚠️ readCardId returned null/empty');
      }
    } catch (e) {
      debugPrint('[NFC] ❌ Read Card Failed: $e');
      cardId = 'UNKNOWN-CARD';
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

    final tapInTime = DateTime.now().toUtc();

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

    // Queue TapIn GPS resolution — รอ GPS ที่เวลาเลย tapInTime ก่อน resolve
    _pendingTapInGpsQueue.add(
      _PendingTapInGps(aid: qrData.aid, tapInTime: tapInTime),
    );
    debugPrint('[EMV] ========== TAP-IN EMV FLOW ==========');
    debugPrint('[EMV] 📝 Queued TapIn GPS resolution');
    debugPrint('[EMV]   ├─ aid: ${qrData.aid}');
    debugPrint('[EMV]   ├─ tapInTime: $tapInTime');
    debugPrint('[EMV]   ├─ current GPS history size: ${_gpsHistory.length}');
    debugPrint(
      '[EMV]   └─ pending TapIn queue size: ${_pendingTapInGpsQueue.length}',
    );
    debugPrint('[EMV] ⏳ Waiting for GPS rec > $tapInTime ...');

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
    final tapOutTime = DateTime.now().toUtc();

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
      tapInTime: _formatDateTime(pending.tapInTime),
      tapInLoc: pending.tapInLoc,
      tapOutTime: _formatDateTime(tapOutTime),
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

        // --- Queue EMV Transaction — รอ GPS ที่เวลาเลย tapOutTime ก่อนส่ง ---
        final tapOutTime = DateTime.parse(
          payload.transactions.first.tapOutTime,
        );
        _pendingEmvRequests.add(
          _PendingEmvRequest(
            payload: payload,
            routeId: routeId,
            tapOutTime: tapOutTime,
          ),
        );
        debugPrint('[EMV] ========== TAP-OUT EMV FLOW ==========');
        debugPrint('[EMV] 📝 Queued EMV transaction (waiting for GPS)');
        debugPrint('[EMV]   ├─ aid: $aid');
        debugPrint('[EMV]   ├─ tapOutTime: $tapOutTime');
        debugPrint(
          '[EMV]   ├─ tapInGps resolved: ${_resolvedTapInGps.containsKey(aid)}',
        );
        debugPrint('[EMV]   ├─ GPS history size: ${_gpsHistory.length}');
        debugPrint(
          '[EMV]   └─ pending EMV queue size: ${_pendingEmvRequests.length}',
        );
        debugPrint('[EMV] ⏳ Waiting for GPS rec > $tapOutTime ...');

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

  /// Build and submit EMV Transaction
  Future<void> _submitEmvTransaction(
    TransactionRequest originalPayload, {
    int? routeId,
  }) async {
    try {
      final firstTxn = originalPayload.transactions.first;
      debugPrint('[EMV] ========== BUILDING EMV TRANSACTION ==========');
      debugPrint(
        '[EMV] 🛠️ txnId: ${firstTxn.txnId}, assetId: ${firstTxn.assetId}',
      );

      final tapInTime = DateTime.parse(firstTxn.tapInTime);
      final tapOutTime = DateTime.parse(firstTxn.tapOutTime);
      debugPrint('[EMV] ⏱️ tapInTime: $tapInTime, tapOutTime: $tapOutTime');

      // --- TapIn GPS ---
      final hasResolvedTapIn = _resolvedTapInGps.containsKey(firstTxn.assetId);
      final tapInGps =
          _resolvedTapInGps[firstTxn.assetId] ?? _findClosestGps(tapInTime);
      final tapInGpsLat = tapInGps?.lat ?? firstTxn.tapInLoc.lat;
      final tapInGpsLng = tapInGps?.lng ?? firstTxn.tapInLoc.lng;
      debugPrint('[EMV] 📍 TapIn GPS:');
      debugPrint(
        '[EMV]   ├─ source: ${hasResolvedTapIn ? "RESOLVED (pre-captured)" : "HISTORY LOOKUP"}',
      );
      debugPrint('[EMV]   ├─ gpsTime: ${tapInGps?.rec}');
      debugPrint('[EMV]   ├─ lat: $tapInGpsLat, lng: $tapInGpsLng');
      debugPrint('[EMV]   ├─ box: ${tapInGps?.box}, spd: ${tapInGps?.spd}');
      if (tapInGps == null) {
        debugPrint('[EMV]   └─ ⚠️ FALLBACK to original transaction lat/lng');
      } else {
        final diffMs =
            (tapInGps.rec!.millisecondsSinceEpoch -
                    tapInTime.millisecondsSinceEpoch)
                .abs();
        debugPrint(
          '[EMV]   └─ time diff from tapInTime: ${diffMs}ms (${(diffMs / 1000).toStringAsFixed(1)}s)',
        );
      }

      // --- TapOut GPS ---
      final tapOutGps = _findClosestGps(tapOutTime);
      final tapOutGpsLat = tapOutGps?.lat ?? firstTxn.tapOutLoc.lat;
      final tapOutGpsLng = tapOutGps?.lng ?? firstTxn.tapOutLoc.lng;
      debugPrint('[EMV] 📍 TapOut GPS:');
      debugPrint('[EMV]   ├─ source: HISTORY LOOKUP');
      debugPrint('[EMV]   ├─ gpsTime: ${tapOutGps?.rec}');
      debugPrint('[EMV]   ├─ lat: $tapOutGpsLat, lng: $tapOutGpsLng');
      debugPrint('[EMV]   ├─ box: ${tapOutGps?.box}, spd: ${tapOutGps?.spd}');
      if (tapOutGps == null) {
        debugPrint('[EMV]   └─ ⚠️ FALLBACK to original transaction lat/lng');
      } else {
        final diffMs =
            (tapOutGps.rec!.millisecondsSinceEpoch -
                    tapOutTime.millisecondsSinceEpoch)
                .abs();
        debugPrint(
          '[EMV]   └─ time diff from tapOutTime: ${diffMs}ms (${(diffMs / 1000).toStringAsFixed(1)}s)',
        );
      }

      // --- Bus Stops ---
      final tapInStop = await _dbHelper.getNearestBusStop(
        tapInGpsLat,
        tapInGpsLng,
        routeId: routeId,
      );
      final tapOutStop = await _dbHelper.getNearestBusStop(
        tapOutGpsLat,
        tapOutGpsLng,
        routeId: routeId,
      );
      debugPrint('[EMV] 🚏 Bus Stops:');
      debugPrint(
        '[EMV]   ├─ TapIn: id=${tapInStop?.busstopId}, name=${tapInStop?.busstopDesc}, seq=${tapInStop?.seq}',
      );
      debugPrint(
        '[EMV]   └─ TapOut: id=${tapOutStop?.busstopId}, name=${tapOutStop?.busstopDesc}, seq=${tapOutStop?.seq}',
      );

      // --- Active Bus Trip ---
      final activeBusTrip = await _dbHelper.getActiveBusTrip();
      debugPrint('[EMV] 🚌 Active Bus Trip:');
      debugPrint(
        '[EMV]   ├─ id: ${activeBusTrip?.id}, routeId: ${activeBusTrip?.routeId}',
      );
      debugPrint(
        '[EMV]   └─ buslineId: ${activeBusTrip?.buslineId}, busno: ${activeBusTrip?.busno}',
      );

      // --- Fare ---
      double fareAmount = 0.0;
      if (tapInStop != null && tapOutStop != null) {
        fareAmount =
            await _dbHelper.getFare(
              tapInStop.seq,
              tapOutStop.seq,
              routeId: routeId,
            ) ??
            0.0;
      }
      debugPrint(
        '[EMV] 💰 Fare: $fareAmount (tapInSeq=${tapInStop?.seq}, tapOutSeq=${tapOutStop?.seq})',
      );

      // --- Device GPS (เครื่อง POS) ---
      double? deviceLat;
      double? deviceLng;
      try {
        final locStr = await _posService.getLocation().timeout(
          const Duration(seconds: 3),
          onTimeout: () => null,
        );
        if (locStr != null && locStr.contains(',')) {
          final parts = locStr.split(',');
          deviceLat = double.tryParse(parts[0]);
          deviceLng = double.tryParse(parts[1]);
        }
      } catch (e) {
        debugPrint('[EMV] ⚠️ Device GPS unavailable: $e');
      }
      debugPrint('[EMV] 📱 Device GPS: lat=$deviceLat, lng=$deviceLng');

      // Build EmvTapLocation for tap-in
      final tapInBusstopDist = _haversineDistance(
        tapInGpsLat,
        tapInGpsLng,
        tapInStop?.latitude ?? 0.0,
        tapInStop?.longitude ?? 0.0,
      );
      final emvTapInLoc = EmvTapLocation(
        latitude: deviceLat, // GPS เครื่อง POS (null ถ้าดึงไม่ได้)
        longitude: deviceLng, // GPS เครื่อง POS
        busstopId: tapInStop?.busstopId ?? 0, // master data BMS
        busstopName: tapInStop?.busstopDesc ?? '', // master data BMS
        busstopLatitude: tapInStop?.latitude ?? 0.0, // master data BMS
        busstopLongitude: tapInStop?.longitude ?? 0.0, // master data BMS
        busstopDistance: tapInBusstopDist, // ระยะห่าง MQTT GPS <-> bus stop
        gpsbusstopName: tapInStop?.busstopDesc ?? '', // ป้ายใกล้สุดจาก MQTT GPS
        gpsbusstopLatitude: tapInGpsLat, // MQTT GPS lat
        gpsbusstopLongitude: tapInGpsLng, // MQTT GPS lng
        gpsBoxId: tapInGps?.box ?? '',
        gpsRecDatetime:
            tapInGps?.rec?.toIso8601String() ?? tapInTime.toIso8601String(),
        gpsSpeed: tapInGps?.spd ?? 0.0,
      );

      // Build EmvTapLocation for tap-out
      final tapOutBusstopDist = _haversineDistance(
        tapOutGpsLat,
        tapOutGpsLng,
        tapOutStop?.latitude ?? 0.0,
        tapOutStop?.longitude ?? 0.0,
      );
      final emvTapOutLoc = EmvTapLocation(
        latitude: deviceLat, // GPS เครื่อง POS
        longitude: deviceLng, // GPS เครื่อง POS
        busstopId: tapOutStop?.busstopId ?? 0,
        busstopName: tapOutStop?.busstopDesc ?? '',
        busstopLatitude: tapOutStop?.latitude ?? 0.0,
        busstopLongitude: tapOutStop?.longitude ?? 0.0,
        busstopDistance: tapOutBusstopDist,
        gpsbusstopName: tapOutStop?.busstopDesc ?? '',
        gpsbusstopLatitude: tapOutGpsLat, // MQTT GPS lat
        gpsbusstopLongitude: tapOutGpsLng, // MQTT GPS lng
        gpsBoxId: tapOutGps?.box ?? '',
        gpsRecDatetime:
            tapOutGps?.rec?.toIso8601String() ?? tapOutTime.toIso8601String(),
        gpsSpeed: tapOutGps?.spd ?? 0.0,
      );

      // Build EmvFareInfo
      final emvFareInfo = EmvFareInfo(
        bustripId: activeBusTrip?.id ?? 0,
        routeId: activeBusTrip?.routeId ?? routeId ?? 0,
        buslineId: activeBusTrip?.buslineId ?? 0,
        businfoId: activeBusTrip?.businfoId ?? 0,
        busNo: activeBusTrip?.busno ?? '',
        isMorning: false,
        isExpress: false,
        morningAmount: 0.0,
        expressAmount: 0.0,
        fareAmount: fareAmount,
        totalAmount: fareAmount,
      );

      // Build EmvTransactionItem
      final emvTxnItem = EmvTransactionItem(
        txnId: firstTxn.txnId,
        assetId: firstTxn.assetId,
        assetType: 'EMV',
        tapInTime: firstTxn.tapInTime,
        tapInLoc: emvTapInLoc,
        tapOutTime: firstTxn.tapOutTime,
        tapOutLoc: emvTapOutLoc,
        fareInfo: emvFareInfo,
      );

      // Build request
      final emvRequest = EmvTransactionRequest(
        deviceId: originalPayload.deviceId,
        plateNo: originalPayload.plateNo,
        transactions: [emvTxnItem],
      );

      debugPrint('[EMV] 📦 Payload built. Sending to API...');
      debugPrint('[EMV]   ├─ deviceId: ${emvRequest.deviceId}');
      debugPrint('[EMV]   └─ plateNo: ${emvRequest.plateNo}');

      // Send
      final success = await _emvTransactionService.submitEmvTransaction(
        emvRequest,
      );
      debugPrint(
        '[EMV] ========== EMV RESULT: ${success ? "✅ SUCCESS" : "❌ FAILED"} ==========',
      );
    } catch (e) {
      debugPrint('[EMV] ❌ EXCEPTION in _submitEmvTransaction: $e');
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

  // ============ Debug Simulate ============
  void _simulateTap({required bool isTapOut}) {
    const simulatedAid = 'SIM-CARD-001';
    final qrData = QrData(aid: simulatedAid, bal: 100.00);

    if (isTapOut && _pendingTransactions.containsKey(simulatedAid)) {
      debugPrint('[SIM] 🟡 Simulating TAP-OUT for $simulatedAid');
      _handleTapOut(qrData);
    } else if (!isTapOut) {
      debugPrint('[SIM] 🟢 Simulating TAP-IN for $simulatedAid');
      _handleTapIn(qrData);
    } else {
      debugPrint('[SIM] ⚠️ No pending tap-in found for $simulatedAid');
      _showResultDialog(
        'ไม่มีข้อมูลแตะขึ้น',
        'กรุณากดจำลองแตะขึ้นก่อน',
        isSuccess: false,
      );
    }
  }

  // ============ UI Build ============
  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return Scaffold(
        resizeToAvoidBottomInset: false,
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
      resizeToAvoidBottomInset: false,
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
                                    Expanded(
                                      child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          Text(
                                            'สถานีปัจจุบัน: $_currentStation',
                                            style: TextStyle(
                                              color: Colors.white,
                                              fontSize: 16,
                                              fontWeight: FontWeight.w500,
                                            ),
                                            overflow: TextOverflow.ellipsis,
                                          ),
                                          if (_currentStationDistance != null &&
                                              _currentStationSeq != null)
                                            Text(
                                              'ป้ายที่: $_currentStationSeq | ระยะห่าง: ${_currentStationDistance!.toStringAsFixed(0)} เมตร',
                                              style: TextStyle(
                                                color: Colors.white70,
                                                fontSize: 13,
                                              ),
                                            ),
                                          SizedBox(height: 4),
                                          if (_nextStation.isNotEmpty) ...[
                                            Text(
                                              'สถานีถัดไป: $_nextStation',
                                              style: TextStyle(
                                                color: Colors.white70,
                                                fontSize: 14,
                                                fontWeight: FontWeight.w500,
                                              ),
                                              overflow: TextOverflow.ellipsis,
                                            ),
                                            if (_nextStationDistance != null &&
                                                _nextStationSeq != null)
                                              Text(
                                                'ป้ายที่: $_nextStationSeq | ระยะห่าง: ${_nextStationDistance!.toStringAsFixed(0)} เมตร',
                                                style: TextStyle(
                                                  color: Colors.white54,
                                                  fontSize: 13,
                                                ),
                                              ),
                                          ],
                                        ],
                                      ),
                                    ),
                                    if (_isGpsUpdating)
                                      SizedBox(
                                        width: 16,
                                        height: 16,
                                        child: CircularProgressIndicator(
                                          strokeWidth: 2,
                                          color: Colors.greenAccent,
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

                              // === Debug Simulate Buttons ===
                              const SizedBox(height: 20),
                              Row(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  ElevatedButton.icon(
                                    onPressed: () =>
                                        _simulateTap(isTapOut: false),
                                    icon: const Icon(Icons.login, size: 18),
                                    label: const Text('จำลองแตะขึ้น'),
                                    style: ElevatedButton.styleFrom(
                                      backgroundColor: Colors.green.shade700,
                                      foregroundColor: Colors.white,
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 16,
                                        vertical: 10,
                                      ),
                                      shape: RoundedRectangleBorder(
                                        borderRadius: BorderRadius.circular(20),
                                      ),
                                    ),
                                  ),
                                  const SizedBox(width: 12),
                                  ElevatedButton.icon(
                                    onPressed:
                                        _pendingTransactions.containsKey(
                                          'SIM-CARD-001',
                                        )
                                        ? () => _simulateTap(isTapOut: true)
                                        : null,
                                    icon: const Icon(Icons.logout, size: 18),
                                    label: const Text('จำลองแตะลง'),
                                    style: ElevatedButton.styleFrom(
                                      backgroundColor: Colors.red.shade700,
                                      foregroundColor: Colors.white,
                                      disabledBackgroundColor:
                                          Colors.grey.shade600,
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 16,
                                        vertical: 10,
                                      ),
                                      shape: RoundedRectangleBorder(
                                        borderRadius: BorderRadius.circular(20),
                                      ),
                                    ),
                                  ),
                                ],
                              ),

                              const Spacer(),

                              // Bottom Status Indicators
                              Padding(
                                padding: const EdgeInsets.only(bottom: 16.0),
                                child: Row(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  children: [
                                    Container(
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
                                        ],
                                      ),
                                    ),
                                    const SizedBox(width: 16),

                                     // Removed Status Icons here
                                    // Settings Button
                                    GestureDetector(
                                      onTap: () async {
                                        await Navigator.of(context).push(
                                          MaterialPageRoute(
                                            builder: (_) => SettingsScreen(
                                              plateNumber: _plateNumber,
                                              activeRouteId: _activeRouteId,
                                              onPlateChanged: (newPlate) async {
                                                await _performPlateChange(newPlate);
                                              },
                                              gpsHistory: _gpsHistory,
                                              gpsStream: _mqttService.gpsStream,
                                            ),
                                          ),
                                        );
                                        // Refresh plate from SharedPreferences when returning
                                        final prefs = await SharedPreferences.getInstance();
                                        final savedPlate = prefs.getString('plate_number') ?? '';
                                        if (mounted && savedPlate != _plateNumber) {
                                          setState(() {
                                            _plateNumber = savedPlate;
                                          });
                                        }
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
                                              Icons.settings,
                                              color: Colors.white,
                                              size: 20,
                                            ),
                                            SizedBox(width: 6),
                                            Text(
                                              'ตั้งค่า',
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

          // === Loading overlay during plate change ===
          if (_isPlateChanging)
            Container(
              color: Colors.black87,
              child: Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    CircularProgressIndicator(
                      color: Colors.white,
                      strokeWidth: 3,
                    ),
                    SizedBox(height: 24),
                    Text(
                      _plateChangeStatus,
                      style: TextStyle(color: Colors.white, fontSize: 18),
                      textAlign: TextAlign.center,
                    ),
                    SizedBox(height: 8),
                    Text(
                      'กรุณารอสักครู่...',
                      style: TextStyle(color: Colors.white54, fontSize: 14),
                    ),
                  ],
                ),
              ),
            ),

          // === Disabled overlay when data is incomplete ===
          if (_isAppDisabled && !_isPlateChanging)
            Container(
              color: Colors.black54,
              child: Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.warning_amber_rounded,
                      color: Colors.amber,
                      size: 64,
                    ),
                    SizedBox(height: 16),
                    Text(
                      'ข้อมูลไม่ครบสมบูรณ์',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 20,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    SizedBox(height: 8),
                    Text(
                      'กรุณาแก้ไขทะเบียนเพื่อดึงข้อมูลใหม่',
                      style: TextStyle(color: Colors.white70, fontSize: 14),
                    ),
                    SizedBox(height: 24),
                    ElevatedButton.icon(
                      icon: Icon(Icons.settings),
                      label: Text('ไปตั้งค่า'),
                      onPressed: () {
                        Navigator.of(context).push(
                          MaterialPageRoute(
                            builder: (_) => SettingsScreen(
                              plateNumber: _plateNumber,
                              activeRouteId: _activeRouteId,
                              onPlateChanged: (newPlate) async {
                                await _performPlateChange(newPlate);
                              },
                              gpsHistory: _gpsHistory,
                              gpsStream: _mqttService.gpsStream,
                            ),
                          ),
                        );
                      },
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.amber,
                        foregroundColor: Colors.black,
                      ),
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }



  // _showEditPlateDialog() ย้ายไปหน้า SettingsScreen แล้ว

  /// Full plate change flow with loading overlay
  Future<void> _performPlateChange(String newPlate) async {
    setState(() {
      _isPlateChanging = true;
      _plateChangeStatus = 'กำลังเตรียมข้อมูล...';
      _plateChangeErrors.clear();
      _isAppDisabled = false;
    });

    // Step 1: Clear old data
    setState(() => _plateChangeStatus = 'กำลังล้างข้อมูลเก่า...');
    await Future.delayed(const Duration(milliseconds: 300));
    setState(() {
      _plateNumber = newPlate;
      _gpsHistory.clear();
      _pendingEmvRequests.clear();
      _pendingTapInGpsQueue.clear();
      _resolvedTapInGps.clear();
      _pendingTransactions.clear();
      _currentGpsData = null;
      _currentStation = 'กำลังค้นหาสถานี...';
      _currentStationSeq = null;
      _nextStation = '';
      _nextStationSeq = null;
    });

    // Step 2: Save to SharedPreferences
    setState(() => _plateChangeStatus = 'กำลังบันทึกทะเบียน...');
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('plate_number', _plateNumber);
      await _savePendingTransactions();
    } catch (e) {
      _plateChangeErrors.add('❌ บันทึกทะเบียนล้มเหลว: $e');
      debugPrint('[PLATE] ❌ Save prefs error: $e');
    }

    // Step 3: Connect MQTT
    setState(() => _plateChangeStatus = 'กำลังเชื่อมต่อ MQTT ($newPlate)...');
    try {
      final mqttResult = await _mqttService.connect(_plateNumber);
      if (!mqttResult) {
        _plateChangeErrors.add('⚠️ เชื่อมต่อ MQTT ไม่สำเร็จ');
        debugPrint('[PLATE] ⚠️ MQTT connect failed');
      }
    } catch (e) {
      _plateChangeErrors.add('❌ เชื่อมต่อ MQTT ล้มเหลว: $e');
      debugPrint('[PLATE] ❌ MQTT error: $e');
    }

    // Step 4: Sync data
    setState(() => _plateChangeStatus = 'กำลังดาวน์โหลดข้อมูลเส้นทาง...');
    SyncResult? syncResult;
    try {
      final syncService = DataSyncService();
      syncResult = await syncService.syncAllData(plateNo: _plateNumber);
      if (!syncResult.isSuccess) {
        _plateChangeErrors.add('❌ ดึงข้อมูลเส้นทางไม่สำเร็จ');
        debugPrint('[PLATE] ❌ syncAllData returned failure');
      } else {
        if (mounted) {
          setState(() {
            _activeRouteId = syncResult?.activeRouteId;
          });
        }
      }
    } catch (e) {
      _plateChangeErrors.add('❌ ดึงข้อมูลเส้นทางล้มเหลว: $e');
      debugPrint('[PLATE] ❌ Sync error: $e');
    }

    // Step 5: Verify data completeness
    setState(() => _plateChangeStatus = 'กำลังตรวจสอบข้อมูล...');
    try {
      final db = await _dbHelper.database;
      final routeCount =
          Sqflite.firstIntValue(
            await db.rawQuery('SELECT COUNT(*) FROM route_details'),
          ) ??
          0;
      final priceCount =
          Sqflite.firstIntValue(
            await db.rawQuery('SELECT COUNT(*) FROM price_ranges'),
          ) ??
          0;
      final tripCount =
          Sqflite.firstIntValue(
            await db.rawQuery('SELECT COUNT(*) FROM bus_trips'),
          ) ??
          0;

      debugPrint(
        '[PLATE] 📊 Data check: routes=$routeCount prices=$priceCount trips=$tripCount',
      );

      if (routeCount == 0)
        _plateChangeErrors.add('⚠️ ไม่พบข้อมูลเส้นทาง (route_details)');
      if (priceCount == 0)
        _plateChangeErrors.add('⚠️ ไม่พบข้อมูลราคา (price_ranges)');
      if (tripCount == 0)
        _plateChangeErrors.add('⚠️ ไม่พบข้อมูลเที่ยวรถ (bus_trips)');
    } catch (e) {
      _plateChangeErrors.add('❌ ตรวจสอบข้อมูลล้มเหลว: $e');
    }

    // Done — show result
    if (_plateChangeErrors.isNotEmpty) {
      setState(() {
        _isPlateChanging = false;
        _isAppDisabled = true;
      });

      if (mounted) {
        showDialog(
          context: context,
          barrierDismissible: false,
          builder: (ctx) => AlertDialog(
            title: Row(
              children: [
                Icon(Icons.error_outline, color: Colors.red),
                SizedBox(width: 8),
                Text('เกิดข้อผิดพลาด'),
              ],
            ),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'ทะเบียน: $newPlate',
                  style: TextStyle(fontWeight: FontWeight.bold),
                ),
                SizedBox(height: 12),
                ..._plateChangeErrors.map(
                  (e) => Padding(
                    padding: EdgeInsets.only(bottom: 4),
                    child: Text(e, style: TextStyle(fontSize: 13)),
                  ),
                ),
                SizedBox(height: 12),
                Text(
                  'ระบบไม่สามารถใช้งานได้จนกว่าข้อมูลจะครบสมบูรณ์\nกรุณาลองใหม่อีกครั้ง',
                  style: TextStyle(color: Colors.red, fontSize: 13),
                ),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () {
                  Navigator.of(ctx).pop();
                  Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => SettingsScreen(
                        plateNumber: _plateNumber,
                        activeRouteId: _activeRouteId,
                        onPlateChanged: (newPlate) async {
                          await _performPlateChange(newPlate);
                        },
                        gpsHistory: _gpsHistory,
                        gpsStream: _mqttService.gpsStream,
                      ),
                    ),
                  );
                },
                child: Text('เปลี่ยนทะเบียน'),
              ),
              ElevatedButton(
                onPressed: () {
                  Navigator.of(ctx).pop();
                  _performPlateChange(newPlate); // retry
                },
                child: Text('ลองใหม่'),
              ),
            ],
          ),
        );
      }
    } else {
      setState(() {
        _isPlateChanging = false;
        _isAppDisabled = false;
      });

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('อัปเดตข้อมูลสำหรับ $newPlate เรียบร้อย ✅'),
            backgroundColor: Colors.green,
          ),
        );
      }
    }
  }
}

/// Pending EMV request — รอ GPS ที่เวลาเลย tapOutTime ก่อนส่ง
class _PendingEmvRequest {
  final TransactionRequest payload;
  final int? routeId;
  final DateTime tapOutTime;

  _PendingEmvRequest({
    required this.payload,
    this.routeId,
    required this.tapOutTime,
  });
}

/// Pending TapIn GPS — รอ GPS ที่เวลาเลย tapInTime ก่อน resolve
class _PendingTapInGps {
  final String aid;
  final DateTime tapInTime;

  _PendingTapInGps({required this.aid, required this.tapInTime});
}
