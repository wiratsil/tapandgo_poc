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

void main() {
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

  // Transaction State
  final Map<String, PendingTransaction> _pendingTransactions = {};
  final Uuid _uuid = const Uuid();
  static const String _storageKey = 'pending_transactions';
  bool _isProcessing = false;
  bool _isLoading = false; // Add Loading State

  // Loading UI Helper (Matches MyHomePage style)
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

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _loadPendingTransactions();
      _startNfcPolling();
    });
  }

  @override
  void dispose() {
    _isProcessing = true; // Stop polling
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

  // Reuse existing logic for Tap In
  void _handleTapIn(QrData qrData) {
    final pending = PendingTransaction(
      aid: qrData.aid,
      tapInTime: DateTime.now().toUtc(),
      tapInLoc: TransactionLocation(lat: 0.0, lng: 0.0), // Mock
    );

    setState(() {
      _pendingTransactions[qrData.aid] = pending;
    });
    _savePendingTransactions();
    _showResultDialog(
      'Tap In Success',
      'AID: ${qrData.aid}\nBalance: ${qrData.bal}',
      isSuccess: true,
    );
  }

  // Reuse existing logic for Tap Out
  Future<void> _handleTapOut(QrData qrData) async {
    final pending = _pendingTransactions[qrData.aid]!;
    final tapOutTime = DateTime.now().toUtc();
    final tapOutLoc = TransactionLocation(lat: 0.0, lng: 0.0);

    final txnItem = TransactionItem(
      txnId: _uuid.v4(),
      assetId: qrData.aid,
      assetType: 'QR', // Metadata says QR but using for NFC too for POC
      tapInTime: pending.tapInTime.toIso8601String(),
      tapInLoc: pending.tapInLoc,
      tapOutTime: tapOutTime.toIso8601String(),
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
      'https://08hh39x2-5274.asse.devtunnels.ms/tap/transactions',
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
          'Tap Out Success',
          'ยอดคงเหลือ: 475.00 ฿',
          isSuccess: true,
          isTapOut: true,
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
            title: isTapOut ? 'สยามพารากอน' : 'อนุสาวรีย์ชัยฯ',
            price: isTapOut ? '25.00 ฿' : '0.00 ฿',
            message: message,
            isTapOut: isTapOut,
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

  Future<void> _manualTestNfc() async {
    debugPrint('Manual NFC Test Triggered');
    try {
      final isPresent = await _cpaySdkPlugin.isRfCardPresent();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('isRfCardPresent: $isPresent'),
            duration: const Duration(seconds: 1),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Error: $e')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    // If Loading, show Loading UI replacing everything
    if (_isLoading) {
      return Scaffold(backgroundColor: Colors.white, body: _buildLoadingUI());
    }

    return Scaffold(
      body: Container(
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
        child: SafeArea(
          child: Column(
            children: [
              // Top Bar
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16.0,
                  vertical: 12.0,
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Row(
                      children: const [
                        Icon(Icons.location_on, color: Colors.pinkAccent),
                        SizedBox(width: 8),
                        Text(
                          'อนุสาวรีย์ชัยฯ',
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 18,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ],
                    ),
                    const Text(
                      'EN | TH',
                      style: TextStyle(
                        color: Colors.yellow,
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
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
                'รองรับบัตร ขสมก. / บัตรเครดิต',
                style: TextStyle(color: Colors.white70, fontSize: 16),
              ),

              const SizedBox(height: 20),
              // TEST BUTTON
              TextButton.icon(
                onPressed: _manualTestNfc,
                icon: const Icon(Icons.nfc, color: Colors.white),
                label: const Text(
                  'Test isRfCardPresent',
                  style: TextStyle(color: Colors.white),
                ),
                style: TextButton.styleFrom(
                  backgroundColor: Colors.white.withOpacity(0.2),
                ),
              ),

              const Spacer(),

              // Bottom Button (Dashed Border simulated)
              Padding(
                padding: const EdgeInsets.only(bottom: 60.0),
                child: InkWell(
                  onTap: () {
                    Navigator.of(context).pushReplacement(
                      MaterialPageRoute(
                        builder: (context) =>
                            const MyHomePage(title: 'TapAndGo POC'),
                      ),
                    );
                  },
                  borderRadius: BorderRadius.circular(30),
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 32,
                      vertical: 16,
                    ),
                    decoration: BoxDecoration(
                      border: Border.all(
                        color: Colors.white,
                        style: BorderStyle.none,
                      ), // Using CustomPaint for real dashed if needed, but simple border first
                      borderRadius: BorderRadius.circular(30),
                      color: Colors.transparent, // Or semi-transparent
                    ),
                    child: CustomPaint(
                      painter: _DashedBorderPainter(
                        color: Colors.white,
                        strokeWidth: 2,
                        gap: 5,
                        dash: 5,
                        radius: 30,
                      ),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 16.0,
                          vertical: 8.0,
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: const [
                            Text(
                              'กดปุ่มเพื่อสแกน QR',
                              style: TextStyle(
                                color: Colors.white,
                                fontSize: 18,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                            SizedBox(width: 10),
                            Icon(Icons.qr_code_scanner, color: Colors.white),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// Helper class for dashed border
class _DashedBorderPainter extends CustomPainter {
  final Color color;
  final double strokeWidth;
  final double gap;
  final double dash;
  final double radius;

  _DashedBorderPainter({
    required this.color,
    this.strokeWidth = 1.0,
    this.gap = 5.0,
    this.dash = 5.0,
    this.radius = 0.0,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final Paint paint = Paint()
      ..color = color
      ..strokeWidth = strokeWidth
      ..style = PaintingStyle.stroke;

    final Path path = Path()
      ..addRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(0, 0, size.width, size.height),
          Radius.circular(radius),
        ),
      );

    PathDashPath(path: path, graph: this).draw(canvas, paint);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

class PathDashPath {
  final Path path;
  final _DashedBorderPainter graph;

  PathDashPath({required this.path, required this.graph});

  void draw(Canvas canvas, Paint paint) {
    PathMetrics pathMetrics = path.computeMetrics();
    for (PathMetric pathMetric in pathMetrics) {
      double distance = 0.0;
      while (distance < pathMetric.length) {
        canvas.drawPath(
          pathMetric.extractPath(distance, distance + graph.dash),
          paint,
        );
        distance += graph.dash + graph.gap;
      }
    }
  }
}

class MyHomePage extends StatefulWidget {
  const MyHomePage({super.key, required this.title});
  final String title;

  @override
  State<MyHomePage> createState() => _MyHomePageState();
}

class _MyHomePageState extends State<MyHomePage> {
  final _cpaySdkPlugin = CpaySdkPlugin();

  // State for Tap In/Out
  final Map<String, PendingTransaction> _pendingTransactions = {};
  final Uuid _uuid = const Uuid();
  String _loadingStatus = 'System Starting...';
  static const String _storageKey = 'pending_transactions';

  // Guard to prevent multiple processing
  bool _isProcessing = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _loadPendingTransactions().then((_) {
        // Trigger both Scan and NFC
        if (mounted) {
          _scanQr();
          _startNfcPolling();
        }
      });
    });
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

  void _navigateToWelcome() {
    Navigator.of(context).pushReplacement(
      MaterialPageRoute(builder: (context) => const WelcomeScreen()),
    );
  }

  Future<void> _startNfcPolling() async {
    // Polling loop for RF Card Presence
    while (mounted && !_isProcessing) {
      try {
        await _checkNfcOnce();
      } catch (e) {
        debugPrint('NFC Poll Error: $e');
      }
      // Wait before next poll
      await Future.delayed(const Duration(milliseconds: 500));
    }
  }

  Future<void> _checkNfcOnce() async {
    if (_isProcessing) return;
    try {
      final isPresent = await _cpaySdkPlugin.isRfCardPresent();
      debugPrint('isRfCardPresent result: $isPresent');

      if (isPresent == true) {
        _isProcessing = true;
        debugPrint('RF Card Detected!');
        await _cpaySdkPlugin.beep();

        final mockAid = 'RF-${DateTime.now().millisecondsSinceEpoch}';
        final nfcData = QrData(aid: mockAid, bal: 100.00);

        if (_pendingTransactions.containsKey(nfcData.aid)) {
          await _handleTapOut(nfcData);
        } else {
          _handleTapIn(nfcData);
        }
      }
    } catch (e) {
      debugPrint('Check NFC Error: $e');
    }
  }

  Future<void> _manualTestNfc() async {
    debugPrint('Manual NFC Test Triggered');
    try {
      final isPresent = await _cpaySdkPlugin.isRfCardPresent();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('isRfCardPresent: $isPresent'),
            duration: const Duration(seconds: 1),
          ),
        );
      }
      if (isPresent == true) {
        await _checkNfcOnce();
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Error: $e')));
      }
    }
  }

  Future<void> _scanQr() async {
    if (_isProcessing) return;
    try {
      final result = await _cpaySdkPlugin.scan(
        isFrontCamera: true,
        timeout: 60000,
      );

      if (result != null && !_isProcessing) {
        _isProcessing = true;
        await _processQrData(result);
      } else {
        // Scan cancelled or timed out
        // Only navigate back if we haven't processed a card
        if (mounted && !_isProcessing) _navigateToWelcome();
      }
    } catch (e) {
      debugPrint('Scan Error: $e');
      if (mounted && !_isProcessing) _navigateToWelcome();
    }
  }

  Future<void> _processQrData(String jsonString) async {
    try {
      final Map<String, dynamic> data = jsonDecode(jsonString);
      final qrData = QrData.fromJson(data);

      if (_pendingTransactions.containsKey(qrData.aid)) {
        // TAP OUT
        await _handleTapOut(qrData);
      } else {
        // TAP IN
        _handleTapIn(qrData);
      }
    } catch (e) {
      _showResultDialog(
        'Error',
        'Invalid Data Format: $e\nData: $jsonString',
        isSuccess: false,
      );
    }
  }

  void _handleTapIn(QrData qrData) {
    final pending = PendingTransaction(
      aid: qrData.aid,
      tapInTime: DateTime.now().toUtc(),
      tapInLoc: TransactionLocation(lat: 0.0, lng: 0.0), // Mock location
    );

    setState(() {
      _pendingTransactions[qrData.aid] = pending;
    });
    _savePendingTransactions();
    _showResultDialog(
      'Tap In Success',
      'AID: ${qrData.aid}\nBalance: ${qrData.bal}',
      isSuccess: true,
    );
  }

  Future<void> _handleTapOut(QrData qrData) async {
    final pending = _pendingTransactions[qrData.aid]!;
    final tapOutTime = DateTime.now().toUtc();
    final tapOutLoc = TransactionLocation(lat: 0.0, lng: 0.0); // Mock location

    final txnItem = TransactionItem(
      txnId: _uuid.v4(),
      assetId: qrData.aid,
      assetType: 'QR',
      tapInTime: pending.tapInTime.toIso8601String(),
      tapInLoc: pending.tapInLoc,
      tapOutTime: tapOutTime.toIso8601String(),
      tapOutLoc: tapOutLoc,
    );

    final payload = TransactionRequest(
      deviceId: 'ANDROID_POS_01',
      plateNo: '12-3456',
      transactions: [txnItem],
    );

    // Show processing status
    if (mounted) {
      setState(() {
        _loadingStatus = 'Processing...';
      });
    }

    await _submitTransaction(payload, qrData.aid);
  }

  Future<void> _submitTransaction(
    TransactionRequest payload,
    String aid,
  ) async {
    final url = Uri.parse(
      'https://08hh39x2-5274.asse.devtunnels.ms/tap/transactions',
    );
    try {
      final response = await http.post(
        url,
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode(payload.toJson()),
      );

      // Close loading dialog (not needed as we simply navigate away or show result)
      // if (mounted) Navigator.pop(context);

      if (response.statusCode >= 200 && response.statusCode < 300) {
        setState(() {
          _pendingTransactions.remove(aid);
        });
        _savePendingTransactions();
        _showResultDialog(
          'Tap Out Success',
          'ยอดคงเหลือ: 475.00 ฿', // Mock balance for POC
          isSuccess: true,
          isTapOut: true,
        );
      } else {
        _showResultDialog(
          'Tap Out Failed',
          'API Error: ${response.statusCode}\n${response.body}',
          isSuccess: false,
        );
      }
    } catch (e) {
      // Close loading dialog if error
      // if (mounted) Navigator.pop(context);
      _showResultDialog('Tap Out Error', '$e', isSuccess: false);
    }
  }

  void _showResultDialog(
    String title,
    String message, {
    required bool isSuccess,
    bool isTapOut = false,
  }) {
    if (!mounted) return;

    if (isSuccess) {
      // Navigate to the full-screen Success Design
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(
          builder: (context) => SuccessResultScreen(
            onDismiss: (ctx) {
              Navigator.of(ctx).pushReplacement(
                MaterialPageRoute(builder: (_) => const WelcomeScreen()),
              );
            },
            title: isTapOut
                ? 'สยามพารากอน'
                : 'อนุสาวรีย์ชัยฯ', // Mock logic for POC
            price: isTapOut ? '25.00 ฿' : '0.00 ฿', // Mock logic for POC
            message: message,
            isTapOut: isTapOut,
          ),
        ),
      );
    } else {
      // Navigate to the full-screen Error Design
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(
          builder: (context) => ErrorResultScreen(
            onDismiss: (ctx) {
              Navigator.of(ctx).pushReplacement(
                MaterialPageRoute(builder: (_) => const WelcomeScreen()),
              );
            },
            errorTitle: 'ทำรายการไม่สำเร็จ',
            // errorMessage: message, // Use default static message per user request
          ),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      body: SafeArea(
        child: SizedBox(
          width: double.infinity,
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Spacer(),
              // Bus Icon (Simulated with standard icon and colors)
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
              Text(
                _loadingStatus,
                style: const TextStyle(
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

              const Spacer(),

              TextButton.icon(
                onPressed: _manualTestNfc,
                icon: const Icon(Icons.nfc),
                label: const Text('Test Test isRfCardPresent'),
              ),

              const SizedBox(height: 10),
            ],
          ),
        ),
      ),
    );
  }
}
