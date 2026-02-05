import 'dart:async';
import 'dart:convert';
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:cpay_sdk_plugin/cpay_sdk_plugin.dart';
import 'package:http/http.dart' as http;
import 'package:uuid/uuid.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'models/transaction_model.dart';
import 'success_result_screen.dart';
import 'error_result_screen.dart';

import 'package:wakelock_plus/wakelock_plus.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'services/nearby_service.dart';

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

class _WelcomeScreenState extends State<WelcomeScreen> {
  final _cpaySdkPlugin = CpaySdkPlugin();

  // MobileScanner
  final MobileScannerController _scannerController = MobileScannerController(
    detectionSpeed: DetectionSpeed.noDuplicates,
    facing: CameraFacing.front,
    formats: [BarcodeFormat.qrCode],
  );

  // Transaction State
  final Map<String, PendingTransaction> _pendingTransactions = {};
  final Uuid _uuid = const Uuid();
  static const String _storageKey = 'pending_transactions';
  bool _isProcessing = false;
  bool _isLoading = false;

  String _timeString = '00:00';
  Timer? _timer;

  // Sync State
  String _plateNo = '12-3456'; // Default
  String _role = 'DRIVER'; // DRIVER or PASSENGER
  bool _isSynced = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _loadPendingTransactions();
      _startNfcPolling();
      _scannerController.start();
      _updateTime(); // Update time immediately
      _timer = Timer.periodic(const Duration(seconds: 1), (_) => _updateTime());

