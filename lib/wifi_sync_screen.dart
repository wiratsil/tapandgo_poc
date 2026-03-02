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

/// WiFi Sync Screen - Allows selecting role (Host/Client) and syncing scan data
class WifiSyncScreen extends StatefulWidget {
  const WifiSyncScreen({super.key});

  @override
  State<WifiSyncScreen> createState() => _WifiSyncScreenState();
}

class _WifiSyncScreenState extends State<WifiSyncScreen> {
  final WifiSyncService _syncService = WifiSyncService();
  final TextEditingController _hostIpController = TextEditingController(
    text: WifiSyncService.defaultHostIp,
  );
  final TextEditingController _doorLocationController = TextEditingController(
    text: 'ประตู 2', // Default value, will be updated from service
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

  // Subscriptions
  StreamSubscription<ScanData>? _scanDataSub;
  StreamSubscription<String>? _statusSub;
  StreamSubscription<int>? _clientCountSub;
  StreamSubscription<DiscoveredHost>? _discoveredHostSub;

  @override
  void initState() {
    super.initState();
    _loadSavedHostIp();
    _getLocalIp();
    _setupListeners();
    // Initialize with current service value
    _doorLocationController.text = _syncService.doorLocation;

    // Add listener to update service when text changes
    _doorLocationController.addListener(() {
      _syncService.setDoorLocation(_doorLocationController.text);
    });

    // Restore state from singleton if service is already running
    _restoreStateFromService();
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
      // Android requires location permission to get WiFi info
      if (Platform.isAndroid) {
        var status = await Permission.location.status;
        if (!status.isGranted) {
          status = await Permission.location.request();
        }

        if (!status.isGranted) {
          debugPrint('Location permission denied, cannot get WiFi IP');
          // Show snackbar
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

      // If IP is null, it might be because we are the Hotspot provider
      // Hotspot provider IP is usually 192.168.43.1 on Android
      if (ip == null && Platform.isAndroid) {
        // We can't easily detect if we are hotspot, but we can guess
        // checking network interfaces is another way but complex
        debugPrint('IP is null, might be Hotspot');
      }

      if (mounted) {
        setState(() {
          _localIp = ip;
          // If we couldn't get IP, suggest the default hotspot IP
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
          // Avoid duplicates by checking ID
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
          // Update discovered hosts list
          _discoveredHosts = _syncService.discoveredHosts;
        });
      }
    });
  }

  @override
  void dispose() {
    // Only cancel subscriptions, NOT the service itself (it's a singleton)
    _scanDataSub?.cancel();
    _statusSub?.cancel();
    _clientCountSub?.cancel();
    _discoveredHostSub?.cancel();
    _syncService.stopDiscovery();
    // Do NOT call _syncService.dispose() - it should persist!
    _hostIpController.dispose();
    _doorLocationController.dispose();
    super.dispose();
  }

  Future<void> _searchForHosts() async {
    setState(() {
      _isSearchingHosts = true;
      _discoveredHosts = [];
      _status = 'กำลังค้นหา Host...';
    });

    await _syncService.startDiscoveryListener();

    // Search for 5 seconds
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
        // If local IP is null (common in Hotspot), explicitly show the default hotspot IP
        if (_localIp == null && specificIp == null) {
          _status =
              'Host started (Hotspot IP: ${WifiSyncService.defaultHostIp})';
        } else if (specificIp != null) {
          _status = 'Host started on $specificIp';
        }

        // Auto-set door location for Host
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
      // Save successful IP
      try {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString('last_host_ip', hostIp);
      } catch (e) {
        debugPrint('Error saving Host IP: $e');
      }

      setState(() {
        _selectedRole = SyncRole.client;

        // Auto-set door location for Client
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
      timestamp: DateTime.now(),
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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('WiFi Sync'),
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
          child: Column(
            children: [
              // Status Card
              _buildStatusCard(),

              // Role Selection or Active View
              Expanded(
                child: _selectedRole == SyncRole.none
                    ? _buildRoleSelection()
                    : _buildActiveView(),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildStatusCard() {
    Color statusColor = Colors.grey;
    IconData statusIcon = Icons.wifi_off;

    if (_syncService.isRunning) {
      statusColor = Colors.green;
      statusIcon = _selectedRole == SyncRole.host ? Icons.dns : Icons.wifi;
    }

    return Card(
      margin: const EdgeInsets.all(16),
      elevation: 4,
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
    return Padding(
      padding: const EdgeInsets.all(16),
      child: LayoutBuilder(
        builder: (context, constraints) {
          return SingleChildScrollView(
            child: ConstrainedBox(
              constraints: BoxConstraints(minHeight: constraints.maxHeight),
              child: IntrinsicHeight(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text(
                      'เลือก Role',
                      style: Theme.of(context).textTheme.headlineSmall
                          ?.copyWith(fontWeight: FontWeight.bold),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'เลือกว่าเครื่องนี้จะทำหน้าที่เป็น Host หรือ Client',
                      style: TextStyle(color: Colors.grey.shade600),
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 32),

                    // Host Button
                    _buildRoleButton(
                      title: 'Host (Server)',
                      subtitle: 'เลือกเครือข่าย IP เพื่อทำเป็นเซิร์ฟเวอร์',
                      icon: Icons.dns,
                      color: Colors.deepPurple,
                      onTap: _showNetworkDebugDialog,
                    ),

                    const SizedBox(height: 16),

                    // Client Button
                    _buildRoleButton(
                      title: 'Client',
                      subtitle: 'เชื่อมต่อไปยัง Host',
                      icon: Icons.phone_android,
                      color: Colors.blue,
                      onTap: () => _showClientConnectDialog(),
                    ),
                  ],
                ),
              ),
            ),
          );
        },
      ),
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
                      Navigator.pop(context); // Close dialog
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
    // Check camera availability before opening scanner
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
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
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

        const SizedBox(height: 16),

        // Synced Data List
        Expanded(
          child: Card(
            margin: const EdgeInsets.all(16),
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
                Expanded(
                  child: _syncedData.isEmpty
                      ? Center(
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Icon(
                                Icons.inbox_outlined,
                                size: 64,
                                color: Colors.grey.shade300,
                              ),
                              const SizedBox(height: 16),
                              Text(
                                'ยังไม่มีข้อมูล',
                                style: TextStyle(color: Colors.grey.shade500),
                              ),
                              const SizedBox(height: 8),
                              Text(
                                'กดปุ่ม "สแกน" เพื่อส่งข้อมูล',
                                style: TextStyle(
                                  color: Colors.grey.shade400,
                                  fontSize: 12,
                                ),
                              ),
                            ],
                          ),
                        )
                      : ListView.separated(
                          itemCount: _syncedData.length,
                          separatorBuilder: (_, __) => const Divider(height: 1),
                          itemBuilder: (context, index) {
                            final data = _syncedData[index];
                            return ListTile(
                              leading: CircleAvatar(
                                backgroundColor: Colors.deepPurple.withOpacity(
                                  0.1,
                                ),
                                child: const Icon(
                                  Icons.door_front_door,
                                  color: Colors.deepPurple,
                                ),
                              ),
                              title: Text(
                                data.doorLocation,
                                style: const TextStyle(
                                  fontWeight: FontWeight.w600,
                                ),
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
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  String _formatTime(DateTime time) {
    final hour = time.hour.toString().padLeft(2, '0');
    final minute = time.minute.toString().padLeft(2, '0');
    final second = time.second.toString().padLeft(2, '0');
    return '$hour:$minute:$second';
  }
}
