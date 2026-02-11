import 'dart:async';
import 'dart:convert';
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

  // Transaction State
  final Map<String, PendingTransaction> _pendingTransactions = {};
  final Uuid _uuid = const Uuid();
  static const String _storageKey = 'pending_transactions';
  bool _isProcessing = false;
  bool _isLoading = false;

  // Background Scanning State
  bool _isBackgroundScanningActive = false;
  StreamSubscription<String>? _qrSubscription;
  StreamSubscription<bool>? _nfcSubscription;

  // WiFi Sync for pending transactions
  final WifiSyncService _syncService = WifiSyncService();
  StreamSubscription<PendingTransactionSync>? _pendingSyncSubscription;

  String _plateNumber = '12-3456';
  String _timeString = '00:00';
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
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _loadPlateNumber();
      _loadPendingTransactions();
      _requestPermissionsAndStartScanning();
      _requestPermissionsAndStartScanning();
      _setupPendingSyncListener();
      _updateTime();
      _timer = Timer.periodic(const Duration(seconds: 1), (_) => _updateTime());
    });
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
    WidgetsBinding.instance.removeObserver(this);
    _timer?.cancel();
    _pendingSyncSubscription?.cancel();
    _stopBackgroundScanning();
    super.dispose();
  }

  // ============ Permission Handling ============
  Future<void> _requestPermissionsAndStartScanning() async {
    // Stop any existing sessions first to prevent camera conflicts
    debugPrint('Cleaning up any existing sessions...');
    try {
      await _cpaySdkPlugin.stopQrScan();
      await _cpaySdkPlugin.stopNfcPolling();
    } catch (e) {
      debugPrint('Cleanup error (can be ignored): $e');
    }

    // Small delay to ensure resources are released
    await Future.delayed(const Duration(milliseconds: 300));

    // Request camera permission
    final cameraStatus = await Permission.camera.request();
    debugPrint('Camera permission status: $cameraStatus');

    if (cameraStatus.isGranted) {
      await _startBackgroundScanning();
    } else if (cameraStatus.isPermanentlyDenied) {
      // Show dialog to open settings
      if (mounted) {
        _showPermissionDeniedDialog();
      }
    } else {
      // Permission denied but not permanently - start NFC only
      debugPrint('Camera permission denied, starting NFC only');
      await _startNfcPollingOnly();
    }
  }

  void _showPermissionDeniedDialog() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('ต้องการ Permission กล้อง'),
        content: const Text(
          'แอปต้องการ Permission กล้องเพื่อสแกน QR Code กรุณาไปที่ Settings เพื่อเปิด Permission',
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
    for (int attempt = 1; attempt <= retries; attempt++) {
      try {
        // Wait a bit before starting to ensure camera resources are released
        if (attempt > 1) {
          debugPrint('QR Scan retry attempt $attempt/$retries...');
          await Future.delayed(Duration(milliseconds: 500 * attempt));
        }

        final qrStarted = await _cpaySdkPlugin.startQrScan(isFrontCamera: true);
        debugPrint('QR Scan started: $qrStarted');

        _qrSubscription?.cancel();
        _qrSubscription = _cpaySdkPlugin.onQrCodeDetected.listen((qrCode) {
          debugPrint('QR Code Detected: $qrCode');
          _handleQrDetected(qrCode);
        });

        return; // Success, exit retry loop
      } catch (e) {
        debugPrint('Failed to start QR scan (attempt $attempt): $e');
        if (attempt == retries) {
          debugPrint('All QR scan retries failed, continuing with NFC only');
        }
      }
    }
  }

  Future<void> _startNfcPollingOnly() async {
    try {
      final nfcStarted = await _cpaySdkPlugin.startNfcPolling(intervalMs: 500);
      debugPrint('NFC Polling started: $nfcStarted');

      _nfcSubscription?.cancel();
      _nfcSubscription = _cpaySdkPlugin.onNfcCardDetected.listen((cardPresent) {
        if (cardPresent) {
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
      await _cpaySdkPlugin.stopQrScan();
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
    } catch (e) {
      debugPrint('Error loading plate number: $e');
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
    final pending = PendingTransaction(
      aid: qrData.aid,
      tapInTime: DateTime.now().toUtc(),
      tapInLoc: TransactionLocation(lat: 0.0, lng: 0.0),
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
      );
      await _syncService.sendPendingSync(pendingSync);
      debugPrint('📤 Broadcasted Tap In for ${qrData.aid}');
    }

    _showResultDialog(
      'อนุสาวรีย์ชัยฯ',
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
    final tapOutLoc = TransactionLocation(lat: 0.0, lng: 0.0);

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

    await _submitTransaction(payload, qrData.aid);
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
    String aid,
  ) async {
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
          debugPrint('📤 Broadcasted Tap Out removal for $aid');
        }

        _showResultDialog(
          'สยามพารากอน',
          'ขอบคุณที่ใช้บริการ',
          isSuccess: true,
          isTapOut: true,
          price: '25.00 ฿',
          balance: '475.00 ฿',
          topStatus: 'ชำระเงินสำเร็จ',
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

    if (isSuccess) {
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(
          builder: (context) => SuccessResultScreen(
            onDismiss: (ctx) {
              Navigator.of(ctx).pushReplacement(
                MaterialPageRoute(builder: (_) => const WelcomeScreen()),
              );
            },
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
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(
          builder: (context) => ErrorResultScreen(
            onDismiss: (ctx) {
              Navigator.of(ctx).pushReplacement(
                MaterialPageRoute(builder: (_) => const WelcomeScreen()),
              );
            },
            errorTitle: 'ทำรายการไม่สำเร็จ',
          ),
        ),
      );
    }
  }

  // ============ UI Build ============
  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return Scaffold(backgroundColor: Colors.white, body: _buildLoadingUI());
    }

    return Scaffold(
      body: Container(
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
                          crossAxisAlignment: CrossAxisAlignment.start,
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
                              _syncService.currentRole == SyncRole.host
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
                        'สถานีปัจจุบัน: อนุสาวรีย์ชัยฯ',
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

                // Center Content
                const Icon(
                  Icons.credit_card,
                  size: 100,
                  color: Colors.lightBlueAccent,
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
                const SizedBox(height: 12),
                const Text(
                  'รองรับบัตรเครดิต และ QR Code',
                  style: TextStyle(color: Colors.white70, fontSize: 18),
                ),

                const SizedBox(height: 20),
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
                            borderRadius: BorderRadius.circular(20),
                            border: Border.all(color: Colors.white54),
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
                            _buildStatusIcon(Icons.qr_code_scanner, true),
                            const SizedBox(width: 16),
                            _buildStatusIcon(Icons.credit_card, true),
                          ],
                        ),
                      ),
                      const SizedBox(width: 16),
                      // WiFi Sync Button
                      GestureDetector(
                        onTap: () {
                          Navigator.of(context).push(
                            MaterialPageRoute(
                              builder: (_) => const WifiSyncScreen(),
                            ),
                          );
                        },
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 8,
                          ),
                          decoration: BoxDecoration(
                            color: Colors.deepPurple.withOpacity(0.8),
                            borderRadius: BorderRadius.circular(20),
                            border: Border.all(color: Colors.white54),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: const [
                              Icon(Icons.wifi, color: Colors.white, size: 20),
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
                if (controller.text.isNotEmpty) {
                  setState(() {
                    _plateNumber = controller.text;
                  });
                  final prefs = await SharedPreferences.getInstance();
                  await prefs.setString('plate_number', _plateNumber);
                }
                if (mounted) Navigator.of(context).pop();
              },
              child: const Text('บันทึก'),
            ),
          ],
        );
      },
    );
  }
}
