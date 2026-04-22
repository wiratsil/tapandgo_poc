import 'dart:async';
import 'package:flutter/services.dart';
import 'package:flutter/material.dart';
import 'dart:io';
import 'package:network_info_plus/network_info_plus.dart';
import 'package:uuid/uuid.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'services/wifi_sync_service.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'models/gps_data_model.dart';
import 'services/app_audio_service.dart';
import 'services/database_helper.dart';
import 'services/pos_service.dart';
import 'services/receipt_image_service.dart';
import 'system_checklist_screen.dart';

/// Settings Screen - รวมข้อมูลรถ, WiFi Sync, และเกี่ยวกับแอป
class SettingsScreen extends StatefulWidget {
  final String plateNumber;
  final int? activeRouteId;
  final Future<void> Function(String newPlate) onPlateChanged;
  final List<GpsData> gpsHistory;
  final Stream<GpsData>? gpsStream;
  final bool isOfflineMode;
  final ValueChanged<bool> onOfflineModeChanged;
  final String lastScanLog;
  final String latestLogNo;
  final VoidCallback? onClearCache;
  final bool useDeviceGps;
  final ValueChanged<bool> onUseDeviceGpsChanged;
  final bool showQrScanner;
  final ValueChanged<bool> onShowQrScannerChanged;
  final VoidCallback onResetQrScanner;

  const SettingsScreen({
    super.key,
    required this.plateNumber,
    this.activeRouteId,
    required this.onPlateChanged,
    this.gpsHistory = const [],
    this.gpsStream,
    this.isOfflineMode = false,
    required this.onOfflineModeChanged,
    this.lastScanLog = '',
    this.latestLogNo = '',
    this.onClearCache,
    this.useDeviceGps = false,
    required this.onUseDeviceGpsChanged,
    this.showQrScanner = false,
    required this.onShowQrScannerChanged,
    required this.onResetQrScanner,
  });

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  static const String _receiptLogoAsset = 'assets/BMTA_Logo.png';
  final WifiSyncService _syncService = WifiSyncService();
  final PosService _posService = PosService();
  final TextEditingController _hostIpController = TextEditingController(
    text: WifiSyncService.defaultHostIp,
  );
  final TextEditingController _doorLocationController = TextEditingController(
    text: 'ประตู 2',
  );
  final Uuid _uuid = const Uuid();

  // State
  SyncRole _selectedRole = SyncRole.none;
  String _status = 'ยังไม่ได้เชื่อมต่อ';
  int _clientCount = 0;
  String? _localIp;
  final List<ScanData> _syncedData = [];

  // Discovery state
  List<DiscoveredHost> _discoveredHosts = [];
  bool _isSearchingHosts = false;

  // App info
  String _appVersion = '';
  String _appBuildNumber = '';

  // Current plate (can be updated from dialog)
  late String _currentPlateNumber;
  late bool _localOfflineMode;
  late bool _localUseDeviceGps;
  late bool _localShowQrScanner;

  // GPS History
  late List<GpsData> _localGpsHistory;

  // DB data counts
  final DatabaseHelper _dbHelper = DatabaseHelper();
  int _routeDetailsCount = 0;
  int _priceRangesCount = 0;

  // Subscriptions
  StreamSubscription<ScanData>? _scanDataSub;
  StreamSubscription<String>? _statusSub;
  StreamSubscription<int>? _clientCountSub;
  StreamSubscription<DiscoveredHost>? _discoveredHostSub;

  bool _hasInternet = false;
  Timer? _internetCheckTimer;

  @override
  void initState() {
    super.initState();
    _currentPlateNumber = widget.plateNumber;
    _localOfflineMode = widget.isOfflineMode;
    _localUseDeviceGps = widget.useDeviceGps;
    _localShowQrScanner = widget.showQrScanner;
    _localGpsHistory = List<GpsData>.from(widget.gpsHistory);
    _loadSavedHostIp();
    _getLocalIp();
    _setupListeners();
    _loadAppInfo();
    _loadDbCounts();
    _doorLocationController.text = _syncService.doorLocation;

    _doorLocationController.addListener(() {
      _syncService.setDoorLocation(_doorLocationController.text);
    });

    _restoreStateFromService();

    // Initial internet check and setup periodic check
    _checkInternetConnection();
    _internetCheckTimer = Timer.periodic(const Duration(seconds: 10), (_) {
      _checkInternetConnection();
    });
  }

  Future<void> _checkInternetConnection() async {
    try {
      final result = await InternetAddress.lookup('google.com')
          .timeout(const Duration(seconds: 3));
      final hasInternet = result.isNotEmpty && result[0].rawAddress.isNotEmpty;
      if (mounted && _hasInternet != hasInternet) {
        setState(() {
          _hasInternet = hasInternet;
        });
      }
    } catch (_) {
      if (mounted && _hasInternet) {
        setState(() {
          _hasInternet = false;
        });
      }
    }
  }

  Future<void> _loadAppInfo() async {
    try {
      final info = await PackageInfo.fromPlatform();
      if (mounted) {
        setState(() {
          _appVersion = info.version;
          _appBuildNumber = info.buildNumber;
        });
      }
    } catch (e) {
      debugPrint('Error loading app info: $e');
    }
  }