      // Auto-start Sync
      _initSync();
    });
  }

  void _initSync() {
    final nearby = NearbyService();
    nearby.checkPermissions().then((granted) {
      if (granted) {
        if (_role == 'DRIVER') {
          nearby.startAdvertising(_plateNo);
        } else {
          nearby.startDiscovery(_plateNo);
        }
      }
    });

    nearby.onDataReceived = (data) {
      debugPrint('Sync Data: $data');
      try {
        final map = jsonDecode(data);
        if (map['type'] == 'TAP_IN') {
          // Sync Tap In logic
          final aid = map['aid'];
          final time = DateTime.parse(map['time']);
          if (!_pendingTransactions.containsKey(aid)) {
            setState(() {
              _pendingTransactions[aid] = PendingTransaction(
                aid: aid,
                tapInTime: time,
                tapInLoc: TransactionLocation(lat: 0, lng: 0),
              );
            });
            _savePendingTransactions();
          }
        } else if (map['type'] == 'TAP_OUT') {
          // Sync Tap Out logic
          final aid = map['aid'];
          setState(() {
            _pendingTransactions.remove(aid);
          });
          _savePendingTransactions();
        }
      } catch (e) {
        /* ignore */
      }
    };

    nearby.onStatusChanged = (status) {
      if (status.contains('Connected')) {
        setState(() => _isSynced = true);
      } else if (status.contains('Disconnected')) {
        setState(() => _isSynced = false);
      }
    };
  }

  Widget _buildLoadingUI() {
    return Container(
      width: double.infinity,
      color: Colors.white,
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          // Bus Icon
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
          // BMTA Text
          const Text(
            'ขสมก. BMTA',
            style: TextStyle(
              color: Color(0xFF0D47A1), // Dark Blue
              fontSize: 28,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 16),
          // System Starting / Processing Text
          const Text(
            'กำลังประมวลผล...',
            style: TextStyle(
              color: Color(0xFF64B5F6), // Lighter Blue
              fontSize: 18,
              fontWeight: FontWeight.w500,
            ),
          ),
          const SizedBox(height: 40),
          // Loader
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

  void _updateTime() {
    final now = DateTime.now();
    // Manual formatting to avoid intl dependency if not present
    final hour = now.hour.toString().padLeft(2, '0');
    final minute = now.minute.toString().padLeft(2, '0');
    if (mounted) {
      setState(() {
        _timeString = '$hour:$minute';
      });
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    _isProcessing = true; // Stop polling
    _scannerController.dispose();
    super.dispose();
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

  Future<void> _startNfcPolling() async {
    while (mounted && !_isProcessing) {
      try {
        await _checkNfcOnce();
      } catch (e) {
        debugPrint('NFC Poll Error: $e');
      }
      await Future.delayed(const Duration(milliseconds: 500));
    }
  }

  Future<void> _checkNfcOnce() async {
    if (_isProcessing) return;
    try {
      final isPresent = await _cpaySdkPlugin.isRfCardPresent();

      if (isPresent == true) {
        _isProcessing = true;
        // debugPrint('RF Card Detected!');
        // await _cpaySdkPlugin.beep(); // Commented out to prevent double beep

        // IMMEDIATE LOADING STATE
        if (mounted) {
          setState(() {
            _isLoading = true;
          });
        }

        // Try to get actual Card ID
        String cardId;
        try {
          final emvData = await _cpaySdkPlugin.readCardEmv().timeout(
            const Duration(milliseconds: 500),
            onTimeout: () => null,
          );
          if (emvData != null && emvData.isNotEmpty) {
            // If returns JSON or raw data, use hash or data as ID
            cardId = 'CARD-${emvData.hashCode}';
          } else {
            // Fallback to Fixed ID if read fails or returns null
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
    } catch (e) {
      debugPrint('Check NFC Error: $e');
      _isProcessing = false; // Reset if error occurred early
      if (mounted) {
        setState(() {
          _isLoading = false; // Reset loading
        });
      }
    }
  }

  // Detect QR Code from MobileScanner
  void _onQrDetect(BarcodeCapture capture) async {
    if (_isProcessing) return;

    final List<Barcode> barcodes = capture.barcodes;
    if (barcodes.isNotEmpty) {
      final code = barcodes.first.rawValue;
      if (code != null) {
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
        await _processQrString(code);
      }
    }
  }

  Future<void> _processQrString(String jsonString) async {
    try {
      final Map<String, dynamic> data = jsonDecode(jsonString);
      final qrData = QrData.fromJson(data);

      if (_pendingTransactions.containsKey(qrData.aid)) {
        await _handleTapOut(qrData);
      } else {
        _handleTapIn(qrData);
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

  // Reuse existing logic for Tap In
  void _handleTapIn(QrData qrData) {
    final pending = PendingTransaction(
      aid: qrData.aid,
      tapInTime: DateTime.now().toUtc(),
      tapInLoc: TransactionLocation(lat: 0.0, lng: 0.0), // Mock
    );

    // Broadcast Tap In
    final nearby = NearbyService();
    nearby.sendData({
      'type': 'TAP_IN',
      'aid': qrData.aid,
      'time': pending.tapInTime.toIso8601String(),
    });

    setState(() {
      _pendingTransactions[qrData.aid] = pending;
    });
    _savePendingTransactions();
    _showResultDialog(
      'อนุสาวรีย์ชัยฯ', // Location
      'บันทึกจุดขึ้นรถแล้ว', // Main Message
      isSuccess: true,
      price: null, // Hide price
      topStatus: 'เริ่มต้นเดินทาง',
      instruction: 'กรุณาแตะบัตรอีกครั้งเมื่อลงรถ',
    );
  }

  // Reuse existing logic for Tap Out
  Future<void> _handleTapOut(QrData qrData) async {
    // ... validate transaction exists ...
    if (!_pendingTransactions.containsKey(qrData.aid)) return;

    final pending = _pendingTransactions[qrData.aid]!;
    final tapOutTime = DateTime.now().toUtc();
    final tapOutLoc = TransactionLocation(lat: 0.0, lng: 0.0);

    // Broadcast Tap Out (Before or After API, but mainly to clear peer pending list)
    final nearby = NearbyService();
    nearby.sendData({'type': 'TAP_OUT', 'aid': qrData.aid});

    final txnItem = TransactionItem(
      txnId: _uuid.v4(),
      assetId: qrData.aid,
      assetType: 'QR',
      tapInTime: pending.tapInTime.toUtc().toIso8601String(), // Ensure UTC
      tapInLoc: pending.tapInLoc,
      tapOutTime: tapOutTime.toUtc().toIso8601String(), // Ensure UTC
      tapOutLoc: tapOutLoc,
    );

    final payload = TransactionRequest(
      deviceId: 'ANDROID_POS_01',
      plateNo: '12-3456',
      transactions: [txnItem],
    );

    await _submitTransaction(payload, qrData.aid);
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
        _showResultDialog(
          'สยามพารากอน', // Location (Drop-off)
          'ขอบคุณที่ใช้บริการ', // Main Message
          isSuccess: true,
          isTapOut: true,
          price: '25.00 ฿', // Fare
          balance: '475.00 ฿', // Balance
          topStatus: 'ชำระเงินสำเร็จ',
          instruction: 'เดินทางปลอดภัย',
        );
      } else {
        _showResultDialog(
          'Tap Out Failed',
          'API Error: ${response.statusCode}',
          isSuccess: false,
        );
      }
    } catch (e) {
      _showResultDialog('Tap Out Error', '$e', isSuccess: false);
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

    // Resume polling after dialog is dismissed if needed,
    // but typically we navigate back to Welcome (which is this screen)
    // effectively resetting the state or just dismissing the dialog.
    // For this flow, we push the ResultScreen.

    if (isSuccess) {
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(
          builder: (context) => SuccessResultScreen(
            onDismiss: (ctx) {
              // When dismissed, go back to WelcomeScreen (reload it to restart polling)
              Navigator.of(ctx).pushReplacement(
                MaterialPageRoute(builder: (_) => const WelcomeScreen()),
              );
            },
            title: title, // This is location name
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

  void _showSettingsDialog() {
    final plateController = TextEditingController(text: _plateNo);
    // Temporary variables to hold state changes in dialog
    String tempRole = _role;

    showDialog(
      context: context,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setStateDialog) {
            return AlertDialog(
              title: const Text('ตั้งค่าระบบ'),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // Role Selection
                  const Text(
                    'ตำแหน่งอุปกรณ์:',
                    style: TextStyle(fontWeight: FontWeight.bold),
                  ),
                  RadioListTile<String>(
                    title: const Text('คนขับ (Driver)'),
                    value: 'DRIVER',
                    groupValue: tempRole,
                    onChanged: (val) {
                      setStateDialog(() => tempRole = val!);
                    },
                  ),
                  RadioListTile<String>(
                    title: const Text('ประตูหลัง (Passenger)'),
                    value: 'PASSENGER',
                    groupValue: tempRole,
                    onChanged: (val) {
                      setStateDialog(() => tempRole = val!);
                    },
                  ),

                  const SizedBox(height: 16),

                  // Plate No Input
                  TextField(
                    controller: plateController,
                    decoration: const InputDecoration(
                      labelText: 'หมายเลขข้างรถ (Plate No)',
                      border: OutlineInputBorder(),
                    ),
                  ),
                ],
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('ยกเลิก'),
                ),
                ElevatedButton(
                  onPressed: () {
                    // Save Settings and Restart Sync
                    setState(() {
                      _role = tempRole;
                      _plateNo = plateController.text;
                      _isSynced = false;
                    });

                    // Restart Nearby Service
                    final nearby = NearbyService();
                    nearby.stopAll().then((_) {
                      _initSync();
                    });

                    Navigator.pop(context);
                  },
                  child: const Text('บันทึก'),
                ),
              ],
            );
          },
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return Scaffold(backgroundColor: Colors.white, body: _buildLoadingUI());
    }

    return Scaffold(
      body: Stack(
        children: [
          // Layer 1: Scanner Logic/View (Background)
          // Use SizedBox.expand to fill the screen
          SizedBox.expand(
            child: MobileScanner(
              controller: _scannerController,
              onDetect: _onQrDetect,
              fit: BoxFit.cover,
            ),
          ),

          // Layer 2: Overlay UI (Opaque)
          Container(
            decoration: const BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [
                  Color(0xFF1B5E20), // Dark Green
                  Color(0xFF0D47A1), // Dark Blue
                ],
              ),
            ),
          ),

          // Layer 3: Main Content (Same as before)
          SafeArea(
            child: SizedBox(
              width: double.infinity,
              child: Column(
                children: [
                  // 1. Top Status Bar
                  Container(
                    width: double.infinity,
                    color: Colors.black.withOpacity(0.2), // Slight contrast
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16.0,
                      vertical: 8.0,
                    ),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        // Left: BMTA | Time
                        Text(
                          'ขสมก. BMTA  |  $_timeString',
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 18,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        // Right: Signal & Settings
                        Row(
                          children: [
                            // Signal Icon Only
                            const Icon(
                              Icons.signal_cellular_4_bar,
                              color: Colors.greenAccent,
                              size: 20,
                            ),
                            const SizedBox(width: 8),

                            // Sync Status Icon
                            Icon(
                              _isSynced ? Icons.link : Icons.link_off,
                              color: _isSynced
                                  ? Colors.greenAccent
                                  : Colors.white30,
                              size: 20,
                            ),
                            const SizedBox(width: 8),

                            // Settings Button
                            GestureDetector(
                              onTap: _showSettingsDialog,
                              child: const Icon(
                                Icons.settings,
                                color: Colors.white54,
                                size: 24,
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),

                  // 2. Location Bar
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.symmetric(
                      vertical: 8,
                      horizontal: 16,
                    ),
                    color: Colors.black.withOpacity(0.1),
                    child: Row(
                      children: const [
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
                    'กรุณาแตะบัตร', // Updated Text
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 32,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 12),
                  const Text(
                    'รองรับบัตรเครดิต', // Updated Sub-text
                    style: TextStyle(color: Colors.white70, fontSize: 18),
                  ),

                  const SizedBox(height: 20),
                  const Spacer(),

                  // Bottom Status Indicators
                  Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: Colors.black.withOpacity(0.3),
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(color: Colors.white30),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        _buildStatusIcon(Icons.camera_alt, true),
                        const SizedBox(width: 16),
                        _buildStatusIcon(Icons.credit_card, true),
                      ],
                    ),
                  ),
                  const SizedBox(height: 10),
                ],
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
}
