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
import 'package:mobile_scanner/mobile_scanner.dart';
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
import 'models/bus_trip_model.dart';
import 'services/app_audio_service.dart';
import 'services/receipt_image_service.dart';
import 'system_checklist_screen.dart';
import 'package:sqflite/sqflite.dart';

import 'package:qr_flutter/qr_flutter.dart';

import 'package:wakelock_plus/wakelock_plus.dart';

class MyHttpOverrides extends HttpOverrides {
  @override
  HttpClient createHttpClient(SecurityContext? context) {
    return super.createHttpClient(context)
      ..badCertificateCallback =
          (X509Certificate cert, String host, int port) => true;
  }
}

class _SystemCheckIssue {
  final String topic;
  final String indicator;
  final String impact;

  const _SystemCheckIssue({
    required this.topic,
    required this.indicator,
    required this.impact,
  });
}

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = MyHttpOverrides(); // Fix for Android 5 SSL Handshake
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
  static const String _qrLandingPageUrl =
      'https://08hh39x2-5234.asse.devtunnels.ms/qrcode.html';
  static const String _qrScannerModeKey = 'show_qr_scanner';
  static const String _receiptLogoAsset = 'assets/BMTA_Logo.png';
  static final Uri _transactionsUrl = Uri.parse(
    'https://tng-platform-dev.atlasicloud.com/api/tng/tap/transactions',
  );
  static final Uri _flatRateTransactionsUrl = Uri.parse(
    'https://tng-platform-dev.atlasicloud.com/api/tng/tap/transactions/flat-rate',
  );

  final _posService = PosService();
  late MobileScannerController _qrScannerController;
  // final _cpaySdkPlugin = CpaySdkPlugin(); // Refactored into PosService

  // Prevent auto sync from running again when returning to this screen
  static bool _hasAutoSynced = false;

  static const List<AppSound> _welcomeSoundSequence = [AppSound.welcome];

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
  bool _useDeviceGps = false; // GPS source toggle for NFC fare calculation

  StreamSubscription<bool>? _nfcSubscription;
  StreamSubscription<String>? _posQrSubscription;
  String _qrCodePayload = ''; // Payload for the generated QR Code
  bool _showQrScanner = false;
  bool _showSimulateButtons = false;
  bool _isQrScanDialogOpen = false;
  String? _lastQrScanValue;
  DateTime? _lastQrScanTime;

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
  MobileScannerController _createQrScannerController() {
    return MobileScannerController(facing: CameraFacing.front);
  }

  List<AppSound> _tapInSuccessSounds({required bool isNfc}) {
    return isNfc
        ? const [AppSound.tapCard, AppSound.successful]
        : const [AppSound.scanQr, AppSound.successful];
  }

  List<AppSound> _tapOutSuccessSounds({required bool isNfc}) {
    return isNfc
        ? const [AppSound.tapCard, AppSound.payment, AppSound.successful]
        : const [AppSound.scanQr, AppSound.payment, AppSound.successful];
  }

  List<AppSound> _failureSounds({
    required bool isNfc,
    bool includeSourceCue = true,
  }) {
    if (!includeSourceCue) {
      return const [AppSound.unsuccessful, AppSound.tryAgain];
    }

    return isNfc
        ? const [
            AppSound.tapCard,
            AppSound.unsuccessful,
            AppSound.tryAgain,
          ]
        : const [
            AppSound.scanQr,
            AppSound.unsuccessful,
            AppSound.tryAgain,
          ];
  }

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
    final a = sin(dLat / 2) * sin(dLat / 2) +
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

  String _formatReceiptDateTime(DateTime dt) {
    final local = dt.toLocal();
    final hour = local.hour.toString().padLeft(2, '0');
    final minute = local.minute.toString().padLeft(2, '0');
    const months = [
      'ม.ค.',
      'ก.พ.',
      'มี.ค.',
      'เม.ย.',
      'พ.ค.',
      'มิ.ย.',
      'ก.ค.',
      'ส.ค.',
      'ก.ย.',
      'ต.ค.',
      'พ.ย.',
      'ธ.ค.',
    ];
    return '${local.day.toString().padLeft(2, '0')} ${months[local.month - 1]} ${local.year + 543}, $hour:$minute น.';
  }

  Future<void> _printArkeReceipt({
    required String txnId,
    required DateTime tapInTime,
    required DateTime tapOutTime,
    required String tapInStopName,
    required String tapOutStopName,
    required double fareAmount,
    String? logNo,
  }) async {
    if (!_posService.isArke || fareAmount <= 0) return;

    try {
      debugPrint('[PRINT] Printing receipt for txnId=$txnId');
      final imageBytes = await ReceiptImageService.buildReceiptImage(
        logoAssetPath: _receiptLogoAsset,
        title: 'รายการสำเร็จ',
        statusText: 'การชำระเงินสำเร็จ',
        timestampText: _formatReceiptDateTime(tapOutTime),
        sectionTitle: 'ข้อมูลการชำระค่าโดยสาร',
        fields: [
          ReceiptImageField(label: 'สายรถโดยสาร', value: _plateNumber),
          ReceiptImageField(label: 'เลขอ้างอิง', value: logNo ?? '-'),
          ReceiptImageField(label: 'เลขที่ทำรายการ', value: txnId),
          ReceiptImageField(
            label: 'เวลาแตะขึ้น',
            value: _formatReceiptDateTime(tapInTime),
          ),
          ReceiptImageField(
            label: 'เวลาแตะลง',
            value: _formatReceiptDateTime(tapOutTime),
          ),
          ReceiptImageField(
            label: 'สถานีต้นทาง',
            value: tapInStopName,
          ),
          ReceiptImageField(
            label: 'สถานีปลายทาง',
            value: tapOutStopName,
          ),
          const ReceiptImageField(label: 'จำนวนผู้โดยสาร', value: '1 ท่าน'),
          const ReceiptImageField(label: 'ค่าธรรมเนียม', value: '0.00'),
        ],
        totalLabel: 'ค่าโดยสารรวม',
        totalValue: fareAmount.toStringAsFixed(2),
        paymentMethod: 'บัตร EMV',
        discountText: 'ไม่มีสิทธิลดหย่อน',
        transactionNo: txnId,
        footerText: 'ขอบคุณที่ใช้บริการ',
      );
      await _posService.printImageBytes(imageBytes, align: 1);
      debugPrint('[PRINT] Receipt printed successfully');
    } catch (e) {
      debugPrint('[PRINT] Receipt print failed: $e');
    }
  }

  String _buildQrCodePayloadUrl(Map<String, dynamic> payload) {
    final landingPageUri = Uri.parse(_qrLandingPageUrl);
    return landingPageUri.replace(queryParameters: {
      ...landingPageUri.queryParameters,
      'payload': jsonEncode(payload),
    }).toString();
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
  bool _isOfflineMode = false;
  String _lastScanLog = '';
  String _latestLogNo = '';
  Timer? _timer;
  Timer? _systemChecklistTimer;
  bool _hasInternet = false;
  int _routeDetailsCount = 0;
  int _priceRangesCount = 0;
  bool _lastChecklistGpsReady = false;
  bool _lastChecklistAudioReady = false;
  bool _hasActiveBusTrip = false;
  int? _checklistRouteId;
  String _checklistBusNo = '';

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
    _qrScannerController = _createQrScannerController();
    WidgetsBinding.instance.addObserver(this);
    _ignoreNfcEventsUntil = DateTime.now().add(_startupNfcWarmup);
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      await _loadPlateNumber();
      _loadPendingTransactions();

      // Check for internet if not in offline mode and plate number is set
      if (!_isOfflineMode && _plateNumber.isNotEmpty) {
        final hasInternet = await _checkInternetConnection();
        if (!hasInternet && mounted) {
          _promptOfflineMode();
        }
      }

      // Initialize POS Service FIRST (Detect Device: Arke or CPay)
      await _posService.init();
      await _posService.initVas(); // Initialize VAS Service
      if (mounted) setState(() {});
      await _syncDedicatedQrScannerMode();

      // Set up VAS event listener
      _posService.onVasEvent?.listen((event) async {
        debugPrint('[VAS] Event Type: ${event.type}, Data: ${event.data}');

        // Reset the NFC scan cooldown so ghost scans are ignored right after returning to our app
        _lastScannedTime = DateTime.now();

        if (mounted) {
          setState(() {
            _lastScanLog = 'VAS Event: ${event.type}\nData:\n${event.data}';
          });
        }

        if (event.type == 'onComplete') {
          if (!_vasSaleInProgress) {
            debugPrint(
              '[VAS] Ignoring stale onComplete because no app-initiated vasSale is active.',
            );
            return;
          }
          final saleAgeMs = _vasSaleStartedAt == null
              ? null
              : DateTime.now().difference(_vasSaleStartedAt!).inMilliseconds;
          debugPrint(
            '[VAS] Processing app-initiated onComplete (saleAgeMs=$saleAgeMs)',
          );
          _vasSaleInProgress = false;
          _vasSaleStartedAt = null;
          // Parse VAS event data
          try {
            Map<String, dynamic> data = {};
            if (event.data is String) {
              data = jsonDecode(event.data as String) as Map<String, dynamic>;
            } else if (event.data is Map) {
              data = Map<String, dynamic>.from(event.data as Map);
            }

            final code = data['code']?.toString() ??
                data['responseCode']?.toString() ??
                data['status']?.toString() ??
                data['responseCodeThirtyNine']?.toString();
            final msg = data['message']?.toString() ??
                data['responseMessage']?.toString() ??
                data['error']?.toString() ??
                event.data.toString();

            if (code == '1' ||
                code == '0' ||
                code == '00' ||
                code == '200' ||
                code == 'SUCCESS' ||
                code == 'success') {
              // Extract card info and log number for our custom flow
              final String? cardNumber =
                  data['cardNumber']?.toString() ?? data['cardNo']?.toString();
              final String? logNo = data['logNo']?.toString() ??
                  data['voucherNumber']?.toString() ??
                  data['referenceNumber']?.toString();

              if (logNo != null && logNo.isNotEmpty && mounted) {
                setState(() {
                  _latestLogNo = logNo;
                });
              }

              if (cardNumber != null && cardNumber.isNotEmpty) {
                final pendingKey = _findPendingTransactionKey(cardNumber);
                debugPrint(
                    '[VAS] ✅ Sale 1 THB Success. Card: $cardNumber, LogNo: $logNo');

                debugPrint(
                  '[VAS] Pending lookup => raw="$cardNumber", normalized="${_normalizeCardKey(cardNumber)}", matchedKey="$pendingKey", pendingKeys=${_pendingTransactions.keys.toList()}',
                );

                // Determine if this is Tap In or Tap Out based on cardNumber
                // We use aid as a primary key, so we'll map cardNumber to aid
                final nfcData = QrData(
                  aid: pendingKey ?? _normalizeCardKey(cardNumber),
                  bal: 100.00,
                );

                if (pendingKey != null) {
                  await _handleTapOut(nfcData,
                      isNfc: true, cardNumber: cardNumber, logNo: logNo);
                } else {
                  await _handleTapIn(nfcData,
                      isNfc: true, cardNumber: cardNumber, logNo: logNo);
                }
              } else {
                debugPrint(
                  '[VAS] Ignoring successful VAS event without card number.',
                );
                if (mounted) {
                  setState(() {
                    _isProcessing = false;
                    _isLoading = false;
                  });
                }
              }
            } else {
              String cause = 'ระบบไม่สามารถดึงเงินจากบัตรได้';
              if (code == '2') {
                cause = 'แตะบัตรไม่สำเร็จ หรือดึงบัตรออกเร็วเกินไป';
              } else if (code == '-1' || code == 'USER_CANCEL') {
                cause = 'ผู้ใช้ยกเลิกการทำรายการผ่านหน้าเครื่อง';
              } else if (code == '51') {
                cause = 'ยอดเงินในบัตรไม่เพียงพอ';
              } else if (code == '54') {
                cause = 'บัตรหมดอายุ หรือบัตรถูกระงับ';
              }

              _showResultDialog(
                  'ชำระเงินไม่สำเร็จ', 'Code: $code\nMessage: $msg',
                  isSuccess: false,
                  instruction: cause,
                  soundSequence: _failureSounds(isNfc: true));
            }
          } catch (e) {
            debugPrint('[VAS] Parse error: $e');
            _showResultDialog(
                'สถานะไม่ชัดเจน', 'Error: $e\n\nRaw Data:\n${event.data}',
                isSuccess: false, soundSequence: _failureSounds(isNfc: true));
          }
        } else if (event.type == 'onError') {
          if (!_vasSaleInProgress) {
            debugPrint(
              '[VAS] Ignoring stale onError because no app-initiated vasSale is active.',
            );
            return;
          }
          final saleAgeMs = _vasSaleStartedAt == null
              ? null
              : DateTime.now().difference(_vasSaleStartedAt!).inMilliseconds;
          debugPrint(
            '[VAS] Processing app-initiated onError (saleAgeMs=$saleAgeMs)',
          );
          _vasSaleInProgress = false;
          _vasSaleStartedAt = null;
          _showResultDialog('ข้อผิดพลาด', 'ไม่สามารถทำรายการได้\n${event.data}',
              isSuccess: false, soundSequence: _failureSounds(isNfc: true));
        }
      });

      // Then start scanning (uses device type from PosService)
      await _requestAllPermissions();
      _setupPendingSyncListener();
      _updateTime();
      _timer = Timer.periodic(const Duration(seconds: 1), (_) => _updateTime());
      await AppAudioService.instance.init();
      unawaited(_refreshSystemChecklistStatus());
      _systemChecklistTimer = Timer.periodic(
        const Duration(seconds: 10),
        (_) => unawaited(_refreshSystemChecklistStatus()),
      );

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
              _submitEmvTransaction(
                pending.payload,
                routeId: pending.routeId,
                logNo: pending.logNo,
              );
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

            // Create QR payload
            String newQrPayload = '';
            if (nearestStop != null) {
              final activeBusTrip = await _dbHelper.getActiveBusTrip();
              final routeId = await _dbHelper.getFirstRouteId();
              final qrPayloadMap = {
                "busTripId": activeBusTrip?.id ?? 0,
                "buslineId": activeBusTrip?.buslineId ?? 0,
                "routeId": activeBusTrip?.routeId ?? routeId ?? 0,
                "gpsTimeStamp": gpsData.rec != null
                    ? gpsData.rec!.toUtc().toIso8601String()
                    : DateTime.now().toUtc().toIso8601String(),
                "latitudeGPS": gpsData.lat,
                "longitudeGPS": gpsData.lng,
                "busStopId": nearestStop.busstopId,
                "busStopName": nearestStop.busstopDesc,
                "licensePlate": _plateNumber,
              };
              newQrPayload = _buildQrCodePayloadUrl(qrPayloadMap);
            }

            if (mounted) {
              setState(() {
                _qrCodePayload = newQrPayload;
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

      unawaited(AppAudioService.instance.playSequence(_welcomeSoundSequence));
    });
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
      unawaited(_refreshSystemChecklistStatus());
    }
  }

  Future<void> _handleClearCache() async {
    // 1. Clear Data in SQLite
    await _dbHelper.clearAllData();

    // 2. Clear local variables & pending transactions
    setState(() {
      _pendingTransactions.clear();
      _gpsHistory.clear();
      _lastScanLog = '';
      _pendingEmvRequests.clear();
      _pendingTapInGpsQueue.clear();
      _resolvedTapInGps.clear();
      _routeDetailsCount = 0;
      _priceRangesCount = 0;
      _lastChecklistGpsReady = false;
      _lastChecklistAudioReady = false;
      _hasActiveBusTrip = false;
      _checklistRouteId = null;
      _checklistBusNo = '';
    });

    // 3. Save (overwrite) pending transactions in SharedPreferences to empty
    await _savePendingTransactions();

    // 4. Force a re-sync of configuration data
    _hasAutoSynced = false;
    await Future.delayed(const Duration(milliseconds: 500));
    await _syncData();
    unawaited(_refreshSystemChecklistStatus());

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('✅ ล้างข้อมูลแคชสำเร็จ')),
      );
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

  // Duplicate scan protection
  String? _lastScannedCardId;
  DateTime? _lastScannedTime;
  static const Duration _startupNfcWarmup = Duration(seconds: 5);
  DateTime? _ignoreNfcEventsUntil;
  bool _vasSaleInProgress = false;
  DateTime? _vasSaleStartedAt;

  // GPS source toggle helper
  Future<(double, double)> _getGpsForNfc() async {
    try {
      final pos = await _locationService.getCurrentPosition();
      if (pos != null) {
        debugPrint(
            '[GPS] 📱 Device GPS: lat=${pos.latitude}, lng=${pos.longitude}');
        return (pos.latitude, pos.longitude);
      }
    } catch (e) {
      debugPrint('[GPS] ❌ Device GPS error: $e');
    }
    debugPrint('[GPS] ⚠️ Device GPS unavailable, falling back to MQTT');
    return (_currentGpsData?.lat ?? 0.0, _currentGpsData?.lng ?? 0.0);
  }

  void _setUseDeviceGps(bool value) async {
    setState(() => _useDeviceGps = value);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('use_device_gps', value);
    debugPrint(
        '[GPS] 🔧 GPS source changed to: ${value ? "Device GPS" : "MQTT GPS"}');
  }

  void _setShowQrScanner(bool value) async {
    setState(() => _showQrScanner = value);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_qrScannerModeKey, value);
    unawaited(_refreshSystemChecklistStatus());
    await _syncDedicatedQrScannerMode();
    debugPrint(
      '[QR] Display mode changed to: ${value ? "Scanner" : "QR Code"}',
    );
  }

  void _resetQrScanner() {
    if (!mounted) return;

    setState(() {
      if (!_posService.isTapgo) {
        _qrScannerController.dispose();
        _qrScannerController = _createQrScannerController();
      }
      _isQrScanDialogOpen = false;
      _lastQrScanValue = null;
      _lastQrScanTime = null;
    });

    unawaited(_syncDedicatedQrScannerMode());
    debugPrint('[QR] Scanner controller reset');
  }

  Future<void> _syncDedicatedQrScannerMode() async {
    if (!_posService.isTapgo) {
      return;
    }

    _posQrSubscription ??= _posService.onQrCodeDetected.listen((rawValue) {
      unawaited(_handleScannedQrValue(rawValue, source: 'tapgo'));
    });

    if (_showQrScanner) {
      await _posService.startQrScanning();
    } else {
      await _posService.stopQrScanning();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _timer?.cancel();
    _systemChecklistTimer?.cancel();
    _pendingSyncSubscription?.cancel();
    _gpsSubscription?.cancel();
    _posQrSubscription?.cancel();
    _mqttService.disconnect();
    _stopBackgroundScanning();
    unawaited(_posService.stopQrScanning());
    _qrScannerController.dispose();
    _posService.dispose();
    unawaited(AppAudioService.instance.dispose());
    super.dispose();
  }

  // ============ Permission Handling ============
  Future<void> _requestAllPermissions() async {
    // Cleanup NFC only
    debugPrint('Cleaning up any existing sessions...');
    try {
      await _posService.stopNfcPolling();
    } catch (e) {
      debugPrint('Cleanup error (can be ignored): $e');
    }

    await Future.delayed(const Duration(milliseconds: 300));

    debugPrint('Requesting Location permission...');
    final locationStatus = await Permission.location.request();
    debugPrint('Location permission status: $locationStatus');

    debugPrint('Requesting Storage permission...');
    final storageStatus = await Permission.storage.request();
    debugPrint('Storage permission status: $storageStatus');

    // Handle Location Logic
    if (!locationStatus.isGranted) {
      debugPrint('Location permission denied');
    }

    // Start background scanning (which now only handles NFC)
    await _startBackgroundScanning();
  }

  // ============ Background Scanning ============
  Future<void> _startBackgroundScanning() async {
    if (_isBackgroundScanningActive) {
      debugPrint('Background scanning already active, skipping...');
      return;
    }

    debugPrint('Starting background scanning...');
    _isBackgroundScanningActive = true;

    // Start Background NFC Polling IMMEDIATELY (Do not await to prevent blocking)
    _startNfcPollingUnified();
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

  Future<void> _stopBackgroundScanning() async {
    if (!_isBackgroundScanningActive) return;

    debugPrint('Stopping background scanning...');
    _isBackgroundScanningActive = false;

    await _nfcSubscription?.cancel();
    _nfcSubscription = null;

    try {
      await _posService.stopNfcPolling();
    } catch (e) {
      debugPrint('Error stopping background scanning: $e');
    }
  }

  // ============ Event Handlers ============
  Future<void> _handleNfcDetected() async {
    final now = DateTime.now();
    final ignoreUntil = _ignoreNfcEventsUntil;
    if (ignoreUntil != null && now.isBefore(ignoreUntil)) {
      debugPrint(
        '[NFC] Ignoring startup NFC event until $ignoreUntil',
      );
      return;
    }

    if (_isProcessing || _isLoading) return;
    if (_vasSaleInProgress) {
      debugPrint('[NFC] Ignoring NFC event while VAS sale is in progress');
      return;
    }

    _isProcessing = true;
    _vasSaleInProgress = _posService.supportsVas;
    _vasSaleStartedAt = _posService.supportsVas ? now : null;

    if (mounted) {
      setState(() {
        _isLoading = true;
      });
    }

    try {
      if (_posService.supportsVas) {
        debugPrint('[NFC] 💳 Starting 1 THB sale for card identification...');
        await _posService.vasSale(1.0);
        // Processing and Loading will be reset in onVasEvent
        return;
      }

      debugPrint('[NFC] 💳 Starting direct card read...');
      await _handleDirectNfcDetected();
    } catch (e) {
      debugPrint('[NFC] ❌ SDK flow failed: $e');
      _resetActiveNfcFlow();
      _showResultDialog('ข้อผิดพลาด', 'ไม่สามารถอ่านข้อมูลบัตรได้\n$e',
          isSuccess: false, soundSequence: _failureSounds(isNfc: true));
    }
  }

  void _resetActiveNfcFlow() {
    _vasSaleInProgress = false;
    _vasSaleStartedAt = null;

    if (mounted) {
      setState(() {
        _isProcessing = false;
        _isLoading = false;
      });
      return;
    }

    _isProcessing = false;
    _isLoading = false;
  }

  Future<void> _handleDirectNfcDetected() async {
    final cardRead = await _posService.readCardId();
    final rawCardId = cardRead?.cardId.trim();
    if (rawCardId == null || rawCardId.isEmpty) {
      debugPrint('[NFC] No card data returned from POS plugin');
      _resetActiveNfcFlow();
      return;
    }

    debugPrint('[NFC] Direct card read success: $rawCardId');
    _vasSaleInProgress = false;
    _vasSaleStartedAt = null;

    final pendingKey = _findPendingTransactionKey(rawCardId);
    final nfcData = QrData(
      aid: pendingKey ?? _normalizeCardKey(rawCardId),
      bal: 100.00,
    );

    if (pendingKey != null) {
      await _handleTapOut(
        nfcData,
        isNfc: true,
        cardNumber: rawCardId,
      );
      return;
    }

    await _handleTapIn(
      nfcData,
      isNfc: true,
      cardNumber: rawCardId,
    );
  }

  // ============ Shared Logic ============
  Future<void> _loadPlateNumber() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final savedPlate = prefs.getString('plate_number');
      final savedOffline = prefs.getBool('offline_mode') ?? false;
      final savedUseDeviceGps = prefs.getBool('use_device_gps') ?? false;
      final savedShowQrScanner = prefs.getBool(_qrScannerModeKey) ?? false;
      if (mounted) {
        setState(() {
          if (savedPlate != null) _plateNumber = savedPlate;
          _isOfflineMode = savedOffline;
          _useDeviceGps = savedUseDeviceGps;
          _showQrScanner = savedShowQrScanner;
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

  String _normalizeCardKey(String value) {
    return value.replaceAll(RegExp(r'[^A-Za-z0-9]'), '').toUpperCase();
  }

  String? _findPendingTransactionKey(String rawCardNumber) {
    final normalizedInput = _normalizeCardKey(rawCardNumber);

    if (_pendingTransactions.containsKey(rawCardNumber)) {
      return rawCardNumber;
    }

    for (final entry in _pendingTransactions.entries) {
      final pendingKey = _normalizeCardKey(entry.key);
      final pendingCardNumber = entry.value.cardNumber == null
          ? ''
          : _normalizeCardKey(entry.value.cardNumber!);

      if (pendingKey == normalizedInput ||
          pendingCardNumber == normalizedInput) {
        return entry.key;
      }
    }

    return null;
  }

  // ============ Tap In / Tap Out Logic ============
  Future<void> _handleTapIn(QrData qrData,
      {bool isNfc = false, String? cardNumber, String? logNo}) async {
    // Get current location — check GPS source for NFC
    double lat;
    double lng;
    if (isNfc && _useDeviceGps) {
      final gps = await _getGpsForNfc();
      lat = gps.$1;
      lng = gps.$2;
      debugPrint('[DEBUG] 📍 Using Device GPS (Tap In): lat=$lat, lng=$lng');
    } else {
      lat = _currentGpsData?.lat ?? 0.0;
      lng = _currentGpsData?.lng ?? 0.0;
      if (lat != 0.0 && lng != 0.0) {
        debugPrint('[DEBUG] 📍 Using GPS from MQTT: lat=$lat, lng=$lng');
      } else {
        debugPrint('[DEBUG] ⚠️ GPS not found or 0.0, using Mock Location');
      }
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
      cardNumber: cardNumber,
      logNo: logNo,
    );

    setState(() {
      _pendingTransactions[qrData.aid] = pending;
    });
    debugPrint(
      '[TAP] Stored pending => key="${qrData.aid}", cardNumber="$cardNumber", pendingKeys=${_pendingTransactions.keys.toList()}',
    );
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
      soundSequence: _tapInSuccessSounds(isNfc: isNfc),
    );
  }

  Future<void> _handleTapOut(QrData qrData,
      {bool isNfc = false, String? cardNumber, String? logNo}) async {
    // Check internet connectivity before Tap Out (skip in offline mode)
    if (!_isOfflineMode) {
      final hasInternet = await _checkInternetConnection();
      if (!hasInternet) {
        _showResultDialog(
          'ไม่มีสัญญาณอินเทอร์เน็ต',
          'กรุณาเชื่อมต่ออินเทอร์เน็ตก่อนลงรถ',
          isSuccess: false,
          soundSequence: _failureSounds(isNfc: isNfc),
        );
        return;
      }
    }

    final pending = _pendingTransactions[qrData.aid]!;
    final tapOutTime = DateTime.now().toUtc();

    // Get current location for Tap Out — check GPS source for NFC
    double lat;
    double lng;
    if (isNfc && _useDeviceGps) {
      final gps = await _getGpsForNfc();
      lat = gps.$1;
      lng = gps.$2;
      debugPrint('[DEBUG] 📍 Using Device GPS (Tap Out): lat=$lat, lng=$lng');
    } else {
      lat = _currentGpsData?.lat ?? 0.0;
      lng = _currentGpsData?.lng ?? 0.0;
      if (lat != 0.0 && lng != 0.0) {
        debugPrint(
            '[DEBUG] 📍 Using GPS from MQTT (Tap Out): lat=$lat, lng=$lng');
      } else {
        debugPrint('[DEBUG] ⚠️ GPS not found (Tap Out)');
      }
    }

    debugPrint('[DEBUG] 🔎 TapOut Coords Used: $lat, $lng');
    debugPrint(
      '[DEBUG] 🔎 TapIn Coords from Pending: ${pending.tapInLoc.lat}, ${pending.tapInLoc.lng}',
    );

    final tapOutLoc = TransactionLocation(lat: lat, lng: lng);

    final txnItem = TransactionItem(
      txnId: _uuid.v4(),
      assetId: qrData.aid,
      assetType: isNfc ? 'NFC' : 'QRCODE',
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

    await _submitTransaction(payload, qrData.aid,
        routeId: pending.routeId, isNfc: isNfc, logNo: logNo ?? pending.logNo);
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

  bool _hasFreshGpsSignal() {
    final latestGps =
        _currentGpsData ?? (_gpsHistory.isNotEmpty ? _gpsHistory.last : null);
    if (latestGps == null || latestGps.lat == 0 || latestGps.lng == 0) {
      return false;
    }

    final recordedAt = latestGps.rec?.toLocal();
    if (recordedAt == null) return true;

    final ageSeconds = DateTime.now().difference(recordedAt).inSeconds;
    return ageSeconds >= -60 && ageSeconds <= 300;
  }

  bool get _isTripReady =>
      _hasActiveBusTrip ||
      ((_activeRouteId ?? 0) != 0 &&
          _routeDetailsCount > 0 &&
          _priceRangesCount > 0);

  bool get _isReaderReady =>
      _posService.type != PosType.unknown || _showQrScanner;

  bool get _isAudioReady => AppAudioService.instance.isReady;

  bool get _isSystemReady =>
      _hasInternet &&
      _hasFreshGpsSignal() &&
      _isTripReady &&
      _isReaderReady &&
      _isAudioReady;

  Future<void> _refreshSystemChecklistStatus() async {
    final hasInternet = await _checkInternetConnection();
    final activeTrip = await _dbHelper.getActiveBusTrip();
    final routeDetailsCount = await _dbHelper.getRouteDetailsCount();
    final priceRangesCount = await _dbHelper.getPriceRangesCount();

    if (!mounted) return;

    final nextRouteId = activeTrip?.routeId ?? _activeRouteId;
    final nextBusNo = activeTrip?.busno.trim() ?? '';
    final gpsReady = _hasFreshGpsSignal();
    final audioReady = _isAudioReady;
    final hasActiveBusTrip = activeTrip != null;

    if (_hasInternet != hasInternet ||
        _routeDetailsCount != routeDetailsCount ||
        _priceRangesCount != priceRangesCount ||
        _lastChecklistGpsReady != gpsReady ||
        _lastChecklistAudioReady != audioReady ||
        _hasActiveBusTrip != hasActiveBusTrip ||
        _checklistRouteId != nextRouteId ||
        _checklistBusNo != nextBusNo) {
      setState(() {
        _hasInternet = hasInternet;
        _routeDetailsCount = routeDetailsCount;
        _priceRangesCount = priceRangesCount;
        _lastChecklistGpsReady = gpsReady;
        _lastChecklistAudioReady = audioReady;
        _hasActiveBusTrip = hasActiveBusTrip;
        _checklistRouteId = nextRouteId;
        _checklistBusNo = nextBusNo;
      });
    }
  }

  Future<void> _openSystemChecklist() async {
    unawaited(_refreshSystemChecklistStatus());

    final routeId = _checklistRouteId ?? _activeRouteId;
    final routeLabel = routeId != null && routeId != 0 ? '$routeId' : '-';
    final busLabel = _checklistBusNo.isNotEmpty
        ? _checklistBusNo
        : _plateNumber.trim().isNotEmpty
            ? _plateNumber.trim()
            : '-';

    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => SystemChecklistScreen(
          routeLabel: routeLabel,
          busLabel: busLabel,
          internetReady: _hasInternet,
          initialGpsReady: _hasFreshGpsSignal(),
          tripReady: _isTripReady,
          readerReady: _isReaderReady,
          audioReady: _isAudioReady,
          tripStatusLabel: _isTripReady ? 'Status 3' : 'Status -',
          gpsStream: _mqttService.gpsStream,
        ),
      ),
    );

    unawaited(_refreshSystemChecklistStatus());
  }

  List<_SystemCheckIssue> get _systemCheckIssues {
    final issues = <_SystemCheckIssue>[];

    if (!_hasInternet) {
      issues.add(
        const _SystemCheckIssue(
          topic: 'สัญญาณ Internet',
          indicator: 'สถานะการเชื่อมต่อ 4G/5G',
          impact: 'ตัดเงินจาก Wallet ไม่ได้, แจ้งเตือนไป Staff App ไม่ทำงาน',
        ),
      );
    }

    if (!_hasFreshGpsSignal()) {
      issues.add(
        const _SystemCheckIssue(
          topic: 'สัญญาณ GPS',
          indicator: 'พิกัดปัจจุบัน (Latitude/Longitude)',
          impact: 'ระบบไม่รู้ว่ารถอยู่ป้ายไหน คำนวณค่าโดยสารตามระยะทางไม่ได้',
        ),
      );
    }

    if (!_isTripReady) {
      issues.add(
        const _SystemCheckIssue(
          topic: 'สถานะเที่ยวรถ',
          indicator: 'เที่ยวรถในระบบ (Status 3)',
          impact:
              'พขร. จะกด "เริ่มเดินรถ" ไม่ได้ และนายท่าจะปิดงานบน Web ไม่ได้',
        ),
      );
    }

    if (!_isReaderReady) {
      issues.add(
        const _SystemCheckIssue(
          topic: 'ระบบ Reader',
          indicator: 'หัวอ่านบัตร EMV และ QR Code',
          impact: 'ผู้โดยสารแตะบัตรแล้วเครื่องไม่ตอบสนอง',
        ),
      );
    }

    if (!_isAudioReady) {
      issues.add(
        const _SystemCheckIssue(
          topic: 'ระบบเสียง (Audio)',
          indicator: 'ลำโพงแจ้งเตือนบนเครื่อง',
          impact: 'พขร. จะไม่ได้ยินเสียงเตือนเมื่อชำระเงินสำเร็จหรือล้มเหลว',
        ),
      );
    }

    return issues;
  }

  Future<bool> _postTransactionPayload({
    required Uri url,
    required Map<String, dynamic> payload,
    required String label,
  }) async {
    debugPrint('[DEBUG] Submitting $label to $url');
    debugPrint('[DEBUG] Payload: ${jsonEncode(payload)}');

    final response = await http.post(
      url,
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode(payload),
    );

    if (response.statusCode >= 200 && response.statusCode < 300) {
      debugPrint(
        '[DEBUG] $label submitted successfully (${response.statusCode})',
      );
      return true;
    }

    debugPrint(
      '[DEBUG] $label failed: ${response.statusCode} - ${response.body}',
    );
    return false;
  }

  Future<EmvTransactionRequest> _buildFlatRateTransactionRequest(
    TransactionRequest originalPayload, {
    required BusTrip activeBusTrip,
    int? routeId,
  }) async {
    final firstTxn = originalPayload.transactions.first;
    final effectiveRouteId = routeId ?? activeBusTrip.routeId;
    final tapInStop = await _dbHelper.getNearestBusStop(
      firstTxn.tapInLoc.lat,
      firstTxn.tapInLoc.lng,
      routeId: effectiveRouteId,
    );
    final tapOutStop = await _dbHelper.getNearestBusStop(
      firstTxn.tapOutLoc.lat,
      firstTxn.tapOutLoc.lng,
      routeId: effectiveRouteId,
    );

    final tapInDistance = tapInStop == null
        ? 0.0
        : _haversineDistance(
            firstTxn.tapInLoc.lat,
            firstTxn.tapInLoc.lng,
            tapInStop.latitude,
            tapInStop.longitude,
          );
    final tapOutDistance = tapOutStop == null
        ? 0.0
        : _haversineDistance(
            firstTxn.tapOutLoc.lat,
            firstTxn.tapOutLoc.lng,
            tapOutStop.latitude,
            tapOutStop.longitude,
          );
    final flatPrice = activeBusTrip.flatPrice;

    final tapInLoc = EmvTapLocation(
      latitude: firstTxn.tapInLoc.lat,
      longitude: firstTxn.tapInLoc.lng,
      busstopId: tapInStop?.busstopId ?? 0,
      busstopName: tapInStop?.busstopDesc ?? '',
      busstopLatitude: tapInStop?.latitude ?? 0.0,
      busstopLongitude: tapInStop?.longitude ?? 0.0,
      busstopDistance: tapInDistance,
      gpsbusstopName: tapInStop?.busstopDesc ?? '',
      gpsbusstopLatitude: firstTxn.tapInLoc.lat,
      gpsbusstopLongitude: firstTxn.tapInLoc.lng,
      gpsBoxId: '',
      gpsRecDatetime: firstTxn.tapInTime,
      gpsSpeed: 0.0,
    );
    final tapOutLoc = EmvTapLocation(
      latitude: firstTxn.tapOutLoc.lat,
      longitude: firstTxn.tapOutLoc.lng,
      busstopId: tapOutStop?.busstopId ?? 0,
      busstopName: tapOutStop?.busstopDesc ?? '',
      busstopLatitude: tapOutStop?.latitude ?? 0.0,
      busstopLongitude: tapOutStop?.longitude ?? 0.0,
      busstopDistance: tapOutDistance,
      gpsbusstopName: tapOutStop?.busstopDesc ?? '',
      gpsbusstopLatitude: firstTxn.tapOutLoc.lat,
      gpsbusstopLongitude: firstTxn.tapOutLoc.lng,
      gpsBoxId: '',
      gpsRecDatetime: firstTxn.tapOutTime,
      gpsSpeed: 0.0,
    );
    final fareInfo = EmvFareInfo(
      bustripId: activeBusTrip.id,
      routeId: activeBusTrip.routeId,
      buslineId: activeBusTrip.buslineId,
      businfoId: activeBusTrip.businfoId,
      busNo: activeBusTrip.busno,
      isMorning: false,
      isExpress: false,
      morningAmount: 0.0,
      expressAmount: 0.0,
      fareAmount: flatPrice,
      totalAmount: flatPrice,
      isFlatRate: activeBusTrip.isFlatRate,
      flatPrice: flatPrice,
    );

    return EmvTransactionRequest(
      deviceId: originalPayload.deviceId,
      plateNo: originalPayload.plateNo,
      isFlatRate: activeBusTrip.isFlatRate,
      flatPrice: flatPrice,
      transactions: [
        EmvTransactionItem(
          txnId: firstTxn.txnId,
          assetId: firstTxn.assetId,
          assetType: firstTxn.assetType,
          tapInTime: firstTxn.tapInTime,
          tapInLoc: tapInLoc,
          tapOutTime: firstTxn.tapOutTime,
          tapOutLoc: tapOutLoc,
          fareInfo: fareInfo,
        ),
      ],
    );
  }

  Future<void> _submitTransaction(
    TransactionRequest payload,
    String aid, {
    int? routeId,
    bool isNfc = false,
    String? logNo,
  }) async {
    try {
      final activeBusTrip = await _dbHelper.getActiveBusTrip();
      final isFlatRate = activeBusTrip?.isFlatRate ?? false;
      final effectiveRouteId = routeId ?? activeBusTrip?.routeId;
      bool submitted = true;

      if (!isNfc) {
        if (isFlatRate && activeBusTrip != null) {
          final flatRatePayload = await _buildFlatRateTransactionRequest(
            payload,
            activeBusTrip: activeBusTrip,
            routeId: effectiveRouteId,
          );
          submitted = await _postTransactionPayload(
            url: _flatRateTransactionsUrl,
            payload: flatRatePayload.toJson(),
            label: 'Flat-rate Transaction',
          );
        } else {
          submitted = await _postTransactionPayload(
            url: _transactionsUrl,
            payload: payload.toJson(),
            label: 'Transaction',
          );
        }
      } else {
        debugPrint(
          '[EMV] Skip /transactions. EMV will be submitted to /transactions/emv (isFlatRate=$isFlatRate).',
        );
      }

      if (submitted) {
        setState(() {
          _pendingTransactions.remove(aid);
        });
        _savePendingTransactions();

        // Broadcast removal to other devices via WiFi Sync
        if (_syncService.isRunning) {
          final pendingSync = PendingTransactionSync(
            aid: aid,
            tapInTime:
                DateTime.now().toUtc(), // Time doesn't matter for removal
            isRemove: true,
          );
          await _syncService.sendPendingSync(pendingSync);
          debugPrint('[DEBUG] 📤 Broadcasted Tap Out removal for $aid');
        }

        // --- Queue EMV Transaction — รอ GPS ที่เวลาเลย tapOutTime ก่อนส่ง ---
        if (isNfc) {
          final tapOutTime = DateTime.parse(
            payload.transactions.first.tapOutTime,
          );
          _pendingEmvRequests.add(
            _PendingEmvRequest(
              payload: payload,
              routeId: effectiveRouteId,
              tapOutTime: tapOutTime,
              logNo: logNo,
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
            routeId: effectiveRouteId,
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
              routeId: effectiveRouteId,
            );

            if (tapInStop != null) {
              debugPrint(
                '[DEBUG] 📍 Nearest Stop (Tap In): ${tapInStop.busstopDesc} (Seq: ${tapInStop.seq})',
              );

              // 3. Calculate Fare
              final fare = isFlatRate
                  ? activeBusTrip?.flatPrice
                  : await _dbHelper.getFare(
                      tapInStop.seq,
                      tapOutStop.seq,
                      routeId: effectiveRouteId,
                    );
              if (fare != null) {
                priceDisplay = '${fare.toStringAsFixed(2)} ฿';
                debugPrint(
                  '[DEBUG] 💰 ${isFlatRate ? "Flat-rate" : "Calculated"} Fare: $priceDisplay',
                );

                // --- ARKE EMV PAYMENT INTEGRATION (BYPASSED) ---
                try {
                  if (isNfc && _posService.isArke) {
                    debugPrint(
                        '[DEBUG] 💳 Skip traditional VAS Sale, using settlement adjustment flow');
                    // In the new flow, we don't call vasSale(fare) here.
                    // Instead, we wait for _submitEmvTransaction to call vasSettlementAdjustment.
                    // But we still need to wait for GPS to resolve.
                    _showResultDialog(
                      busStopName,
                      'กำลังดำเนินการ settlement ที่เครื่อง POS',
                      isSuccess: true,
                      isTapOut: true,
                      price: priceDisplay,
                      balance: '475.00 ฿',
                      topStatus: 'บันทึกจุดลงรถแล้ว',
                      instruction: 'ระบบจะปรับยอดผ่าน POS อัตโนมัติ',
                      soundSequence: _tapOutSuccessSounds(isNfc: isNfc),
                    );
                    return;
                  }

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
                    soundSequence: _tapOutSuccessSounds(isNfc: isNfc),
                  );
                } catch (e) {
                  debugPrint('[DEBUG] ❌ Payment Failed: $e');
                  _showResultDialog(
                    'ชำระเงินไม่สำเร็จ',
                    'เกิดข้อผิดพลาดในการตัดเงิน: ${e.toString()}',
                    isSuccess: false,
                    soundSequence: _failureSounds(isNfc: isNfc),
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
          soundSequence: _tapOutSuccessSounds(isNfc: isNfc),
        );
      } else {
        _showResultDialog(
          'ทำรายการไม่สำเร็จ',
          'ไม่สามารถส่งข้อมูลธุรกรรมไปยัง API ได้',
          isSuccess: false,
          soundSequence: _failureSounds(isNfc: isNfc),
        );
      }
    } catch (e) {
      _showResultDialog(
        'เกิดข้อผิดพลาด',
        '$e',
        isSuccess: false,
        soundSequence: _failureSounds(isNfc: isNfc),
      );
    }
  }

  /// Build and submit EMV Transaction
  Future<void> _submitEmvTransaction(
    TransactionRequest originalPayload, {
    int? routeId,
    String? logNo,
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
      double tapInGpsLat;
      double tapInGpsLng;
      if (_useDeviceGps) {
        final gps = await _getGpsForNfc();
        tapInGpsLat = gps.$1;
        tapInGpsLng = gps.$2;
        debugPrint(
            '[EMV] 📍 TapIn GPS: Device GPS lat=$tapInGpsLat, lng=$tapInGpsLng');
      } else {
        final hasResolvedTapIn =
            _resolvedTapInGps.containsKey(firstTxn.assetId);
        final tapInGps =
            _resolvedTapInGps[firstTxn.assetId] ?? _findClosestGps(tapInTime);
        tapInGpsLat = tapInGps?.lat ?? firstTxn.tapInLoc.lat;
        tapInGpsLng = tapInGps?.lng ?? firstTxn.tapInLoc.lng;
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
          final diffMs = (tapInGps.rec!.millisecondsSinceEpoch -
                  tapInTime.millisecondsSinceEpoch)
              .abs();
          debugPrint(
            '[EMV]   └─ time diff from tapInTime: ${diffMs}ms (${(diffMs / 1000).toStringAsFixed(1)}s)',
          );
        }
      }

      // --- TapOut GPS ---
      double tapOutGpsLat;
      double tapOutGpsLng;
      if (_useDeviceGps) {
        final gps = await _getGpsForNfc();
        tapOutGpsLat = gps.$1;
        tapOutGpsLng = gps.$2;
        debugPrint(
            '[EMV] 📍 TapOut GPS: Device GPS lat=$tapOutGpsLat, lng=$tapOutGpsLng');
      } else {
        final tapOutGps = _findClosestGps(tapOutTime);
        tapOutGpsLat = tapOutGps?.lat ?? firstTxn.tapOutLoc.lat;
        tapOutGpsLng = tapOutGps?.lng ?? firstTxn.tapOutLoc.lng;
        debugPrint('[EMV] 📍 TapOut GPS:');
        debugPrint('[EMV]   ├─ source: HISTORY LOOKUP');
        debugPrint('[EMV]   ├─ gpsTime: ${tapOutGps?.rec}');
        debugPrint('[EMV]   ├─ lat: $tapOutGpsLat, lng: $tapOutGpsLng');
        debugPrint('[EMV]   ├─ box: ${tapOutGps?.box}, spd: ${tapOutGps?.spd}');
        if (tapOutGps == null) {
          debugPrint('[EMV]   └─ ⚠️ FALLBACK to original transaction lat/lng');
        } else {
          final diffMs = (tapOutGps.rec!.millisecondsSinceEpoch -
                  tapOutTime.millisecondsSinceEpoch)
              .abs();
          debugPrint(
            '[EMV]   └─ time diff from tapOutTime: ${diffMs}ms (${(diffMs / 1000).toStringAsFixed(1)}s)',
          );
        }
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
      final isFlatRate = activeBusTrip?.isFlatRate ?? false;
      final flatPrice = activeBusTrip?.flatPrice ?? 0.0;
      if (isFlatRate) {
        fareAmount = flatPrice;
      } else if (tapInStop != null && tapOutStop != null) {
        fareAmount = await _dbHelper.getFare(
              tapInStop.seq,
              tapOutStop.seq,
              routeId: routeId,
            ) ??
            0.0;
      }
      debugPrint(
        '[EMV] 💰 Fare: $fareAmount (isFlatRate=$isFlatRate, flatPrice=$flatPrice, tapInSeq=${tapInStop?.seq}, tapOutSeq=${tapOutStop?.seq})',
      );

      // --- Device GPS (เครื่อง POS หรือ โทรศัพท์) ---
      double? deviceLat;
      double? deviceLng;
      try {
        // 1. ลองดึงจาก SDK ของเครื่อง POS (CPay)
        final locStr = await _posService.getLocation().timeout(
              const Duration(seconds: 3),
              onTimeout: () => null,
            );

        if (locStr != null && locStr.contains(',')) {
          final parts = locStr.split(',');
          deviceLat = double.tryParse(parts[0]);
          deviceLng = double.tryParse(parts[1]);
        }

        // 2. ถ้าดึงไม่ได้ (เช่น เป็นมือถือทั่วไป หรือ Arke) ให้ใช้ Geolocator
        if (deviceLat == null || deviceLng == null) {
          debugPrint(
              '[EMV] ⚠️ POS SDK GPS returned null, falling back to native phone GPS...');
          final pos = await _locationService.getCurrentPosition();
          if (pos != null) {
            deviceLat = pos.latitude;
            deviceLng = pos.longitude;
          }
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
        gpsbusstopLatitude: tapInGpsLat,
        gpsbusstopLongitude: tapInGpsLng,
        gpsBoxId: _useDeviceGps
            ? ''
            : (_resolvedTapInGps[firstTxn.assetId]?.box ??
                _findClosestGps(tapInTime)?.box ??
                ''),
        gpsRecDatetime: _useDeviceGps
            ? tapInTime.toIso8601String()
            : (_resolvedTapInGps[firstTxn.assetId]?.rec?.toIso8601String() ??
                _findClosestGps(tapInTime)?.rec?.toIso8601String() ??
                tapInTime.toIso8601String()),
        gpsSpeed: _useDeviceGps
            ? 0.0
            : (_resolvedTapInGps[firstTxn.assetId]?.spd ??
                _findClosestGps(tapInTime)?.spd ??
                0.0),
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
        gpsbusstopLatitude: tapOutGpsLat,
        gpsbusstopLongitude: tapOutGpsLng,
        gpsBoxId: _useDeviceGps ? '' : (_findClosestGps(tapOutTime)?.box ?? ''),
        gpsRecDatetime: _useDeviceGps
            ? tapOutTime.toIso8601String()
            : (_findClosestGps(tapOutTime)?.rec?.toIso8601String() ??
                tapOutTime.toIso8601String()),
        gpsSpeed:
            _useDeviceGps ? 0.0 : (_findClosestGps(tapOutTime)?.spd ?? 0.0),
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
        isFlatRate: isFlatRate,
        flatPrice: flatPrice,
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
        isFlatRate: isFlatRate,
        flatPrice: flatPrice,
        transactions: [emvTxnItem],
      );

      debugPrint('[EMV] 📦 Payload built. Sending to API...');
      debugPrint('[EMV]   ├─ deviceId: ${emvRequest.deviceId}');
      debugPrint('[EMV]   └─ plateNo: ${emvRequest.plateNo}');

      // Send to EMV API
      final success = await _emvTransactionService.submitEmvTransaction(
        emvRequest,
      );

      // --- ARKE SETTLEMENT ADJUSTMENT ---
      if (success && _posService.isArke && fareAmount > 0) {
        if (logNo != null && logNo.isNotEmpty) {
          debugPrint(
              '[EMV] 💰 Triggering VAS Settlement Adjustment: Amount=$fareAmount, LogNo=$logNo');
          await _posService.vasSettlementAdjustment(fareAmount, logNo);
          await _printArkeReceipt(
            txnId: firstTxn.txnId,
            tapInTime: tapInTime,
            tapOutTime: tapOutTime,
            tapInStopName: tapInStop?.busstopDesc ?? '-',
            tapOutStopName: tapOutStop?.busstopDesc ?? '-',
            fareAmount: fareAmount,
            logNo: logNo,
          );
        } else {
          debugPrint(
              '[EMV] ⚠️ Cannot adjust settlement: logNo is null for txnId ${firstTxn.txnId}');
        }
      }

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
    List<AppSound> soundSequence = const [],
  }) {
    if (!mounted) return;

    if (_posService.isTapgo && _showQrScanner) {
      unawaited(_posService.stopQrScanning());
    }
    _stopBackgroundScanning();
    unawaited(AppAudioService.instance.playSequence(soundSequence));

    void handleDismiss(BuildContext ctx) {
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
      }
      if (Navigator.of(ctx).canPop()) {
        Navigator.of(ctx).pop();
      }
      if (mounted) {
        setState(() {
          _isProcessing = false;
        });
        Future<void>.delayed(const Duration(milliseconds: 500), () async {
          if (!mounted || _isBackgroundScanningActive) return;
          await _startBackgroundScanning();
          await _syncDedicatedQrScannerMode();
        });
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
            errorCause: instruction,
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
        soundSequence: _failureSounds(isNfc: true, includeSourceCue: false),
      );
    }
  }

  QrData? _parseQrDataFromScan(String rawValue) {
    try {
      Map<String, dynamic>? payloadMap;

      final scannedUri = Uri.tryParse(rawValue);
      final encodedPayload = scannedUri?.queryParameters['payload'];
      if (encodedPayload != null && encodedPayload.isNotEmpty) {
        payloadMap = jsonDecode(encodedPayload) as Map<String, dynamic>;
      } else if (scannedUri != null &&
          scannedUri.hasQuery &&
          scannedUri.queryParameters.containsKey('aid')) {
        payloadMap = {
          'aid': scannedUri.queryParameters['aid'],
          'bal':
              double.tryParse(scannedUri.queryParameters['bal'] ?? '') ?? 0.0,
          'exp': scannedUri.queryParameters['exp'],
        };
      } else {
        payloadMap = jsonDecode(rawValue) as Map<String, dynamic>;
      }

      final nestedPayload = payloadMap['payload'];
      if (nestedPayload is Map<String, dynamic>) {
        payloadMap = nestedPayload;
      } else if (nestedPayload is String && nestedPayload.isNotEmpty) {
        payloadMap = jsonDecode(nestedPayload) as Map<String, dynamic>;
      }

      if (payloadMap.containsKey('aid') && payloadMap.containsKey('bal')) {
        return QrData.fromJson(payloadMap);
      }
    } catch (e) {
      debugPrint('[QR] Failed to decode scanned payload: $e');
    }
    return null;
  }

  Future<void> _handleScannedQrValue(
    String rawValue, {
    required String source,
  }) async {
    if (_isQrScanDialogOpen || _isProcessing || _isLoading) return;
    if (rawValue.isEmpty) return;
    debugPrint('[QR][$source] Raw scan value: $rawValue');

    final now = DateTime.now();
    if (_lastQrScanValue == rawValue &&
        _lastQrScanTime != null &&
        now.difference(_lastQrScanTime!) < const Duration(seconds: 2)) {
      return;
    }

    _lastQrScanValue = rawValue;
    _lastQrScanTime = now;
    _isQrScanDialogOpen = true;
    _isProcessing = true;

    if (!mounted) {
      _isQrScanDialogOpen = false;
      _isProcessing = false;
      return;
    }

    try {
      final qrData = _parseQrDataFromScan(rawValue);
      if (qrData == null) {
        debugPrint('[QR][$source] Ignoring non-Tap&Go QR payload.');
        _isProcessing = false;
        if (mounted) {
          setState(() {});
        }
        return;
      }

      final pendingKey = _findPendingTransactionKey(qrData.aid);
      final effectiveQrData = pendingKey != null && pendingKey != qrData.aid
          ? QrData(aid: pendingKey, bal: qrData.bal, exp: qrData.exp)
          : qrData;

      if (pendingKey != null) {
        debugPrint(
            '[QR][$source] Routing scan to TAP-OUT flow | aid=${effectiveQrData.aid}');
        await _handleTapOut(effectiveQrData);
      } else {
        debugPrint(
            '[QR][$source] Routing scan to TAP-IN flow | aid=${effectiveQrData.aid}');
        await _handleTapIn(effectiveQrData);
      }
    } finally {
      _isQrScanDialogOpen = false;
    }
  }

  Future<void> _handleQrCodeDetected(BarcodeCapture capture) async {
    if (capture.barcodes.isEmpty) return;

    final rawValue = capture.barcodes.first.rawValue;
    if (rawValue == null || rawValue.isEmpty) return;

    await _handleScannedQrValue(rawValue, source: 'camera');
  }

  Widget _buildQrDisplayPanel() {
    if (_showQrScanner) {
      if (_posService.isTapgo) {
        return Container(
          color: const Color(0xFF101820),
          child: Stack(
            fit: StackFit.expand,
            children: [
              Container(
                decoration: BoxDecoration(
                  border: Border.all(color: Colors.greenAccent, width: 2),
                  borderRadius: BorderRadius.circular(16),
                ),
              ),
              Center(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 20),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: const [
                      Icon(
                        Icons.qr_code_scanner_rounded,
                        color: Colors.greenAccent,
                        size: 72,
                      ),
                      SizedBox(height: 16),
                      Text(
                        'TapGo QR Scanner Ready',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 18,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      SizedBox(height: 8),
                      Text(
                        'กรุณาใช้หัวสแกน QR ของเครื่องเพื่ออ่านโค้ด',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          color: Colors.white70,
                          fontSize: 13,
                          height: 1.4,
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

      return Stack(
        fit: StackFit.expand,
        children: [
          MobileScanner(
            controller: _qrScannerController,
            onDetect: _handleQrCodeDetected,
          ),
          Container(
            decoration: BoxDecoration(
              border: Border.all(color: Colors.greenAccent, width: 2),
              borderRadius: BorderRadius.circular(16),
            ),
          ),
          Positioned(
            left: 0,
            right: 0,
            bottom: 8,
            child: Container(
              margin: const EdgeInsets.symmetric(horizontal: 12),
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              decoration: BoxDecoration(
                color: Colors.black.withOpacity(0.6),
                borderRadius: BorderRadius.circular(12),
              ),
              child: const Text(
                'สแกน QR Code',
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ),
        ],
      );
    }

    return Container(
      color: Colors.white,
      child: _qrCodePayload.isNotEmpty
          ? QrImageView(
              data: _qrCodePayload,
              version: QrVersions.auto,
              padding: const EdgeInsets.all(12),
            )
          : const Center(
              child: CircularProgressIndicator(),
            ),
    );
  }

  Widget _buildMainSystemStatusButton() {
    final isReady = _isSystemReady;
    final statusColor = isReady ? Colors.greenAccent : Colors.amberAccent;
    final backgroundColor = isReady
        ? Colors.greenAccent.withOpacity(0.16)
        : Colors.orangeAccent.withOpacity(0.18);
    final borderColor = isReady
        ? Colors.greenAccent.withOpacity(0.75)
        : Colors.amberAccent.withOpacity(0.85);

    return GestureDetector(
      onTap: _openSystemChecklist,
      child: Container(
        width: 38,
        height: 38,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: backgroundColor,
          shape: BoxShape.circle,
          border: Border.all(color: borderColor),
        ),
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            Icon(
              isReady ? Icons.verified_rounded : Icons.warning_amber_rounded,
              color: statusColor,
              size: 22,
            ),
            if (!isReady)
              Positioned(
                right: -2,
                top: -2,
                child: Container(
                  width: 8,
                  height: 8,
                  decoration: BoxDecoration(
                    color: Colors.redAccent,
                    shape: BoxShape.circle,
                    border: Border.all(color: Colors.white, width: 1),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildMainIssueAlert() {
    final issues = _systemCheckIssues;
    if (issues.isEmpty) return const SizedBox.shrink();

    final issueNames = issues.map((issue) => issue.topic).join(', ');

    return GestureDetector(
      onTap: _openSystemChecklist,
      child: Container(
        width: double.infinity,
        margin: const EdgeInsets.symmetric(horizontal: 14),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: const Color(0xFF2B1114).withOpacity(0.92),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: Colors.redAccent.withOpacity(0.82)),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(0.22),
              blurRadius: 12,
              offset: const Offset(0, 6),
            ),
          ],
        ),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 220),
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Icon(
                      Icons.warning_amber_rounded,
                      color: Colors.amberAccent,
                      size: 20,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'พบข้อขัดข้อง: $issueNames',
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 15,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                ...issues.map(
                  (issue) => Padding(
                    padding: const EdgeInsets.only(top: 7),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '${issue.topic}: ${issue.indicator}',
                          style: const TextStyle(
                            color: Color(0xFFFFD6D6),
                            fontSize: 13,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          issue.impact,
                          style: const TextStyle(
                            color: Color(0xFFFFA8A8),
                            fontSize: 12,
                            height: 1.25,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildFloatingIssueAlert() {
    if (_systemCheckIssues.isEmpty) return const SizedBox.shrink();

    return SafeArea(
      child: Align(
        alignment: Alignment.topCenter,
        child: Padding(
          padding: const EdgeInsets.only(top: 104),
          child: _buildMainIssueAlert(),
        ),
      ),
    );
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
                                  child: _buildQrDisplayPanel(),
                                ),
                              ),
                              const SizedBox(height: 24),
                              if (_showQrScanner)
                                const Text(
                                  'กรุณาสแกน QR Code',
                                  style: TextStyle(
                                    color: Colors.white,
                                    fontSize: 32,
                                    fontWeight: FontWeight.bold,
                                  ),
                                )
                              else
                                Text(
                                  'กรุณาแตะบัตร',
                                  style: TextStyle(
                                    color: Colors.white,
                                    fontSize: 32,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                              const SizedBox(height: 16),
                              if (_showQrScanner)
                                const Text(
                                  'สแกน QR ในกรอบด้านบนเพื่ออ่าน payload',
                                  style: TextStyle(
                                    color: Colors.white70,
                                    fontSize: 18,
                                  ),
                                )
                              else
                                Text(
                                  'แตะบัตรที่จุดอ่านเพื่อชำระเงิน',
                                  style: TextStyle(
                                    color: Colors.white70,
                                    fontSize: 18,
                                  ),
                                ),

                              // === Debug Simulate Buttons ===
                              if (_showSimulateButtons) ...[
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
                                          borderRadius:
                                              BorderRadius.circular(20),
                                        ),
                                      ),
                                    ),
                                    const SizedBox(width: 12),
                                    ElevatedButton.icon(
                                      onPressed: _pendingTransactions
                                              .containsKey(
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
                                          borderRadius:
                                              BorderRadius.circular(20),
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              ],

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
                                    const SizedBox(width: 10),
                                    _buildMainSystemStatusButton(),
                                    const SizedBox(width: 10),
                                    GestureDetector(
                                      onTap: () async {
                                        await Navigator.of(context).push(
                                          MaterialPageRoute(
                                            builder: (_) => SettingsScreen(
                                              plateNumber: _plateNumber,
                                              activeRouteId: _activeRouteId,
                                              onPlateChanged: (newPlate) async {
                                                await _performPlateChange(
                                                    newPlate);
                                              },
                                              gpsHistory: _gpsHistory,
                                              gpsStream: _mqttService.gpsStream,
                                              isOfflineMode: _isOfflineMode,
                                              onOfflineModeChanged:
                                                  _setOfflineMode,
                                              lastScanLog: _lastScanLog,
                                              latestLogNo: _latestLogNo,
                                              onClearCache: _handleClearCache,
                                              useDeviceGps: _useDeviceGps,
                                              onUseDeviceGpsChanged:
                                                  _setUseDeviceGps,
                                              showQrScanner: _showQrScanner,
                                              onShowQrScannerChanged:
                                                  _setShowQrScanner,
                                              onResetQrScanner: _resetQrScanner,
                                            ),
                                          ),
                                        );
                                        // Refresh plate from SharedPreferences when returning
                                        final prefs = await SharedPreferences
                                            .getInstance();
                                        final savedPlate =
                                            prefs.getString('plate_number') ??
                                                '';
                                        if (mounted &&
                                            savedPlate != _plateNumber) {
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

          _buildFloatingIssueAlert(),

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
          if (_isAppDisabled && !_isPlateChanging && !_isOfflineMode)
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
                              isOfflineMode: _isOfflineMode,
                              onOfflineModeChanged: _setOfflineMode,
                              useDeviceGps: _useDeviceGps,
                              onUseDeviceGpsChanged: _setUseDeviceGps,
                              showQrScanner: _showQrScanner,
                              onShowQrScannerChanged: _setShowQrScanner,
                              onResetQrScanner: _resetQrScanner,
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

  void _promptOfflineMode() {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        title: const Text('ไม่มีสัญญาณอินเทอร์เน็ต'),
        content: const Text(
          'ตรวจไม่พบการเชื่อมต่ออินเทอร์เน็ตในขณะนี้\nคุณต้องการเปลี่ยนไปใช้งาน "โหมดออฟไลน์" หรือไม่?\n\n(ใช้งานแตะบัตรขึ้น-ลงรถได้ปกติ แต่จะไม่มีการซิงค์ข้อมูลเส้นทางกับเซิร์ฟเวอร์)',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('ยกเลิก', style: TextStyle(color: Colors.grey)),
          ),
          ElevatedButton(
            onPressed: () {
              Navigator.of(ctx).pop();
              _setOfflineMode(true);
            },
            style: ElevatedButton.styleFrom(backgroundColor: Colors.deepPurple),
            child: const Text('ตกลง', style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );
  }

  /// Full plate change flow with loading overlay
  Future<void> _setOfflineMode(bool value) async {
    setState(() => _isOfflineMode = value);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('offline_mode', value);
    unawaited(_refreshSystemChecklistStatus());
    debugPrint('[OFFLINE] Mode set to: $value');
  }

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
      _routeDetailsCount = 0;
      _priceRangesCount = 0;
      _lastChecklistGpsReady = false;
      _lastChecklistAudioReady = false;
      _hasActiveBusTrip = false;
      _checklistRouteId = null;
      _checklistBusNo = '';
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

    // Step 3: Connect MQTT (skip in offline mode)
    if (!_isOfflineMode) {
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
    } else {
      debugPrint('[PLATE] ⏩ Skipping MQTT connect (offline mode)');
    }

    // Step 4: Sync data (skip in offline mode)
    if (!_isOfflineMode) {
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
            unawaited(_refreshSystemChecklistStatus());
          }
        }
      } catch (e) {
        _plateChangeErrors.add('❌ ดึงข้อมูลเส้นทางล้มเหลว: $e');
        debugPrint('[PLATE] ❌ Sync error: $e');
      }
    } else {
      debugPrint('[PLATE] ⏩ Skipping data sync (offline mode)');
    }

    // Step 5: Verify data completeness (skip in offline mode)
    if (!_isOfflineMode) {
      setState(() => _plateChangeStatus = 'กำลังตรวจสอบข้อมูล...');
      try {
        final db = await _dbHelper.database;
        final routeCount = Sqflite.firstIntValue(
              await db.rawQuery('SELECT COUNT(*) FROM route_details'),
            ) ??
            0;
        final priceCount = Sqflite.firstIntValue(
              await db.rawQuery('SELECT COUNT(*) FROM price_ranges'),
            ) ??
            0;
        final tripCount = Sqflite.firstIntValue(
              await db.rawQuery('SELECT COUNT(*) FROM bus_trips'),
            ) ??
            0;

        debugPrint(
          '[PLATE] 📊 Data check: routes=$routeCount prices=$priceCount trips=$tripCount',
        );

        if (mounted) {
          setState(() {
            _routeDetailsCount = routeCount;
            _priceRangesCount = priceCount;
            _hasActiveBusTrip = tripCount > 0;
          });
        }

        if (routeCount == 0)
          _plateChangeErrors.add('⚠️ ไม่พบข้อมูลเส้นทาง (route_details)');
        if (priceCount == 0)
          _plateChangeErrors.add('⚠️ ไม่พบข้อมูลราคา (price_ranges)');
        if (tripCount == 0)
          _plateChangeErrors.add('⚠️ ไม่พบข้อมูลเที่ยวรถ (bus_trips)');
      } catch (e) {
        _plateChangeErrors.add('❌ ตรวจสอบข้อมูลล้มเหลว: $e');
      }
    } else {
      debugPrint('[PLATE] ⏩ Skipping data verification (offline mode)');
    }

    // Done — show result
    if (_plateChangeErrors.isNotEmpty) {
      setState(() {
        _isPlateChanging = false;
        _isAppDisabled = true;
      });

      unawaited(
        AppAudioService.instance.playSequence(
          _failureSounds(isNfc: false, includeSourceCue: false),
        ),
      );

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
                        isOfflineMode: _isOfflineMode,
                        onOfflineModeChanged: _setOfflineMode,
                        lastScanLog: _lastScanLog,
                        latestLogNo: _latestLogNo,
                        onClearCache: _handleClearCache,
                        useDeviceGps: _useDeviceGps,
                        onUseDeviceGpsChanged: _setUseDeviceGps,
                        showQrScanner: _showQrScanner,
                        onShowQrScannerChanged: _setShowQrScanner,
                        onResetQrScanner: _resetQrScanner,
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

      unawaited(AppAudioService.instance.playSequence(_welcomeSoundSequence));
    }
  }
}

/// Pending EMV request — รอ GPS ที่เวลาเลย tapOutTime ก่อนส่ง
class _PendingEmvRequest {
  final TransactionRequest payload;
  final int? routeId;
  final DateTime tapOutTime;
  final String? logNo;

  _PendingEmvRequest({
    required this.payload,
    this.routeId,
    required this.tapOutTime,
    this.logNo,
  });
}

/// Pending TapIn GPS — รอ GPS ที่เวลาเลย tapInTime ก่อน resolve
class _PendingTapInGps {
  final String aid;
  final DateTime tapInTime;

  _PendingTapInGps({required this.aid, required this.tapInTime});
}
