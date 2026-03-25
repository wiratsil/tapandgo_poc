import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:cpay_sdk_plugin/cpay_sdk_plugin.dart';
import 'package:arke_sdk_flutter/arke_sdk_flutter.dart';

enum PosType { arke, cpay, unknown }

/// Unified POS Service that abstracts Arke (USDK) and CPay SDK.
///
/// On CPay devices:
///   - NFC is event-driven: startNfcPolling → onNfcCardDetected stream fires
///     → then readCardId() is called to get card data.
///
/// On Arke devices:
///   - NFC is blocking: startNfcScan() blocks until a card is tapped,
///     so we run it in a polling loop that emits events to the same stream.

class CardReadResult {
  final String cardId;
  final String rawData;
  CardReadResult(this.cardId, this.rawData);
}

class PosService {
  static final PosService _instance = PosService._internal();
  factory PosService() => _instance;
  PosService._internal();

  final _arke = ArkeSdkFlutter();
  final _cpay = CpaySdkPlugin();

  PosType _type = PosType.unknown;
  PosType get type => _type;
  bool get isArke => _type == PosType.arke;

  // NFC card detection stream (unified for both devices)
  StreamController<bool> _nfcController = StreamController<bool>.broadcast();
  Stream<bool> get onNfcCardDetected => _nfcController.stream;
  StreamSubscription? _cpayNfcSub;

  // Arke NFC polling
  bool _arkeNfcPollingActive = false;

  // Store last read card ID from Arke (since Arke reads during poll)
  String? _lastArkeCardId;

  /// Detect device type (call once at startup)
  Future<void> init() async {
    // Ensure stream controller is fresh
    if (_nfcController.isClosed) {
      _nfcController = StreamController<bool>.broadcast();
    }

    try {
      // Use getTerminalInfo() instead of getPlatformVersion() for detection.
      // getPlatformVersion() returns Android version on ALL devices (including CPay),
      // but getTerminalInfo() requires actual Arke USDK binding and will throw
      // SDK_NOT_CONNECTED on non-Arke devices.
      final info = await _arke.getTerminalInfo().timeout(
        const Duration(seconds: 3),
        onTimeout: () => null,
      );
      if (info != null && info.isNotEmpty) {
        _type = PosType.arke;
        debugPrint('[PosService] 📟 Detected: ARKE (USDK) - ${info['model'] ?? 'unknown'}');
        return;
      }
    } catch (e) {
      debugPrint('[PosService] Not an Arke device: $e');
    }

    // Fallback to CPay
    _type = PosType.cpay;
    debugPrint('[PosService] 📟 Detected: CPAY');

    // Delegate CPay NFC events to our unified stream
    _cpayNfcSub?.cancel();
    _cpayNfcSub = _cpay.onNfcCardDetected.listen((present) {
      if (!_nfcController.isClosed) {
        _nfcController.add(present);
      }
    });
  }

  // ==================== VAS Payment (Arke Only) ====================

  /// Initialize VAS service (Bind and Sign In)
  Future<void> initVas() async {
    if (_type == PosType.arke) {
      try {
        debugPrint('[PosService] Binding VAS Service...');
        await _arke.vas.bindService();
        debugPrint('[PosService] VAS Service bound. Signing in...');
        await _arke.vas.signIn();
        debugPrint('[PosService] VAS Sign In complete.');
      } catch (e) {
        debugPrint('[PosService] VAS init error: $e');
      }
    }
  }

  /// Initiate a VAS sale transaction
  Future<void> vasSale(double amount) async {
    if (_type == PosType.arke) {
      try {
        debugPrint('[PosService] Initiating VAS Sale for $amount...');
        final request = VasRequestBody(amount: amount);
        await _arke.vas.sale(request);
      } catch (e) {
        debugPrint('[PosService] VAS sale error: $e');
      }
    } else {
      debugPrint('[PosService] VAS is only supported on Arke devices.');
    }
  }

  /// Stream of VAS events (onStart, onNext, onComplete, onError)
  Stream<VasEvent>? get onVasEvent => _type == PosType.arke ? _arke.vas.vasEvents : null;

  // ==================== Beep ====================

  Future<void> beep() async {
    try {
      if (_type == PosType.arke) {
        await _arke.beep(milliseconds: 500);
      } else {
        await _cpay.beep();
      }
    } catch (e) {
      debugPrint('[PosService] Beep error: $e');
    }
  }

