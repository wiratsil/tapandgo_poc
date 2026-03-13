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

/// Settings Screen - รวมข้อมูลรถ, WiFi Sync, และเกี่ยวกับแอป
class SettingsScreen extends StatefulWidget {
  final String plateNumber;
  final int? activeRouteId;
  final Future<void> Function(String newPlate) onPlateChanged;

  const SettingsScreen({
    super.key,
    required this.plateNumber,
    this.activeRouteId,
    required this.onPlateChanged,
  });

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  final WifiSyncService _syncService = WifiSyncService();
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

  // Subscriptions
  StreamSubscription<ScanData>? _scanDataSub;
  StreamSubscription<String>? _statusSub;
  StreamSubscription<int>? _clientCountSub;
  StreamSubscription<DiscoveredHost>? _discoveredHostSub;

  @override
  void initState() {
    super.initState();
    _currentPlateNumber = widget.plateNumber;
    _loadSavedHostIp();
    _getLocalIp();
    _setupListeners();
    _loadAppInfo();
    _doorLocationController.text = _syncService.doorLocation;

    _doorLocationController.addListener(() {
      _syncService.setDoorLocation(_doorLocationController.text);
    });

    _restoreStateFromService();
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
              _buildSectionHeader('ข้อมูลรถ', Icons.directions_bus, Colors.orange),
              const SizedBox(height: 8),
              _buildVehicleInfoSection(),
              const SizedBox(height: 24),

              // ========== Section 2: WiFi Sync ==========
              _buildSectionHeader('WiFi Sync', Icons.wifi, Colors.deepPurple),
              const SizedBox(height: 8),
              _buildSyncStatusCard(),
              const SizedBox(height: 8),
              if (_selectedRole == SyncRole.none) _buildRoleSelection(),
              if (_selectedRole != SyncRole.none) _buildActiveView(),
              const SizedBox(height: 24),

              // ========== Section 3: เกี่ยวกับแอป ==========
              _buildSectionHeader('เกี่ยวกับแอป', Icons.info_outline, Colors.blueGrey),
              const SizedBox(height: 8),
              _buildAboutSection(),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildSectionHeader(String title, IconData icon, Color color) {
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

            const Divider(height: 24),

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

  // ============ Section 2: WiFi Sync ============

  Widget _buildSyncStatusCard() {
    Color statusColor = Colors.grey;
    IconData statusIcon = Icons.wifi_off;

    if (_syncService.isRunning) {
      statusColor = Colors.green;
      statusIcon = _selectedRole == SyncRole.host ? Icons.dns : Icons.wifi;
    }

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
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: statusColor.withOpacity(0.1),
                    shape: BoxShape.circle,
                  ),
                  child: Icon(statusIcon, color: statusColor, size: 28),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        _selectedRole == SyncRole.none
                            ? 'ไม่ได้เชื่อมต่อ'
                            : _selectedRole == SyncRole.host
                            ? '🖥️ Host (Server)'
                            : '📱 Client',
                        style: const TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        _status,
                        style: TextStyle(color: Colors.grey.shade600),
                      ),
                    ],
                  ),
                ),
                if (_selectedRole == SyncRole.host)
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 6,
                    ),
                    decoration: BoxDecoration(
                      color: Colors.blue.shade100,
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(Icons.people, size: 16, color: Colors.blue),
                        const SizedBox(width: 4),
                        Text(
                          '$_clientCount',
                          style: const TextStyle(
                            fontWeight: FontWeight.bold,
                            color: Colors.blue,
                          ),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
            if (_localIp != null) ...[
              const Divider(height: 24),
              Row(
                children: [
                  const Icon(Icons.wifi, size: 16, color: Colors.grey),
                  const SizedBox(width: 8),
                  Text(
                    'IP ของเครื่องนี้: $_localIp',
                    style: TextStyle(color: Colors.grey.shade600),
                  ),
                ],
              ),
            ],
            if (_selectedRole == SyncRole.host &&
                _syncService.hostIp != null &&
                _syncService.hostIp!.isNotEmpty) ...[
              const Divider(height: 24),
              const Text(
                'ให้ Client สแกน QR Code เพื่อเชื่อมต่อ',
                style: TextStyle(fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 16),
              Center(
                child: Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: QrImageView(
                    data: _syncService.hostIp!,
                    version: QrVersions.auto,
                    size: 150.0,
                  ),
                ),
              ),
              const SizedBox(height: 8),
              Center(
                child: Text(
                  _syncService.hostIp!,
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                    letterSpacing: 2,
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildRoleSelection() {
    return Column(
      children: [
        _buildRoleButton(
          title: 'Host (Server)',
          subtitle: 'เลือกเครือข่าย IP เพื่อทำเป็นเซิร์ฟเวอร์',
          icon: Icons.dns,
          color: Colors.deepPurple,
          onTap: _showNetworkDebugDialog,
        ),
        const SizedBox(height: 8),
        _buildRoleButton(
          title: 'Client',
          subtitle: 'เชื่อมต่อไปยัง Host',
          icon: Icons.phone_android,
          color: Colors.blue,
          onTap: () => _showClientConnectDialog(),
        ),
      ],
    );
  }

  Widget _buildRoleButton({
    required String title,
    required String subtitle,
    required IconData icon,
    required Color color,
    required VoidCallback onTap,
  }) {
    return SizedBox(
      width: double.infinity,
      child: Card(
        elevation: 2,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(16),
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: color.withOpacity(0.1),
                    shape: BoxShape.circle,
                  ),
                  child: Icon(icon, color: color, size: 32),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                          color: color,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        subtitle,
                        style: TextStyle(color: Colors.grey.shade600),
                      ),
                    ],
                  ),
                ),
                Icon(Icons.arrow_forward_ios, color: color, size: 20),
              ],
            ),
          ),
        ),
      ),
    );
  }

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
                // Search button
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

                // Discovered hosts list
                if (_discoveredHosts.isNotEmpty) ...[
                  const SizedBox(height: 16),
                  const Text(
                    'Host ที่พบ:',
                    style: TextStyle(fontWeight: FontWeight.bold),
                  ),
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
                            leading: const Icon(
                              Icons.computer,
                              color: Colors.green,
                            ),
                            title: Text(host.deviceName),
                            subtitle: Text('${host.ip}:${host.port}'),
                            onTap: () {
                              _selectHost(host);
                              setDialogState(() {});
                            },
                            trailing: _hostIpController.text == host.ip
                                ? const Icon(
                                    Icons.check_circle,
                                    color: Colors.green,
                                  )
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
                      borderRadius: BorderRadius.circular(12),
                    ),
                    prefixIcon: const Icon(Icons.wifi),
                    suffixIcon: IconButton(
                      icon: const Icon(
                        Icons.qr_code_scanner,
                        color: Colors.deepPurple,
                      ),
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
    const cameraChannel = MethodChannel(
      'com.example.tapandgo_poc/camera_check',
    );
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
            'อุปกรณ์นี้ไม่มีกล้อง ไม่สามารถสแกน QR Code ได้\nกรุณาใส่ IP ด้วยตนเอง',
          ),
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

    return showDialog<String>(
      context: context,
      builder: (context) {
        return Dialog(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(20),
          ),
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
    );
  }

  Widget _buildActiveView() {
    return Column(
      children: [
        // Door location and Scan button
        Card(
          elevation: 2,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _doorLocationController,
                    decoration: InputDecoration(
                      labelText: 'ตำแหน่งประตู',
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                      prefixIcon: const Icon(Icons.door_front_door),
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 12,
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 16),
                SizedBox(
                  height: 56,
                  child: ElevatedButton.icon(
                    onPressed: _syncService.isRunning ? _sendScan : null,
                    icon: const Icon(Icons.qr_code_scanner),
                    label: const Text('สแกน'),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.green,
                      foregroundColor: Colors.white,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                      padding: const EdgeInsets.symmetric(horizontal: 24),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),

        const SizedBox(height: 8),

        // Synced Data List
        Card(
          elevation: 2,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.all(16),
                child: Row(
                  children: [
                    const Icon(Icons.sync, color: Colors.deepPurple),
                    const SizedBox(width: 8),
                    Text(
                      'ข้อมูลที่ Sync (${_syncedData.length})',
                      style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const Spacer(),
                    if (_syncedData.isNotEmpty)
                      TextButton.icon(
                        onPressed: () {
                          setState(() {
                            _syncedData.clear();
                          });
                        },
                        icon: const Icon(Icons.clear_all, size: 18),
                        label: const Text('ล้าง'),
                      ),
                  ],
                ),
              ),
              const Divider(height: 1),
              if (_syncedData.isEmpty)
                Padding(
                  padding: const EdgeInsets.all(32),
                  child: Center(
                    child: Column(
                      children: [
                        Icon(
                          Icons.inbox_outlined,
                          size: 48,
                          color: Colors.grey.shade300,
                        ),
                        const SizedBox(height: 8),
                        Text(
                          'ยังไม่มีข้อมูล',
                          style: TextStyle(color: Colors.grey.shade500),
                        ),
                      ],
                    ),
                  ),
                )
              else
                ListView.separated(
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  itemCount: _syncedData.length,
                  separatorBuilder: (_, __) => const Divider(height: 1),
                  itemBuilder: (context, index) {
                    final data = _syncedData[index];
                    return ListTile(
                      leading: CircleAvatar(
                        backgroundColor: Colors.deepPurple.withOpacity(0.1),
                        child: const Icon(
                          Icons.door_front_door,
                          color: Colors.deepPurple,
                        ),
                      ),
                      title: Text(
                        data.doorLocation,
                        style: const TextStyle(fontWeight: FontWeight.w600),
                      ),
                      subtitle: Text(
                        '${_formatTime(data.timestamp)} • ${data.deviceId ?? ""}',
                        style: TextStyle(
                          color: Colors.grey.shade600,
                          fontSize: 12,
                        ),
                      ),
                      trailing: Text(
                        data.id.substring(0, 8),
                        style: TextStyle(
                          color: Colors.grey.shade400,
                          fontSize: 11,
                          fontFamily: 'monospace',
                        ),
                      ),
                    );
                  },
                ),
            ],
          ),
        ),
      ],
    );
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
