import 'dart:convert';
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:cpay_sdk_plugin/cpay_sdk_plugin.dart';
import 'package:http/http.dart' as http;
import 'package:uuid/uuid.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'models/transaction_model.dart';

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

class WelcomeScreen extends StatelessWidget {
  const WelcomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
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
  static const String _storageKey = 'pending_transactions';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _loadPendingTransactions().then((_) {
        // Trigger scan immediately after loading data
        if (mounted) _scanQr();
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

  Future<void> _scanQr() async {
    try {
      final result = await _cpaySdkPlugin.scan(
        isFrontCamera: true,
        timeout: 60000,
      );

      if (result != null) {
        await _processQrData(result);
      } else {
        // Scan cancelled or timed out (returned null)
        if (mounted) _navigateToWelcome();
      }
    } catch (e) {
      // Handle error gracefully (likely a timeout or camera issue)
      debugPrint('Scan Error: $e');
      if (mounted) _navigateToWelcome();
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

    // Show processing dialog or loading
    if (mounted) {
      showDialog(
        context: context,
        barrierDismissible: false,
        builder: (context) => const Center(child: CircularProgressIndicator()),
      );
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

      // Close loading dialog
      if (mounted) Navigator.pop(context);

      if (response.statusCode >= 200 && response.statusCode < 300) {
        setState(() {
          _pendingTransactions.remove(aid);
        });
        _savePendingTransactions();
        _showResultDialog(
          'Tap Out Success',
          'Sent to API: ${response.statusCode}',
          isSuccess: true,
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
      if (mounted) Navigator.pop(context);
      _showResultDialog('Tap Out Error', '$e', isSuccess: false);
    }
  }

  void _showResultDialog(
    String title,
    String message, {
    required bool isSuccess,
  }) {
    if (!mounted) return;
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        title: Text(
          title,
          style: TextStyle(color: isSuccess ? Colors.green : Colors.red),
        ),
        content: Text(message, style: const TextStyle(fontSize: 18)),
        actions: [
          TextButton(
            onPressed: () {
              Navigator.pop(context); // Close dialog
              Navigator.pop(context); // Go back to WelcomeScreen
            },
            child: const Text('OK', style: TextStyle(fontSize: 20)),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    // Show a black screen to transition smoothly to camera
    return const Scaffold(
      backgroundColor: Colors.black,
      body: SizedBox.shrink(),
    );
  }
}