  // ==================== NFC ====================

  /// Start NFC polling.
  /// - CPay: uses SDK polling which fires onNfcCardDetected events.
  /// - Arke: runs a loop that calls startNfcScan() (blocking) and emits events.
  Future<void> startNfcPolling() async {
    if (_type == PosType.arke) {
      _startArkeNfcLoop();
    } else {
      await _cpay.startNfcPolling(intervalMs: 500);
    }
  }

  /// Stop NFC polling.
  Future<void> stopNfcPolling() async {
    if (_type == PosType.arke) {
      _arkeNfcPollingActive = false;
    } else {
      await _cpay.stopNfcPolling();
    }
  }

  /// Arke NFC loop: continuously call startNfcScan() which blocks until
  /// a card is tapped, then emit event and repeat.
  void _startArkeNfcLoop() {
    if (_arkeNfcPollingActive) return;
    _arkeNfcPollingActive = true;

    debugPrint('[PosService] 🔄 Starting Arke NFC loop...');

    Future.doWhile(() async {
      if (!_arkeNfcPollingActive) return false;

      try {
        // startNfcScan() blocks until card is tapped (with internal timeout)
        final uid = await _arke.startNfcScan().timeout(
          const Duration(seconds: 10),
          onTimeout: () => null,
        );

        if (uid != null && uid.isNotEmpty && _arkeNfcPollingActive) {
          _lastArkeCardId = uid;
          debugPrint('[PosService] 📱 Arke NFC card detected: $uid');

          if (!_nfcController.isClosed) {
            _nfcController.add(true); // Notify listeners
          }

          // Short cooldown to prevent duplicate reads
          await Future.delayed(const Duration(seconds: 2));
        }
      } catch (e) {
        debugPrint('[PosService] Arke NFC scan error: $e');
        // Small delay before retry on error
        await Future.delayed(const Duration(seconds: 1));
      }

      return _arkeNfcPollingActive; // Continue loop if still active
    });
  }

  /// Read card ID and raw data.
  /// - CPay: calls readCardEmv() and parses AID/CardNo. Returns full string as rawData.
  /// - Arke: returns the cached card ID from the polling loop.
  Future<CardReadResult?> readCardId() async {
    if (_type == PosType.arke) {
      // Card ID was already read during the polling loop
      final id = _lastArkeCardId;
      _lastArkeCardId = null; // Consume it
      if (id == null) return null;
      return CardReadResult(id, id);
    } else {
      try {
        final emvData = await _cpay.readCardEmv();
        if (emvData == null) return null;

        // Parse AID (priority) or Card No (fallback)
        String? aid;
        String? cardNo;
        for (final line in emvData.split('\n')) {
          final trimmed = line.trim();
          if (trimmed.startsWith('AID:')) {
            aid = trimmed.substring(4).trim();
          } else if (trimmed.startsWith('Card No:')) {
            cardNo = trimmed.substring(8).trim();
          }
        }
        final finalId = aid ?? cardNo ?? emvData;
        return CardReadResult(finalId, emvData);
      } catch (e) {
        debugPrint('[PosService] Cpay Read Error: $e');
        return null;
      }
    }
  }

  // ==================== Location ====================

  /// Get device GPS location.
  /// - CPay: returns lat,lng string from SDK.
  /// - Arke: returns null (no built-in GPS, app uses MQTT GPS instead).
  Future<String?> getLocation() async {
    if (_type == PosType.arke) {
      return null; // Arke doesn't have device GPS, fallback to MQTT
    } else {
      try {
        return await _cpay.getLocation();
      } catch (e) {
        debugPrint('[PosService] Cpay getLocation error: $e');
        return null;
      }
    }
  }

  // ==================== Printing (Arke only) ====================

  Future<void> printReceipt(String text) async {
    if (_type == PosType.arke) {
      await _arke.printText(text, align: 1);
    } else {
      debugPrint('[PosService] Printing not supported on Cpay');
    }
  }

  // ==================== Cleanup ====================

  void dispose() {
    _arkeNfcPollingActive = false;
    _cpayNfcSub?.cancel();
    if (!_nfcController.isClosed) {
      _nfcController.close();
    }
  }
}