  Future<void> _loadSavedHostIp() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final savedIp = prefs.getString('last_host_ip');
      if (savedIp != null && savedIp.isNotEmpty) {
        if (mounted) {
          setState(() {
            _hostIpController.text = savedIp;
          });
        }
      }
    } catch (e) {
      debugPrint('Error loading saved Host IP: $e');
    }
  }

  void _restoreStateFromService() {
    if (_syncService.isRunning) {
      setState(() {
        _selectedRole = _syncService.currentRole;
        _status = _syncService.currentRole == SyncRole.host
            ? 'Host running on port ${_syncService.port}'
            : 'Connected to ${_syncService.hostIp}';
      });
    }
  }

  Future<void> _getLocalIp() async {
    try {
      if (Platform.isAndroid) {
        var status = await Permission.location.status;
        if (!status.isGranted) {
          status = await Permission.location.request();
        }

        if (!status.isGranted) {
          debugPrint('Location permission denied, cannot get WiFi IP');
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text('ต้องการ Location Permission เพื่อเริ่ม Host'),
              ),
            );
          }
          return;
        }
      }

      final info = NetworkInfo();
      var ip = await info.getWifiIP();

      if (ip == null && Platform.isAndroid) {
        debugPrint('IP is null, might be Hotspot');
      }

      if (mounted) {
        setState(() {
          _localIp = ip;
          if (_localIp == null) {
            _status = 'ไม่พบ IP (ถ้าเปิด Hotspot อยู่ IP คือ 192.168.43.1)';
          }
        });
      }
    } catch (e) {
      debugPrint('Error getting local IP: $e');
    }
  }

  void _setupListeners() {
    _scanDataSub = _syncService.onScanDataReceived.listen((data) {
      if (mounted) {
        setState(() {
          if (!_syncedData.any((d) => d.id == data.id)) {
            _syncedData.insert(0, data);
          }
        });
      }
    });

    _statusSub = _syncService.onStatusChanged.listen((status) {
      if (mounted) {
        setState(() {
          _status = status;
        });
      }
    });

    _clientCountSub = _syncService.onClientCountChanged.listen((count) {
      if (mounted) {
        setState(() {
          _clientCount = count;
        });
      }
    });

    _discoveredHostSub = _syncService.onHostDiscovered.listen((host) {
      if (mounted) {
        setState(() {
          _discoveredHosts = _syncService.discoveredHosts;
        });
      }
    });
  }

  @override
  void dispose() {
    _scanDataSub?.cancel();
    _statusSub?.cancel();
    _clientCountSub?.cancel();
    _discoveredHostSub?.cancel();
    _internetCheckTimer?.cancel();
    _syncService.stopDiscovery();
    _hostIpController.dispose();
    _doorLocationController.dispose();
    super.dispose();
  }

  // ============ WiFi Sync Methods (เหมือนเดิม) ============

  Future<void> _searchForHosts() async {
    setState(() {
      _isSearchingHosts = true;
      _discoveredHosts = [];
      _status = 'กำลังค้นหา Host...';
    });

    await _syncService.startDiscoveryListener();

    await Future.delayed(const Duration(seconds: 5));

    if (mounted) {
      setState(() {
        _isSearchingHosts = false;
        _discoveredHosts = _syncService.discoveredHosts;
        _status = _discoveredHosts.isEmpty
            ? 'ไม่พบ Host'
            : 'พบ ${_discoveredHosts.length} Host';
      });
    }
  }

  void _selectHost(DiscoveredHost host) {
    setState(() {
      _hostIpController.text = host.ip;
    });
  }

  Future<void> _startAsHost({String? specificIp}) async {
    setState(() {
      _status = 'กำลังเริ่ม Host...';
    });

    final success = await _syncService.startAsHost(bindIp: specificIp);
    if (success) {
      setState(() {
        _selectedRole = SyncRole.host;
        if (_localIp == null && specificIp == null) {
          _status =
              'Host started (Hotspot IP: ${WifiSyncService.defaultHostIp})';
        } else if (specificIp != null) {
          _status = 'Host started on $specificIp';
        }

        _doorLocationController.text = 'ประตู Host';
        _syncService.setDoorLocation('ประตู Host');
      });
    } else {
      setState(() {
        _status = 'ไม่สามารถเริ่ม Host ได้';
      });
      if (mounted) {
        showDialog(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('Error'),
            content: const Text(
              'ไม่สามารถเปิด Host ได้\n1. ตรวจสอบว่าเปิด WiFi/Hotspot แล้ว\n2. ลองปิด-เปิดแอปใหม่',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('ตกลง'),
              ),
            ],
          ),
        );
      }
    }
  }

  Future<void> _startAsClient() async {
    final hostIp = _hostIpController.text.trim();
    if (hostIp.isEmpty) {
      _showSnackBar('กรุณากรอก IP ของ Host');
      return;
    }

    setState(() {
      _status = 'กำลังเชื่อมต่อไปยัง $hostIp...';
    });

    final success = await _syncService.startAsClient(hostIp: hostIp);
    if (success) {
      try {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString('last_host_ip', hostIp);
      } catch (e) {
        debugPrint('Error saving Host IP: $e');
      }

      setState(() {
        _selectedRole = SyncRole.client;

        _doorLocationController.text = 'ประตู Client';
        _syncService.setDoorLocation('ประตู Client');
      });
    } else {
      _showSnackBar('ไม่สามารถเชื่อมต่อได้');
    }
  }

  Future<void> _stopService() async {
    await _syncService.stop();
    setState(() {
      _selectedRole = SyncRole.none;
      _status = 'ยังไม่ได้เชื่อมต่อ';
      _clientCount = 0;
    });
  }

  Future<void> _sendScan() async {
    final scanData = ScanData(
      id: _uuid.v4(),
      timestamp: DateTime.now().toUtc(),
      doorLocation: _doorLocationController.text,
      deviceId: _localIp ?? 'unknown',
    );

    final success = await _syncService.sendScanData(scanData);
    if (!success) {
      _showSnackBar('ไม่สามารถส่งข้อมูลได้');
    }
  }

  void _showSnackBar(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), duration: const Duration(seconds: 2)),
    );
  }

  // ============ Plate Edit ============

  void _showEditPlateDialog() {
    final TextEditingController controller = TextEditingController(
      text: _currentPlateNumber,
    );

    showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('แก้ไขหมายเลขทะเบียนรถ'),
          content: SingleChildScrollView(
            child: TextField(
              controller: controller,
              decoration: const InputDecoration(
                labelText: 'หมายเลขทะเบียน',
                hintText: 'ตัวอย่าง: 12-3456',
                border: OutlineInputBorder(),
              ),
            ),
          ),
          actions: [
            SizedBox(
              width: double.maxFinite,
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  TextButton(
                    style: TextButton.styleFrom(
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      minimumSize: Size.zero,
                    ),
                    onPressed: () async {
                      final currentPlate = controller.text;
                      if (currentPlate.isNotEmpty) {
                        Navigator.of(context).pop();
                        setState(() {
                          _currentPlateNumber = currentPlate;
                        });
                        await widget.onPlateChanged(currentPlate);
                      }
                    },
                    child: const Text(
                      'รีเฟรช',
                      style: TextStyle(color: Colors.blue),
                    ),
                  ),
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      TextButton(
                        onPressed: () => Navigator.of(context).pop(),
                        child: const Text('ยกเลิก'),
                      ),
                      ElevatedButton(
                        onPressed: () async {
                          if (controller.text.isNotEmpty &&
                              controller.text != _currentPlateNumber) {
                            Navigator.of(context).pop();
                            setState(() {
                              _currentPlateNumber = controller.text;
                            });
                            await widget.onPlateChanged(controller.text);
                          } else {
                            Navigator.of(context).pop();
                          }
                        },
                        child: const Text('บันทึก'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        );
      },
    );
  }

  Future<void> _showSettlementDialog() async {
    bool isSubmitting = false;

    await showDialog(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, setDialogState) => AlertDialog(
          title: const Text('Settlement จาก POS'),
          content: const SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text('เรียกคำสั่ง settle โดยตรงผ่าน POS SDK'),
                SizedBox(height: 16),
                Text(
                  'ระบบจะส่งคำสั่ง arke.vas.settle() ไปยังเครื่อง POS ทันที',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 13, color: Colors.black54),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed:
                  isSubmitting ? null : () => Navigator.of(dialogContext).pop(),
              child: const Text('ยกเลิก'),
            ),
            ElevatedButton(
              onPressed: isSubmitting
                  ? null
                  : () async {
                      final messenger = ScaffoldMessenger.of(context);
                      final navigator = Navigator.of(dialogContext);

                      setDialogState(() {
                        isSubmitting = true;
                      });

                      try {
                        await _posService.vasSettle();
                        if (!mounted) return;
                        navigator.pop();
                        messenger.showSnackBar(
                          const SnackBar(
                            content: Text('ส่งคำสั่ง settle ไปที่ POS แล้ว'),
                            duration: Duration(seconds: 2),
                          ),
                        );
                      } catch (e) {
                        if (mounted) {
                          messenger.showSnackBar(
                            SnackBar(
                              content: Text(
                                'เรียก settlement ไม่สำเร็จ: $e',
                              ),
                              duration: const Duration(seconds: 2),
                            ),
                          );
                        }
                        setDialogState(() {
                          isSubmitting = false;
                        });
                      }
                    },
              child: isSubmitting
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Text('เรียก Settle'),
            ),
          ],
        ),
      ),
    );
  }

  bool _hasFreshGpsSignal() {
    if (_localGpsHistory.isEmpty) return false;

    final latestGps = _localGpsHistory.last;
    if (latestGps.lat == 0 || latestGps.lng == 0) return false;

    final recordedAt = latestGps.rec?.toLocal();
    if (recordedAt == null) return true;

    final ageSeconds = DateTime.now().difference(recordedAt).inSeconds;
    return ageSeconds >= -60 && ageSeconds <= 300;
  }

  Future<void> _openSystemChecklist() async {
    final activeTrip = await _dbHelper.getActiveBusTrip();
    if (!mounted) return;

    final routeId = activeTrip?.routeId ?? widget.activeRouteId;
    final routeLabel = routeId != null && routeId != 0 ? '$routeId' : '-';
    final activeBusNo = activeTrip?.busno.trim() ?? '';
    final plateNumber = _currentPlateNumber.trim();
    final busLabel = activeBusNo.isNotEmpty
        ? activeBusNo
        : plateNumber.isNotEmpty
            ? plateNumber
            : '-';
    final hasRouteData = _routeDetailsCount > 0 && _priceRangesCount > 0;
    final tripReady = activeTrip != null ||
        ((widget.activeRouteId ?? 0) != 0 && hasRouteData);
    final readerReady =
        _posService.type != PosType.unknown || _localShowQrScanner;

    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => SystemChecklistScreen(
          routeLabel: routeLabel,
          busLabel: busLabel,
          internetReady: _hasInternet,
          initialGpsReady: _hasFreshGpsSignal(),
          tripReady: tripReady,
          readerReady: readerReady,
          audioReady: AppAudioService.instance.isReady,
          tripStatusLabel: tripReady ? 'Status 3' : 'Status -',
          gpsStream: widget.gpsStream,
        ),
      ),
    );
  }

  Future<void> _printTestReceipt() async {
    final messenger = ScaffoldMessenger.of(context);

    try {
      final imageBytes = await _buildTestReceiptImage();
      if (!mounted) return;
      await _showReceiptPreviewDialog(imageBytes, messenger);
    } catch (e) {
      if (!mounted) return;
      messenger.showSnackBar(
        SnackBar(
          content: Text('สร้างตัวอย่างใบเสร็จไม่สำเร็จ: $e'),
          duration: const Duration(seconds: 2),
        ),
      );
    }
  }

  Future<Uint8List> _buildTestReceiptImage() async {
    final now = DateTime.now();
    final date = '${now.day.toString().padLeft(2, '0')} '
        '${[
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
    ][now.month - 1]} '
        '${now.year + 543}, '
        '${now.hour.toString().padLeft(2, '0')}:'
        '${now.minute.toString().padLeft(2, '0')} น.';
    const txnId = 'TXNTEST2025062000000048';
    const refNo = '3090';

    return ReceiptImageService.buildReceiptImage(
      logoAssetPath: _receiptLogoAsset,
      title: 'รายการสำเร็จ',
      statusText: 'การชำระเงินสำเร็จ',
      timestampText: date,
      sectionTitle: 'ข้อมูลการชำระค่าโดยสาร',
      fields: [
        const ReceiptImageField(
          label: 'ชื่อลูกค้า',
          value: 'พิมพ์พันธุ์ สันแหลม',
          valueAlign: TextAlign.right,
        ),
        ReceiptImageField(
          label: 'สายรถโดยสาร',
          value:
              _currentPlateNumber.isNotEmpty ? _currentPlateNumber : '1-34 ปอ.',
          valueAlign: TextAlign.right,
        ),
        const ReceiptImageField(
            label: 'เลขอ้างอิง', value: refNo, valueAlign: TextAlign.right),
        const ReceiptImageField(
            label: 'เส้นทางเดินรถ',
            value: 'เส้นทางปกติ',
            valueAlign: TextAlign.right),
        const ReceiptImageField(
          label: 'สถานีต้นทาง',
          value: 'ตรงข้ามซอยพหลโยธิน 51',
          valueAlign: TextAlign.right,
        ),
        const ReceiptImageField(
          label: 'สถานีปลายทาง',
          value: 'ตลาดบางเขน',
          valueAlign: TextAlign.right,
        ),
        const ReceiptImageField(
            label: 'จำนวนผู้โดยสาร',
            value: '1 ท่าน',
            valueAlign: TextAlign.right),
        const ReceiptImageField(
            label: 'ค่าธรรมเนียม', value: '0', valueAlign: TextAlign.right),
      ],
      totalLabel: 'ค่าโดยสารรวม',
      totalValue: '12.00',
      paymentMethod: 'พร้อมเพย์',
      discountText: 'ไม่มีสิทธิลดหย่อน',
      transactionNo: txnId,
      footerText: 'ทดสอบการพิมพ์ใบเสร็จ',
    );
  }

  Future<void> _showReceiptPreviewDialog(
    Uint8List imageBytes,
    ScaffoldMessengerState messenger,
  ) async {
    await showDialog(
      context: context,
      builder: (dialogContext) {
        bool isPrinting = false;

        return StatefulBuilder(
          builder: (context, setDialogState) {
            final dialogNavigator = Navigator.of(dialogContext);

            return AlertDialog(
              title: const Text('ตัวอย่างใบเสร็จ'),
              content: SizedBox(
                width: 320,
                child: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(
                        decoration: BoxDecoration(
                          color: Colors.grey.shade200,
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(color: Colors.grey.shade300),
                        ),
                        padding: const EdgeInsets.all(8),
                        child: Image.memory(imageBytes, fit: BoxFit.contain),
                      ),
                      const SizedBox(height: 12),
                      Text(
                        'ตรวจสอบความเรียบร้อยก่อนพิมพ์',
                        style: TextStyle(
                          color: Colors.grey.shade700,
                          fontSize: 13,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              actions: [
                TextButton(
                  onPressed: isPrinting
                      ? null
                      : () => Navigator.of(dialogContext).pop(),
                  child: const Text('ยกเลิก'),
                ),
                ElevatedButton.icon(
                  onPressed: isPrinting
                      ? null
                      : () async {
                          setDialogState(() {
                            isPrinting = true;
                          });

                          try {
                            await _posService.printImageBytes(imageBytes,
                                align: 1);
                            if (!mounted) return;
                            dialogNavigator.pop();
                            messenger.showSnackBar(
                              const SnackBar(
                                content: Text('สั่งปริ้นใบเสร็จทดสอบแล้ว'),
                                duration: Duration(seconds: 2),
                              ),
                            );
                          } catch (e) {
                            if (!mounted) return;
                            setDialogState(() {
                              isPrinting = false;
                            });
                            messenger.showSnackBar(
                              SnackBar(
                                content: Text('ปริ้นใบเสร็จทดสอบไม่สำเร็จ: $e'),
                                duration: const Duration(seconds: 2),
                              ),
                            );
                          }
                        },
                  icon: isPrinting
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.print),
                  label: Text(isPrinting ? 'กำลังพิมพ์...' : 'พิมพ์'),
                ),
              ],
            );
          },
        );
      },
    );
  }

  // ============ UI Build ============

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('ตั้งค่า'),
        backgroundColor: Colors.deepPurple,
        foregroundColor: Colors.white,
        actions: [
          if (_syncService.isRunning)
            IconButton(
              icon: const Icon(Icons.stop),
              onPressed: _stopService,
              tooltip: 'หยุดการเชื่อมต่อ',
            ),
        ],
      ),
      body: Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Colors.deepPurple.shade50, Colors.white],
          ),
        ),
        child: SafeArea(
          child: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              // ========== Section 1: ข้อมูลรถ ==========
              _buildSectionHeader(
                'ข้อมูลรถ',
                Icons.directions_bus,
                Colors.orange,
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Text(
                      'สถานะอุปกรณ์:',
                      style: TextStyle(
                        fontSize: 12,
                        color: Colors.blueGrey,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(width: 8),
                    _buildStatusIcon(Icons.qr_code_scanner, true),
                    const SizedBox(width: 8),
                    _buildStatusIcon(Icons.credit_card, true),
                    const SizedBox(width: 8),
                    _buildStatusIcon(
                      _hasInternet ? Icons.wifi : Icons.wifi_off,
                      _hasInternet,
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 8),
              _buildVehicleInfoSection(),
              const SizedBox(height: 8),
              _buildGpsHistoryButton(),
              const SizedBox(height: 4),
              _buildRouteDetailsButton(),
              const SizedBox(height: 4),
              _buildPriceRangesButton(),
              const SizedBox(height: 24),

              // ========== Section 2: WiFi Sync ==========
              _buildSectionHeader('WiFi Sync', Icons.wifi, Colors.deepPurple),
              const SizedBox(height: 8),
              _buildSyncSection(),
              const SizedBox(height: 24),

              // ========== Section 3: เกี่ยวกับแอป ==========
              _buildSectionHeader(
                  'เกี่ยวกับแอป', Icons.info_outline, Colors.blueGrey),
              const SizedBox(height: 8),
              _buildAboutSection(),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildSectionHeader(String title, IconData icon, Color color,
      {Widget? trailing}) {
    return Row(
      children: [
        Icon(icon, color: color, size: 22),
        const SizedBox(width: 8),
        Text(
          title,
          style: TextStyle(
            fontSize: 18,
            fontWeight: FontWeight.bold,
            color: color,
          ),
        ),
        if (trailing != null) ...[
          const Spacer(),
          trailing,
        ],
      ],
    );
  }

  // ============ Section 1: ข้อมูลรถ ============

  Widget _buildVehicleInfoSection() {
    return Card(
      elevation: 2,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            // ทะเบียนรถ
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: Colors.orange.withOpacity(0.1),
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(
                    Icons.directions_bus,
                    color: Colors.orange,
                    size: 24,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'ทะเบียนรถ',
                        style: TextStyle(
                          fontSize: 13,
                          color: Colors.grey.shade600,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        _currentPlateNumber.isEmpty
                            ? 'ยังไม่ได้กำหนด'
                            : _currentPlateNumber,
                        style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                          color: _currentPlateNumber.isEmpty
                              ? Colors.red
                              : Colors.black87,
                        ),
                      ),
                    ],
                  ),
                ),
                ElevatedButton.icon(
                  onPressed: _showEditPlateDialog,
                  icon: const Icon(Icons.edit, size: 16),
                  label: const Text('แก้ไข'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.orange,
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(20),
                    ),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 8,
                    ),
                  ),
                ),
              ],
            ),

            const Divider(height: 16),

            // Offline Mode Toggle
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: Colors.grey.withOpacity(0.1),
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(
                    Icons.electrical_services,
                    color: Colors.grey,
                    size: 24,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'โหมดออฟไลน์',
                        style: TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        'ข้ามดึงข้อมูล ใช้งานแตะบัตรได้โดยไม่มีเน็ต',
                        style: TextStyle(
                          fontSize: 12,
                          color: Colors.grey.shade600,
                        ),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
                Switch(
                  value: _localOfflineMode,
                  onChanged: (value) {
                    setState(() {
                      _localOfflineMode = value;
                    });
                    widget.onOfflineModeChanged(value);
                    if (!value) {
                      // Request refresh when turning offline mode OFF
                      widget.onPlateChanged(_currentPlateNumber);
                    }
                  },
                  activeColor: Colors.deepPurple,
                ),
              ],
            ),

            const Divider(height: 16),

            // GPS Source Toggle (NFC only)
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: Colors.teal.withOpacity(0.1),
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(
                    Icons.gps_fixed,
                    color: Colors.teal,
                    size: 24,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'GPS สำหรับคำนวณราคา (NFC)',
                        style: TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        _localUseDeviceGps
                            ? 'Device GPS (มือถือ/POS)'
                            : 'MQTT GPS (กล่อง GPS รถเมล์)',
                        style: TextStyle(
                          fontSize: 12,
                          color: Colors.grey.shade600,
                        ),
                      ),
                    ],
                  ),
                ),
                Switch(
                  value: _localUseDeviceGps,
                  onChanged: (value) {
                    setState(() {
                      _localUseDeviceGps = value;
                    });
                    widget.onUseDeviceGpsChanged(value);
                  },
                  activeColor: Colors.teal,
                ),
              ],
            ),

            if (_localShowQrScanner) ...[
              const SizedBox(height: 10),
              SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  onPressed: () {
                    widget.onResetQrScanner();
                    _showSnackBar('รีเซ็ตกล้องสแกน QR แล้ว');
                  },
                  icon: const Icon(Icons.cameraswitch, size: 18),
                  label: const Text(
                    'รีเซ็ตกล้องสแกน QR',
                    style: TextStyle(fontSize: 14),
                  ),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: Colors.orange,
                    side: const BorderSide(color: Colors.orange),
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10),
                    ),
                  ),
                ),
              ),
            ],

            const Divider(height: 16),

            // Main screen QR display mode toggle
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: Colors.orange.withOpacity(0.1),
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(
                    Icons.qr_code_scanner,
                    color: Colors.orange,
                    size: 24,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'โหมดแสดงผล QR หน้าหลัก',
                        style: TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        _localShowQrScanner
                            ? 'แสดงกล้องสแกน QR'
                            : 'แสดง QR Code',
                        style: TextStyle(
                          fontSize: 12,
                          color: Colors.grey.shade600,
                        ),
                      ),
                    ],
                  ),
                ),
                Switch(
                  value: _localShowQrScanner,
                  onChanged: (value) {
                    setState(() {
                      _localShowQrScanner = value;
                    });
                    widget.onShowQrScannerChanged(value);
                  },
                  activeColor: Colors.orange,
                ),
              ],
            ),

            const Divider(height: 16),

            // Route ID
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: Colors.blue.withOpacity(0.1),
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(
                    Icons.route,
                    color: Colors.blue,
                    size: 24,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Route ID',
                        style: TextStyle(
                          fontSize: 13,
                          color: Colors.grey.shade600,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        widget.activeRouteId != null &&
                                widget.activeRouteId != 0
                            ? '${widget.activeRouteId}'
                            : 'ยังไม่มีข้อมูล',
                        style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                          color: widget.activeRouteId != null &&
                                  widget.activeRouteId != 0
                              ? Colors.black87
                              : Colors.grey,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildStatusIcon(IconData icon, bool isReady) {
    return Stack(
      alignment: Alignment.bottomRight,
      children: [
        Icon(icon, color: Colors.grey.shade700, size: 20),
        Container(
          width: 8,
          height: 8,
          decoration: BoxDecoration(
            color: isReady ? Colors.green : Colors.red,
            shape: BoxShape.circle,
            border: Border.all(color: Colors.white, width: 1.5),
          ),
        ),
      ],
    );
  }

  Future<void> _loadDbCounts() async {
    final rdCount = await _dbHelper.getRouteDetailsCount();
    final prCount = await _dbHelper.getPriceRangesCount();
    if (mounted) {
      setState(() {
        _routeDetailsCount = rdCount;
        _priceRangesCount = prCount;
      });
    }
  }

  Widget _buildRouteDetailsButton() {
    final hasData = _routeDetailsCount > 0;
    return Card(
      elevation: 2,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: InkWell(
        onTap: hasData ? _showRouteDetailsDialog : null,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          child: Row(
            children: [
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color:
                      (hasData ? Colors.indigo : Colors.grey).withOpacity(0.1),
                  shape: BoxShape.circle,
                ),
                child: Icon(Icons.map,
                    color: hasData ? Colors.indigo : Colors.grey, size: 20),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Route Details (ป้ายรถ)',
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.bold,
                        color: hasData ? Colors.black87 : Colors.grey,
                      ),
                    ),
                    Text(
                      hasData
                          ? '$_routeDetailsCount รายการ'
                          : 'ยังไม่มีข้อมูล (ต้อง sync ก่อน)',
                      style:
                          TextStyle(fontSize: 12, color: Colors.grey.shade600),
                    ),
                  ],
                ),
              ),
              if (hasData) ...[
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(
                    color: Colors.indigo.shade50,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Text(
                    '$_routeDetailsCount',
                    style: const TextStyle(
                        fontWeight: FontWeight.bold,
                        color: Colors.indigo,
                        fontSize: 13),
                  ),
                ),
                const SizedBox(width: 4),
                const Icon(Icons.chevron_right, color: Colors.grey, size: 20),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildPriceRangesButton() {
    final hasData = _priceRangesCount > 0;
    return Card(
      elevation: 2,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: InkWell(
        onTap: hasData ? _showPriceRangesDialog : null,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          child: Row(
            children: [
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: (hasData ? Colors.amber.shade700 : Colors.grey)
                      .withOpacity(0.1),
                  shape: BoxShape.circle,
                ),
                child: Icon(Icons.attach_money,
                    color: hasData ? Colors.amber.shade700 : Colors.grey,
                    size: 20),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Price Ranges (ช่วงราคา)',
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.bold,
                        color: hasData ? Colors.black87 : Colors.grey,
                      ),
                    ),
                    Text(
                      hasData
                          ? '$_priceRangesCount รายการ'
                          : 'ยังไม่มีข้อมูล (ต้อง sync ก่อน)',
                      style:
                          TextStyle(fontSize: 12, color: Colors.grey.shade600),
                    ),
                  ],
                ),
              ),
              if (hasData) ...[
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(
                    color: Colors.amber.shade50,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Text(
                    '$_priceRangesCount',
                    style: TextStyle(
                        fontWeight: FontWeight.bold,
                        color: Colors.amber.shade700,
                        fontSize: 13),
                  ),
                ),
                const SizedBox(width: 4),
                const Icon(Icons.chevron_right, color: Colors.grey, size: 20),
              ],
            ],
          ),
        ),
      ),
    );
  }

  void _showRouteDetailsDialog() async {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => const Center(child: CircularProgressIndicator()),
    );

    final data = await _dbHelper.getAllRouteDetails();
    if (!mounted) return;
    Navigator.pop(context); // close loading

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Row(
          children: [
            const Icon(Icons.map, color: Colors.indigo, size: 22),
            const SizedBox(width: 8),
            Expanded(
                child: Text('Route Details (${data.length})',
                    style: const TextStyle(fontSize: 16))),
          ],
        ),
        content: SizedBox(
          width: double.maxFinite,
          height: 400,
          child: data.isEmpty
              ? Center(
                  child: Text('ไม่มีข้อมูล',
                      style: TextStyle(color: Colors.grey.shade400)))
              : ListView.builder(
                  itemCount: data.length,
                  itemBuilder: (ctx, i) {
                    final rd = data[i];
                    return Padding(
                      padding: const EdgeInsets.symmetric(vertical: 3),
                      child: Row(
                        children: [
                          SizedBox(
                            width: 30,
                            child: Text(
                              '${rd.seq}',
                              style: const TextStyle(
                                  fontSize: 12,
                                  fontWeight: FontWeight.bold,
                                  fontFamily: 'monospace'),
                            ),
                          ),
                          if (rd.isExpress)
                            Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 4, vertical: 1),
                              margin: const EdgeInsets.only(right: 4),
                              decoration: BoxDecoration(
                                color: Colors.red.shade50,
                                borderRadius: BorderRadius.circular(4),
                              ),
                              child: const Text('ด่วน',
                                  style: TextStyle(
                                      fontSize: 9, color: Colors.red)),
                            ),
                          Expanded(
                            child: Text(
                              rd.busstopDesc,
                              style: const TextStyle(fontSize: 12),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          Text(
                            '${rd.latitude.toStringAsFixed(4)},${rd.longitude.toStringAsFixed(4)}',
                            style: TextStyle(
                                fontSize: 10,
                                color: Colors.grey.shade500,
                                fontFamily: 'monospace'),
                          ),
                        ],
                      ),
                    );
                  },
                ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('ปิด')),
        ],
      ),
    );
  }

  void _showPriceRangesDialog() async {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => const Center(child: CircularProgressIndicator()),
    );

    final data = await _dbHelper.getAllPriceRanges();
    if (!mounted) return;
    Navigator.pop(context); // close loading

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Row(
          children: [
            Icon(Icons.attach_money, color: Colors.amber.shade700, size: 22),
            const SizedBox(width: 8),
            Expanded(
                child: Text('Price Ranges (${data.length})',
                    style: const TextStyle(fontSize: 16))),
          ],
        ),
        content: SizedBox(
          width: double.maxFinite,
          height: 400,
          child: data.isEmpty
              ? Center(
                  child: Text('ไม่มีข้อมูล',
                      style: TextStyle(color: Colors.grey.shade400)))
              : Column(
                  children: [
                    // Header
                    Padding(
                      padding: const EdgeInsets.only(bottom: 6),
                      child: Row(
                        children: [
                          const SizedBox(
                              width: 70,
                              child: Text('ช่วงป้าย',
                                  style: TextStyle(
                                      fontSize: 11,
                                      fontWeight: FontWeight.bold))),
                          const Expanded(
                              child: Text('ราคา',
                                  style: TextStyle(
                                      fontSize: 11,
                                      fontWeight: FontWeight.bold))),
                          const SizedBox(
                              width: 50,
                              child: Text('กลุ่ม',
                                  style: TextStyle(
                                      fontSize: 11,
                                      fontWeight: FontWeight.bold),
                                  textAlign: TextAlign.right)),
                        ],
                      ),
                    ),
                    const Divider(height: 1),
                    Expanded(
                      child: ListView.builder(
                        itemCount: data.length,
                        itemBuilder: (ctx, i) {
                          final pr = data[i];
                          return Padding(
                            padding: const EdgeInsets.symmetric(vertical: 3),
                            child: Row(
                              children: [
                                SizedBox(
                                  width: 70,
                                  child: Text(
                                    '${pr.routeDetailStartSeq}→${pr.routeDetailEndSeq}',
                                    style: const TextStyle(
                                        fontSize: 12, fontFamily: 'monospace'),
                                  ),
                                ),
                                Expanded(
                                  child: Text(
                                    '฿${pr.price.toStringAsFixed(2)}',
                                    style: TextStyle(
                                        fontSize: 12,
                                        fontWeight: FontWeight.bold,
                                        color: Colors.amber.shade800),
                                  ),
                                ),
                                SizedBox(
                                  width: 50,
                                  child: Text(
                                    '${pr.priceGroupId}',
                                    style: TextStyle(
                                        fontSize: 11,
                                        color: Colors.grey.shade600),
                                    textAlign: TextAlign.right,
                                  ),
                                ),
                              ],
                            ),
                          );
                        },
                      ),
                    ),
                  ],
                ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('ปิด')),
        ],
      ),
    );
  }

  Widget _buildGpsHistoryButton() {
    final lastGps = _localGpsHistory.isNotEmpty ? _localGpsHistory.last : null;
    return Card(
      elevation: 2,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: InkWell(
        onTap: _showGpsHistoryDialog,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          child: Row(
            children: [
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: Colors.teal.withOpacity(0.1),
                  shape: BoxShape.circle,
                ),
                child: const Icon(Icons.satellite_alt,
                    color: Colors.teal, size: 20),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'ประวัติ MQTT GPS',
                      style:
                          TextStyle(fontSize: 14, fontWeight: FontWeight.bold),
                    ),
                    Text(
                      lastGps != null
                          ? 'ล่าสุด: ${_formatGpsTime(lastGps.rec)} | ${lastGps.lat.toStringAsFixed(4)}, ${lastGps.lng.toStringAsFixed(4)}'
                          : 'ยังไม่มีข้อมูล',
                      style:
                          TextStyle(fontSize: 12, color: Colors.grey.shade600),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: Colors.teal.shade50,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Text(
                  '${_localGpsHistory.length}',
                  style: const TextStyle(
                      fontWeight: FontWeight.bold,
                      color: Colors.teal,
                      fontSize: 13),
                ),
              ),
              const SizedBox(width: 4),
              const Icon(Icons.chevron_right, color: Colors.grey, size: 20),
            ],
          ),
        ),
      ),
    );
  }

  String _formatGpsTime(DateTime? dt) {
    if (dt == null) return '-';
    return '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}:${dt.second.toString().padLeft(2, '0')}';
  }

  void _showGpsHistoryDialog() {
    // Make a working copy so dialog can update independently
    final dialogHistory = List<GpsData>.from(_localGpsHistory);
    StreamSubscription<GpsData>? dialogSub;

    showDialog(
      context: context,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setDialogState) {
            // Start listening to stream on first build
            dialogSub ??= widget.gpsStream?.listen((gps) {
              setDialogState(() {
                dialogHistory.add(gps);
              });
              // Also update parent state
              setState(() {
                _localGpsHistory.add(gps);
              });
            });

            return AlertDialog(
              title: Row(
                children: [
                  const Icon(Icons.satellite_alt, color: Colors.teal, size: 22),
                  const SizedBox(width: 8),
                  const Expanded(
                    child: Text('ประวัติ MQTT GPS',
                        style: TextStyle(fontSize: 16)),
                  ),
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                    decoration: BoxDecoration(
                      color: Colors.teal.shade50,
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Text(
                      '${dialogHistory.length}',
                      style: const TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.bold,
                          color: Colors.teal),
                    ),
                  ),
                ],
              ),
              content: SizedBox(
                width: double.maxFinite,
                height: 400,
                child: dialogHistory.isEmpty
                    ? Center(
                        child: Text('ยังไม่มีข้อมูล GPS',
                            style: TextStyle(color: Colors.grey.shade400)),
                      )
                    : ListView.builder(
                        reverse: true,
                        itemCount: dialogHistory.length,
                        itemBuilder: (ctx, index) {
                          // reverse: true shows from bottom, so index 0 = last item
                          final gps =
                              dialogHistory[dialogHistory.length - 1 - index];
                          return Padding(
                            padding: const EdgeInsets.symmetric(vertical: 3),
                            child: Row(
                              children: [
                                // Time
                                SizedBox(
                                  width: 60,
                                  child: Text(
                                    _formatGpsTime(gps.rec),
                                    style: const TextStyle(
                                        fontSize: 12,
                                        fontWeight: FontWeight.w600,
                                        fontFamily: 'monospace'),
                                  ),
                                ),
                                // Lat/Lng
                                Expanded(
                                  child: Text(
                                    '${gps.lat.toStringAsFixed(5)}, ${gps.lng.toStringAsFixed(5)}',
                                    style: const TextStyle(
                                        fontSize: 11, fontFamily: 'monospace'),
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                                // Speed
                                SizedBox(
                                  width: 48,
                                  child: Text(
                                    '${gps.spd.toStringAsFixed(0)} km',
                                    style: TextStyle(
                                        fontSize: 11,
                                        color: Colors.grey.shade600),
                                    textAlign: TextAlign.right,
                                  ),
                                ),
                              ],
                            ),
                          );
                        },
                      ),
              ),
              actions: [
                if (dialogHistory.isNotEmpty)
                  TextButton(
                    onPressed: () {
                      setDialogState(() => dialogHistory.clear());
                      setState(() => _localGpsHistory.clear());
                    },
                    child:
                        const Text('ล้าง', style: TextStyle(color: Colors.red)),
                  ),
                TextButton(
                  onPressed: () {
                    dialogSub?.cancel();
                    Navigator.pop(ctx);
                  },
                  child: const Text('ปิด'),
                ),
              ],
            );
          },
        );
      },
    ).then((_) {
      dialogSub?.cancel();
    });
  }

  // ============ Section 2: WiFi Sync (Compact) ============

  Widget _buildSyncSection() {
    Color statusColor = Colors.grey;
    IconData statusIcon = Icons.wifi_off;
    String roleLabel = 'ไม่ได้เชื่อมต่อ';

    if (_syncService.isRunning) {
      statusColor = Colors.green;
      if (_selectedRole == SyncRole.host) {
        statusIcon = Icons.dns;
        roleLabel = 'Host';
      } else {
        statusIcon = Icons.wifi;
        roleLabel = 'Client';
      }
    }

    return Card(
      elevation: 2,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // === Status Row ===
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: statusColor.withOpacity(0.1),
                    shape: BoxShape.circle,
                  ),
                  child: Icon(statusIcon, color: statusColor, size: 20),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        roleLabel,
                        style: TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.bold,
                          color: statusColor,
                        ),
                      ),
                      Text(
                        _status,
                        style: TextStyle(
                            color: Colors.grey.shade600, fontSize: 12),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
                if (_selectedRole == SyncRole.host)
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    decoration: BoxDecoration(
                      color: Colors.blue.shade50,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(Icons.people, size: 14, color: Colors.blue),
                        const SizedBox(width: 4),
                        Text('$_clientCount',
                            style: const TextStyle(
                                fontWeight: FontWeight.bold,
                                color: Colors.blue,
                                fontSize: 13)),
                      ],
                    ),
                  ),
                if (_syncService.isRunning)
                  Padding(
                    padding: const EdgeInsets.only(left: 8),
                    child: InkWell(
                      onTap: _stopService,
                      borderRadius: BorderRadius.circular(20),
                      child: Container(
                        padding: const EdgeInsets.all(6),
                        decoration: BoxDecoration(
                          color: Colors.red.withOpacity(0.1),
                          shape: BoxShape.circle,
                        ),
                        child:
                            const Icon(Icons.stop, color: Colors.red, size: 18),
                      ),
                    ),
                  ),
              ],
            ),

            // === Local IP ===
            if (_localIp != null) ...[
              const SizedBox(height: 6),
              Row(
                children: [
                  const Icon(Icons.wifi, size: 14, color: Colors.grey),
                  const SizedBox(width: 6),
                  Text('IP: $_localIp',
                      style:
                          TextStyle(color: Colors.grey.shade500, fontSize: 12)),
                ],
              ),
            ],

            // === Role selection (when not connected) ===
            if (_selectedRole == SyncRole.none) ...[
              const Divider(height: 20),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: _showNetworkDebugDialog,
                      icon: const Icon(Icons.dns, size: 16),
                      label: const Text('Host', style: TextStyle(fontSize: 13)),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: Colors.deepPurple,
                        side: const BorderSide(color: Colors.deepPurple),
                        padding: const EdgeInsets.symmetric(vertical: 10),
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(10)),
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: _showClientConnectDialog,
                      icon: const Icon(Icons.phone_android, size: 16),
                      label:
                          const Text('Client', style: TextStyle(fontSize: 13)),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: Colors.blue,
                        side: const BorderSide(color: Colors.blue),
                        padding: const EdgeInsets.symmetric(vertical: 10),
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(10)),
                      ),
                    ),
                  ),
                ],
              ),
            ],

            // === QR Code (Host) ===
            if (_selectedRole == SyncRole.host &&
                _syncService.hostIp != null &&
                _syncService.hostIp!.isNotEmpty) ...[
              const Divider(height: 16),
              Center(
                child: Column(
                  children: [
                    Text('Client สแกน QR เพื่อเชื่อมต่อ',
                        style: TextStyle(
                            fontSize: 12, color: Colors.grey.shade600)),
                    const SizedBox(height: 8),
                    Container(
                      padding: const EdgeInsets.all(6),
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: Colors.grey.shade300),
                      ),
                      child: QrImageView(
                        data: _syncService.hostIp!,
                        version: QrVersions.auto,
                        size: 120.0,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      _syncService.hostIp!,
                      style: const TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.bold,
                          letterSpacing: 1.5),
                    ),
                  ],
                ),
              ),
            ],

            // === Active: Door location + Scan ===
            if (_selectedRole != SyncRole.none) ...[
              const Divider(height: 16),
              Row(
                children: [
                  Expanded(
                    child: SizedBox(
                      height: 42,
                      child: TextField(
                        controller: _doorLocationController,
                        style: const TextStyle(fontSize: 14),
                        decoration: InputDecoration(
                          labelText: 'ตำแหน่งประตู',
                          labelStyle: const TextStyle(fontSize: 13),
                          border: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(8)),
                          prefixIcon:
                              const Icon(Icons.door_front_door, size: 18),
                          contentPadding: const EdgeInsets.symmetric(
                              horizontal: 10, vertical: 8),
                          isDense: true,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  SizedBox(
                    height: 42,
                    child: ElevatedButton.icon(
                      onPressed: _syncService.isRunning ? _sendScan : null,
                      icon: const Icon(Icons.qr_code_scanner, size: 16),
                      label: const Text('สแกน', style: TextStyle(fontSize: 13)),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.green,
                        foregroundColor: Colors.white,
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(8)),
                        padding: const EdgeInsets.symmetric(horizontal: 12),
                      ),
                    ),
                  ),
                ],
              ),
            ],

            // === Synced Data (collapsible) ===
            if (_selectedRole != SyncRole.none) ...[
              const SizedBox(height: 8),
              Theme(
                data: Theme.of(context)
                    .copyWith(dividerColor: Colors.transparent),
                child: ExpansionTile(
                  tilePadding: EdgeInsets.zero,
                  childrenPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.sync,
                      color: Colors.deepPurple, size: 20),
                  title: Text(
                    'ข้อมูลที่ Sync (${_syncedData.length})',
                    style: const TextStyle(
                        fontSize: 14, fontWeight: FontWeight.bold),
                  ),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (_syncedData.isNotEmpty)
                        GestureDetector(
                          onTap: () => setState(() => _syncedData.clear()),
                          child: const Padding(
                            padding: EdgeInsets.only(right: 8),
                            child: Icon(Icons.clear_all,
                                size: 18, color: Colors.grey),
                          ),
                        ),
                      const Icon(Icons.expand_more, size: 20),
                    ],
                  ),
                  children: [
                    if (_syncedData.isEmpty)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 16),
                        child: Center(
                          child: Text('ยังไม่มีข้อมูล',
                              style: TextStyle(
                                  color: Colors.grey.shade400, fontSize: 13)),
                        ),
                      )
                    else
                      ...List.generate(_syncedData.length, (index) {
                        final data = _syncedData[index];
                        return Padding(
                          padding: const EdgeInsets.symmetric(vertical: 4),
                          child: Row(
                            children: [
                              Icon(Icons.door_front_door,
                                  color: Colors.deepPurple.withOpacity(0.5),
                                  size: 18),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Text(
                                  '${data.doorLocation} • ${_formatTime(data.timestamp)}',
                                  style: const TextStyle(fontSize: 13),
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                              Text(
                                data.id.substring(0, 6),
                                style: TextStyle(
                                    color: Colors.grey.shade400,
                                    fontSize: 10,
                                    fontFamily: 'monospace'),
                              ),
                            ],
                          ),
                        );
                      }),
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
  // ============ WiFi Sync Dialogs ============

  Future<void> _showNetworkDebugDialog() async {
    final ips = await _syncService.getInternalIps();
    if (!mounted) return;

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Network Interfaces'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (ips.isEmpty) const Text('No IPv4 interfaces found.'),
              ...ips.map((ip) {
                final address = ip.split(': ')[1];
                return ListTile(
                  title: Text(address),
                  subtitle: Text(ip.split(': ')[0]),
                  leading: const Icon(Icons.network_check),
                  onTap: () {
                    Clipboard.setData(ClipboardData(text: address));
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('Copied to clipboard')),
                    );
                  },
                  trailing: IconButton(
                    icon: const Icon(Icons.play_arrow, color: Colors.green),
                    tooltip: 'Start Host on this IP',
                    onPressed: () {
                      Navigator.pop(context);
                      _startAsHost(specificIp: address);
                    },
                  ),
                );
              }),
              const Divider(),
              const Text(
                'Note: Click Play (▶) to force start Host on a specific IP.',
                style: TextStyle(fontSize: 12, color: Colors.grey),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  void _showClientConnectDialog() {
    showDialog(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('เชื่อมต่อไปยัง Host'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton.icon(
                    onPressed: _isSearchingHosts
                        ? null
                        : () async {
                            setDialogState(() {});
                            await _searchForHosts();
                            setDialogState(() {});
                          },
                    icon: _isSearchingHosts
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: Colors.white,
                            ),
                          )
                        : const Icon(Icons.search),
                    label: Text(
                      _isSearchingHosts
                          ? 'กำลังค้นหา...'
                          : '🔍 ค้นหา Host อัตโนมัติ',
                    ),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.orange,
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(vertical: 12),
                    ),
                  ),
                ),
                if (_discoveredHosts.isNotEmpty) ...[
                  const SizedBox(height: 16),
                  const Text('Host ที่พบ:',
                      style: TextStyle(fontWeight: FontWeight.bold)),
                  const SizedBox(height: 8),
                  Container(
                    constraints: const BoxConstraints(maxHeight: 150),
                    child: ListView.builder(
                      shrinkWrap: true,
                      itemCount: _discoveredHosts.length,
                      itemBuilder: (context, index) {
                        final host = _discoveredHosts[index];
                        return Card(
                          child: ListTile(
                            leading:
                                const Icon(Icons.computer, color: Colors.green),
                            title: Text(host.deviceName),
                            subtitle: Text('${host.ip}:${host.port}'),
                            onTap: () {
                              _selectHost(host);
                              setDialogState(() {});
                            },
                            trailing: _hostIpController.text == host.ip
                                ? const Icon(Icons.check_circle,
                                    color: Colors.green)
                                : null,
                          ),
                        );
                      },
                    ),
                  ),
                ] else if (!_isSearchingHosts) ...[
                  const SizedBox(height: 8),
                  Text(
                    'หรือกรอก IP ด้วยตนเอง:',
                    style: TextStyle(color: Colors.grey.shade600, fontSize: 12),
                  ),
                ],
                const SizedBox(height: 16),
                TextField(
                  controller: _hostIpController,
                  decoration: InputDecoration(
                    labelText: 'Host IP',
                    hintText: '192.168.43.1',
                    border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12)),
                    prefixIcon: const Icon(Icons.wifi),
                    suffixIcon: IconButton(
                      icon: const Icon(Icons.qr_code_scanner,
                          color: Colors.deepPurple),
                      onPressed: () async {
                        final scannedIp = await _scanQrCode();
                        if (scannedIp != null && mounted) {
                          _hostIpController.text = scannedIp;
                        }
                      },
                    ),
                  ),
                  keyboardType: TextInputType.number,
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () {
                _syncService.stopDiscovery();
                Navigator.pop(context);
              },
              child: const Text('ยกเลิก'),
            ),
            ElevatedButton(
              onPressed: () {
                _syncService.stopDiscovery();
                Navigator.pop(context);
                _startAsClient();
              },
              child: const Text('เชื่อมต่อ'),
            ),
          ],
        ),
      ),
    );
  }

  Future<String?> _scanQrCode() async {
    const cameraChannel =
        MethodChannel('com.example.tapandgo_poc/camera_check');
    int cameraCount = 0;
    try {
      cameraCount = await cameraChannel.invokeMethod('checkCamera') ?? 0;
    } catch (e) {
      debugPrint('Camera check failed: $e');
    }

    if (cameraCount == 0) {
      if (!mounted) return null;
      await showDialog(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('ไม่พบกล้อง'),
          content: const Text(
              'อุปกรณ์นี้ไม่มีกล้อง ไม่สามารถสแกน QR Code ได้\nกรุณาใส่ IP ด้วยตนเอง'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('ตกลง'),
            ),
          ],
        ),
      );
      return null;
    }

    final scannerController = MobileScannerController(
      facing: CameraFacing.front,
    );

    return showDialog<String>(
      context: context,
      builder: (context) {
        return Dialog(
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
          child: Container(
            height: 400,
            padding: const EdgeInsets.all(16),
            child: Column(
              children: [
                const Text(
                  'สแกน QR Code จากเครื่อง Host',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 16),
                Expanded(
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(16),
                    child: MobileScanner(
                      controller: scannerController,
                      onDetect: (capture) {
                        final barcodes = capture.barcodes;
                        if (barcodes.isNotEmpty) {
                          final value = barcodes.first.rawValue;
                          if (value != null && value.isNotEmpty) {
                            Navigator.pop(context, value);
                          }
                        }
                      },
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('ยกเลิก'),
                ),
              ],
            ),
          ),
        );
      },
    ).whenComplete(scannerController.dispose);
  }

  // ============ Section 3: เกี่ยวกับแอป ============

  Widget _buildAboutSection() {
    return Card(
      elevation: 2,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: Colors.blueGrey.withOpacity(0.1),
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(
                    Icons.directions_bus_filled_rounded,
                    color: Colors.blueGrey,
                    size: 24,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'TapAndGo POC',
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        'ขสมก. BMTA',
                        style: TextStyle(
                          fontSize: 13,
                          color: Colors.grey.shade600,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const Divider(height: 24),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  'เวอร์ชัน',
                  style: TextStyle(
                    fontSize: 14,
                    color: Colors.grey.shade600,
                  ),
                ),
                Text(
                  _appVersion.isNotEmpty
                      ? '$_appVersion ($_appBuildNumber)'
                      : 'กำลังโหลด...',
                  style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
            const Divider(height: 24),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                onPressed: _openSystemChecklist,
                icon: const Icon(Icons.fact_check_rounded),
                label: const Text('ตรวจสอบความพร้อมระบบ'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.black87,
                  foregroundColor: Colors.white,
                ),
              ),
            ),
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                onPressed: _showSettlementDialog,
                icon: const Icon(Icons.point_of_sale),
                label: const Text('Settlement ผ่าน POS SDK'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.teal,
                  foregroundColor: Colors.white,
                ),
              ),
            ),
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                onPressed: _printTestReceipt,
                icon: const Icon(Icons.print),
                label: const Text('ทดสอบปริ้นใบเสร็จ'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.indigo,
                  foregroundColor: Colors.white,
                ),
              ),
            ),
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                onPressed: () {
                  showDialog(
                    context: context,
                    builder: (ctx) => AlertDialog(
                      title: const Text('ข้อมูลสแกนล่าสุด'),
                      content: SingleChildScrollView(
                        child: SelectableText(
                          widget.lastScanLog.isNotEmpty
                              ? widget.lastScanLog
                              : 'ยังไม่มีข้อมูลการสแกนในรอบการใช้งานนี้',
                        ),
                      ),
                      actions: [
                        TextButton(
                          onPressed: () => Navigator.of(ctx).pop(),
                          child: const Text('ปิด'),
                        ),
                      ],
                    ),
                  );
                },
                icon: const Icon(Icons.receipt_long),
                label: const Text('ดูข้อมูลสแกนล่าสุด (Log)'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.blueGrey,
                  foregroundColor: Colors.white,
                ),
              ),
            ),
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                onPressed: () {
                  showDialog(
                    context: context,
                    builder: (ctx) => AlertDialog(
                      title: const Text('ยืนยันล้างข้อมูลแคช'),
                      content: const Text(
                        'การกระทำนี้จะลบข้อมูลเส้นทาง ป้ายรถเมล์ ประวัติการสแกน และรายการแตะบัตรที่ยังไม่ได้ส่งทั้งหมด\n\n(คุณจะต้องรอให้แอปโหลดข้อมูลเส้นทางใหม่ และรายการแตะเดิมจะหายไป)\n\nคุณแน่ใจหรือไม่?',
                      ),
                      actions: [
                        TextButton(
                          onPressed: () => Navigator.of(ctx).pop(),
                          child: const Text('ยกเลิก',
                              style: TextStyle(color: Colors.grey)),
                        ),
                        ElevatedButton(
                          onPressed: () {
                            Navigator.of(ctx).pop();
                            if (widget.onClearCache != null) {
                              widget.onClearCache!();
                            }
                          },
                          style: ElevatedButton.styleFrom(
                              backgroundColor: Colors.red),
                          child: const Text('ยืนยันล้างข้อมูล',
                              style: TextStyle(color: Colors.white)),
                        ),
                      ],
                    ),
                  );
                },
                icon: const Icon(Icons.delete_sweep),
                label: const Text('ล้างข้อมูลแคชและประวัติ (Clear Cache)'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.red.shade600,
                  foregroundColor: Colors.white,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _formatTime(DateTime time) {
    final hour = time.hour.toString().padLeft(2, '0');
    final minute = time.minute.toString().padLeft(2, '0');
    final second = time.second.toString().padLeft(2, '0');
    return '$hour:$minute:$second';
  }
}
