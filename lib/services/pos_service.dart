import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter/services.dart';
import 'package:flutter/foundation.dart';
import 'package:cpay_sdk_plugin/cpay_sdk_plugin.dart';
import 'package:arke_sdk_flutter/arke_sdk_flutter.dart';
import 'package:tapgo_terminal_plugin/tapgo_terminal_plugin.dart';

enum PosType { arke, tapgo, cpay, unknown }

/// Unified POS Service that abstracts Arke (USDK) and CPay SDK.
///
/// On CPay devices:
///   - NFC is event-driven: startNfcPolling → onNfcCardDetected stream fires
///     → then readCardId() is called to get card data.
///
/// On Arke devices:
///   - NFC is blocking: startNfcScan() blocks until a card is tapped,
///     so we run it in a polling loop that emits events to the same stream.
///
/// On TapGo devices:
///   - NFC is event-based: startNfc() starts the native loop and nfcResult
///     events are bridged back into the same unified stream.

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
  final _tapgo = TapgoTerminalPlugin.instance;

  PosType _type = PosType.unknown;
  PosType get type => _type;
  bool get isArke => _type == PosType.arke;
  bool get isTapgo => _type == PosType.tapgo;
  bool get supportsVas => _type == PosType.arke;

  // NFC card detection stream (unified for both devices)
  StreamController<bool> _nfcController = StreamController<bool>.broadcast();
  Stream<bool> get onNfcCardDetected => _nfcController.stream;
  StreamController<String> _qrController = StreamController<String>.broadcast();
  Stream<String> get onQrCodeDetected => _qrController.stream;
  StreamSubscription? _cpayNfcSub;
  StreamSubscription<TerminalEvent>? _tapgoEventSub;

  // Arke NFC polling
  bool _arkeNfcPollingActive = false;
  int _arkeNfcPollingSession = 0;

  // Store last read card ID from Arke (since Arke reads during poll)
  String? _lastArkeCardId;
  String? _lastTapgoCardId;
  String? _lastTapgoRawData;

  /// Detect device type (call once at startup)
  Future<void> init() async {
    // Ensure stream controller is fresh
    if (_nfcController.isClosed) {
      _nfcController = StreamController<bool>.broadcast();
    }
    if (_qrController.isClosed) {
      _qrController = StreamController<String>.broadcast();
    }
    _cpayNfcSub?.cancel();
    _tapgoEventSub?.cancel();

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
        debugPrint(
            '[PosService] 📟 Detected: ARKE (USDK) - ${info['model'] ?? 'unknown'}');
        return;
      }
    } catch (e) {
      debugPrint('[PosService] Not an Arke device: $e');
    }

    try {
      final initResult = await _tapgo.initialize().timeout(
            const Duration(seconds: 3),
          );
      final capabilities = await _tapgo.getCapabilities().timeout(
            const Duration(seconds: 3),
          );
      final platformInfo = await _tapgo.getPlatformInfo().timeout(
            const Duration(seconds: 3),
          );

      if (initResult.success && capabilities.vendorReaderServiceInstalled) {
        _type = PosType.tapgo;
        debugPrint(
          '[PosService] 📟 Detected: TAPGO - ${platformInfo.model} (${platformInfo.manufacturer})',
        );
        _bindTapgoEvents();
        return;
      }

      debugPrint(
        '[PosService] TapGo not selected: readerServiceInstalled=${capabilities.vendorReaderServiceInstalled}',
      );
    } catch (e) {
      debugPrint('[PosService] Not a TapGo device: $e');
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

  void _bindTapgoEvents() {
    _tapgoEventSub?.cancel();
    _tapgoEventSub = _tapgo.events.listen((event) {
      debugPrint(
        '[PosService][TapGo] ${event.type}: ${event.message ?? ''} payload=${event.payload}',
      );

      if (event.type == 'nfcResult') {
        final pan = event.payload['pan']?.toString();
        if (pan == null || pan.isEmpty) {
          return;
        }

        _lastTapgoCardId = pan;
        _lastTapgoRawData = jsonEncode(event.payload);
        if (!_nfcController.isClosed) {
          _nfcController.add(true);
        }
      } else if (event.type == 'qrScanned') {
        final code = event.payload['code']?.toString();
        if (code == null || code.isEmpty) {
          return;
        }

        if (!_qrController.isClosed) {
          _qrController.add(code);
        }
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

  /// Initiate a VAS settlement adjustment transaction
  Future<void> vasSettlementAdjustment(double amount, String logNo) async {
    if (_type == PosType.arke) {
      try {
        debugPrint(
            '[PosService] Initiating VAS Settlement Adjustment for $amount (Ref: $logNo)...');
        final request = VasRequestBody(
          amount: amount,
          originalVoucherNumber: logNo,
          originalReferenceNumber: logNo,
        );
        await _arke.vas.settlementAdjustment(request);
      } catch (e) {
        debugPrint('[PosService] VAS settlement adjustment error: $e');
      }
    } else {
      debugPrint('[PosService] VAS is only supported on Arke devices.');
    }
  }

  /// Initiate a VAS settle transaction
  Future<void> vasSettle() async {
    if (_type == PosType.arke) {
      try {
        debugPrint('[PosService] Initiating VAS Settle...');
        await _arke.vas.settle();
      } catch (e) {
        debugPrint('[PosService] VAS settle error: $e');
      }
    } else {
      debugPrint('[PosService] VAS is only supported on Arke devices.');
    }
  }

  /// Stream of VAS events (onStart, onNext, onComplete, onError)
  Stream<VasEvent>? get onVasEvent =>
      _type == PosType.arke ? _arke.vas.vasEvents : null;

  // ==================== Beep ====================

  Future<void> beep() async {
    try {
      if (_type == PosType.arke) {
        await _arke.beep(milliseconds: 500);
      } else if (_type == PosType.tapgo) {
        await _tapgo.playBuzzer(durationMs: 500);
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
    } else if (_type == PosType.tapgo) {
      final result = await _tapgo.startNfc();
      debugPrint(
        '[PosService] TapGo startNfc => success=${result.success}, message=${result.message}',
      );
    } else {
      await _cpay.startNfcPolling(intervalMs: 500);
    }
  }

  // ==================== QR ====================

  Future<void> startQrScanning() async {
    if (_type == PosType.tapgo) {
      final result = await _tapgo.startQr();
      debugPrint(
        '[PosService] TapGo startQr => success=${result.success}, message=${result.message}',
      );
      return;
    }

    debugPrint(
        '[PosService] Dedicated QR scanning is not supported on this POS type.');
  }

  Future<void> stopQrScanning() async {
    if (_type == PosType.tapgo) {
      final result = await _tapgo.stopQr();
      debugPrint(
        '[PosService] TapGo stopQr => success=${result.success}, message=${result.message}',
      );
      return;
    }

    debugPrint(
        '[PosService] Dedicated QR scanning is not supported on this POS type.');
  }

  /// Stop NFC polling.
  Future<void> stopNfcPolling() async {
    if (_type == PosType.arke) {
      _arkeNfcPollingActive = false;
      _arkeNfcPollingSession++;
    } else if (_type == PosType.tapgo) {
      final result = await _tapgo.stopNfc();
      debugPrint(
        '[PosService] TapGo stopNfc => success=${result.success}, message=${result.message}',
      );
    } else {
      await _cpay.stopNfcPolling();
    }
  }

  /// Arke NFC loop: continuously call startNfcScan() which blocks until
  /// a card is tapped, then emit event and repeat.
  void _startArkeNfcLoop() {
    if (_arkeNfcPollingActive) return;
    _arkeNfcPollingActive = true;
    final session = ++_arkeNfcPollingSession;

    debugPrint('[PosService] 🔄 Starting Arke NFC loop...');

    Future.doWhile(() async {
      if (!_arkeNfcPollingActive || session != _arkeNfcPollingSession) {
        return false;
      }

      try {
        // startNfcScan() blocks until card is tapped (with internal timeout)
        final uid = await _arke.startNfcScan().timeout(
              const Duration(seconds: 10),
              onTimeout: () => null,
            );

        if (session != _arkeNfcPollingSession || !_arkeNfcPollingActive) {
          debugPrint(
            '[PosService] Ignoring stale Arke NFC result from session=$session',
          );
          return false;
        }

        if (uid != null && uid.isNotEmpty) {
          _lastArkeCardId = uid;
          debugPrint('[PosService] 📱 Arke NFC card detected: $uid');

          if (!_nfcController.isClosed) {
            _nfcController.add(true); // Notify listeners
          }

          // Short cooldown to prevent duplicate reads
          await Future.delayed(const Duration(seconds: 2));
        }
      } catch (e) {
        if (session != _arkeNfcPollingSession || !_arkeNfcPollingActive) {
          debugPrint(
            '[PosService] Arke NFC scan finished after stop (session=$session)',
          );
          return false;
        }

        debugPrint('[PosService] Arke NFC scan error (session=$session): $e');
        // Small delay before retry on error
        await Future.delayed(const Duration(seconds: 1));
      }

      return _arkeNfcPollingActive && session == _arkeNfcPollingSession;
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
    } else if (_type == PosType.tapgo) {
      final id = _lastTapgoCardId;
      final rawData = _lastTapgoRawData;
      _lastTapgoCardId = null;
      _lastTapgoRawData = null;
      if (id == null || id.isEmpty) return null;
      return CardReadResult(id, rawData ?? id);
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
    if (_type == PosType.arke || _type == PosType.tapgo) {
      return null; // Arke/TapGo fallback to app-managed GPS
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

  Future<void> printReceipt(String text, {int align = 0}) async {
    if (_type == PosType.arke) {
      await _arke.printText(text, align: align);
    } else {
      debugPrint('[PosService] Printing not supported on Cpay');
    }
  }

  Future<void> printImageBytes(Uint8List imageBytes, {int align = 1}) async {
    if (_type != PosType.arke) {
      debugPrint('[PosService] Image printing not supported on Cpay');
      return;
    }

    await _arke.printImage(imageBytes, align: align);
  }

  Future<void> printAssetImage(
    String assetPath, {
    int align = 1,
    int? targetWidth = 80,
  }) async {
    if (_type != PosType.arke) {
      debugPrint('[PosService] Image printing not supported on Cpay');
      return;
    }

    try {
      final data = await rootBundle.load(assetPath);
      Uint8List imageBytes = data.buffer.asUint8List();

      if (targetWidth != null && targetWidth > 0) {
        final codec = await ui.instantiateImageCodec(
          imageBytes,
          targetWidth: targetWidth,
        );
        final frame = await codec.getNextFrame();
        final resizedBytes = await frame.image.toByteData(
          format: ui.ImageByteFormat.png,
        );
        if (resizedBytes != null) {
          imageBytes = resizedBytes.buffer.asUint8List();
        }
      }

      await _arke.printImage(imageBytes, align: align);
    } catch (e) {
      debugPrint('[PosService] printAssetImage error: $e');
      rethrow;
    }
  }

  // ==================== Cleanup ====================

  void dispose() {
    _arkeNfcPollingActive = false;
    _arkeNfcPollingSession++;
    _cpayNfcSub?.cancel();
    _tapgoEventSub?.cancel();
    if (!_nfcController.isClosed) {
      _nfcController.close();
    }
    if (!_qrController.isClosed) {
      _qrController.close();
    }
  }
}
