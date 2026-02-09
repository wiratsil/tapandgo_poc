import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';

/// Role of the device in the sync network
enum SyncRole { host, client, none }

/// Scan data model for syncing between devices
class ScanData {
  final String id;
  final DateTime timestamp;
  final String doorLocation;
  final String? deviceId;

  ScanData({
    required this.id,
    required this.timestamp,
    required this.doorLocation,
    this.deviceId,
  });

  Map<String, dynamic> toJson() => {
    'id': id,
    'timestamp': timestamp.toIso8601String(),
    'door_location': doorLocation,
    'device_id': deviceId,
  };

  factory ScanData.fromJson(Map<String, dynamic> json) => ScanData(
    id: json['id'] as String,
    timestamp: DateTime.parse(json['timestamp'] as String),
    doorLocation: json['door_location'] as String,
    deviceId: json['device_id'] as String?,
  );

  @override
  String toString() =>
      'ScanData(id: $id, door: $doorLocation, time: $timestamp)';
}

/// Pending transaction sync data - for syncing Tap In/Out state between devices
class PendingTransactionSync {
  final String aid;
  final DateTime tapInTime;
  final double tapInLat;
  final double tapInLng;
  final bool isRemove; // true = remove from pending (after tap out)

  PendingTransactionSync({
    required this.aid,
    required this.tapInTime,
    this.tapInLat = 0.0,
    this.tapInLng = 0.0,
    this.isRemove = false,
  });

  Map<String, dynamic> toJson() => {
    'type': 'pending_sync',
    'aid': aid,
    'tap_in_time': tapInTime.toIso8601String(),
    'tap_in_lat': tapInLat,
    'tap_in_lng': tapInLng,
    'is_remove': isRemove,
  };

  factory PendingTransactionSync.fromJson(Map<String, dynamic> json) =>
      PendingTransactionSync(
        aid: json['aid'] as String,
        tapInTime: DateTime.parse(json['tap_in_time'] as String),
        tapInLat: (json['tap_in_lat'] as num?)?.toDouble() ?? 0.0,
        tapInLng: (json['tap_in_lng'] as num?)?.toDouble() ?? 0.0,
        isRemove: json['is_remove'] as bool? ?? false,
      );

  @override
  String toString() => 'PendingTransactionSync(aid: $aid, isRemove: $isRemove)';
}

/// Discovered host on the network
class DiscoveredHost {
  final String ip;
  final int port;
  final String deviceName;
  final DateTime discoveredAt;

  DiscoveredHost({
    required this.ip,
    required this.port,
    required this.deviceName,
    required this.discoveredAt,
  });

  Map<String, dynamic> toJson() => {
    'type': 'discovery',
    'ip': ip,
    'port': port,
    'device_name': deviceName,
  };

  factory DiscoveredHost.fromJson(Map<String, dynamic> json) => DiscoveredHost(
    ip: json['ip'] as String,
    port: json['port'] as int,
    deviceName: json['device_name'] as String? ?? 'Unknown Host',
    discoveredAt: DateTime.now(),
  );

  @override
  String toString() => 'DiscoveredHost($ip:$port, name: $deviceName)';
}

/// WiFi Sync Service - Handles both Server and Client roles
/// Uses raw TCP sockets for 100% offline local WiFi communication
/// This is a singleton - persists across screen navigation
class WifiSyncService {
  // Singleton pattern
  static final WifiSyncService _instance = WifiSyncService._internal();
  factory WifiSyncService() => _instance;
  WifiSyncService._internal();

  static const int defaultPort = 5050;
  static const int discoveryPort = 5051; // UDP discovery port
  static const String defaultHostIp = '192.168.43.1';
  static const String broadcastAddress = '255.255.255.255';

  SyncRole _currentRole = SyncRole.none;
  SyncRole get currentRole => _currentRole;

  // Server components
  ServerSocket? _serverSocket;
  final List<Socket> _connectedClients = [];

  // Client components
  Socket? _clientSocket;

  // Discovery components
  RawDatagramSocket? _discoverySocket;
  Timer? _discoveryBroadcastTimer;
  final StreamController<DiscoveredHost> _discoveredHostsController =
      StreamController<DiscoveredHost>.broadcast();
  Stream<DiscoveredHost> get onHostDiscovered =>
      _discoveredHostsController.stream;
  final Map<String, DiscoveredHost> _discoveredHosts = {};
  List<DiscoveredHost> get discoveredHosts => _discoveredHosts.values.toList();

  // State
  bool _isRunning = false;
  bool get isRunning => _isRunning;

  String? _hostIp;
  String? get hostIp => _hostIp;

  int get port => _port;
  int _port = defaultPort;

  // Callbacks
  final StreamController<ScanData> _scanDataController =
      StreamController<ScanData>.broadcast();
  Stream<ScanData> get onScanDataReceived => _scanDataController.stream;

  final StreamController<String> _statusController =
      StreamController<String>.broadcast();
  Stream<String> get onStatusChanged => _statusController.stream;

  final StreamController<int> _clientCountController =
      StreamController<int>.broadcast();
  Stream<int> get onClientCountChanged => _clientCountController.stream;

  // Pending transaction sync
  final StreamController<PendingTransactionSync> _pendingSyncController =
      StreamController<PendingTransactionSync>.broadcast();
  Stream<PendingTransactionSync> get onPendingSyncReceived =>
      _pendingSyncController.stream;

  /// Start as Host (Server) on the specified IP
  Future<bool> startAsHost({
    String ip = defaultHostIp,
    int port = defaultPort,
    String deviceName = 'TapAndGo Host',
  }) async {
    if (_isRunning) {
      await stop();
    }

    try {
      _port = port;
      _hostIp = ip;

      // Bind to all interfaces to accept connections
      _serverSocket = await ServerSocket.bind(
        InternetAddress.anyIPv4,
        port,
        shared: true,
      );

      _currentRole = SyncRole.host;
      _isRunning = true;

      if (!_statusController.isClosed) {
        _statusController.add('Host started on port $port');
      }
      debugPrint('🖥️ Server started on port $port');

      // Start heartbeat to keep connections alive
      _startHeartbeat();

      // Start broadcasting for auto-discovery
      _startDiscoveryBroadcast(deviceName);
      _serverSocket!.listen(
        _handleClientConnection,
        onError: (error) {
          debugPrint('❌ Server error: $error');
          if (!_statusController.isClosed) {
            _statusController.add('Server error: $error');
          }
        },
        onDone: () {
          debugPrint('🔌 Server socket closed');
        },
      );

      return true;
    } catch (e) {
      debugPrint('❌ Failed to start server: $e');
      if (!_statusController.isClosed) {
        _statusController.add('Failed to start server: $e');
      }
      return false;
    }
  }

  Timer? _heartbeatTimer;

  void _startHeartbeat() {
    _heartbeatTimer?.cancel();
    // Send heartbeat ping every 10 seconds to keep connections alive
    _heartbeatTimer = Timer.periodic(const Duration(seconds: 10), (_) {
      if (_connectedClients.isNotEmpty) {
        debugPrint(
          '💓 Sending heartbeat to ${_connectedClients.length} clients',
        );
        _broadcastToClients(
          '{"type":"heartbeat","timestamp":"${DateTime.now().toIso8601String()}"}',
        );
      }
    });
  }

  /// Start broadcasting host presence for discovery (called by Host)
  Future<void> _startDiscoveryBroadcast(String deviceName) async {
    try {
      _discoverySocket = await RawDatagramSocket.bind(
        InternetAddress.anyIPv4,
        0, // Use any available port for sending
      );
      _discoverySocket!.broadcastEnabled = true;

      debugPrint('📡 Starting discovery broadcast...');

      // Broadcast every 2 seconds
      _discoveryBroadcastTimer?.cancel();
      _discoveryBroadcastTimer = Timer.periodic(const Duration(seconds: 2), (
        _,
      ) {
        final message = jsonEncode({
          'type': 'discovery',
          'ip': _hostIp ?? 'unknown',
          'port': _port,
          'device_name': deviceName,
        });

        try {
          _discoverySocket?.send(
            utf8.encode(message),
            InternetAddress(broadcastAddress),
            discoveryPort,
          );
          debugPrint('📡 Broadcast sent: $message');
        } catch (e) {
          debugPrint('❌ Broadcast error: $e');
        }
      });
    } catch (e) {
      debugPrint('❌ Failed to start discovery broadcast: $e');
    }
  }

  /// Start listening for host discovery broadcasts (called by Client)
  Future<void> startDiscoveryListener() async {
    try {
      // Clear old discovered hosts
      _discoveredHosts.clear();

      _discoverySocket = await RawDatagramSocket.bind(
        InternetAddress.anyIPv4,
        discoveryPort,
        reuseAddress: true,
        reusePort: true,
      );

      debugPrint('👂 Listening for host broadcasts on port $discoveryPort...');
      if (!_statusController.isClosed) {
        _statusController.add('Searching for hosts...');
      }

      _discoverySocket!.listen((event) {
        if (event == RawSocketEvent.read) {
          final socket = _discoverySocket;
          if (socket == null) return;

          final datagram = socket.receive();
          if (datagram != null) {
            try {
              final message = utf8.decode(datagram.data);
              final json = jsonDecode(message) as Map<String, dynamic>;

              if (json['type'] == 'discovery') {
                // Use sender IP if not provided in message
                final ip = json['ip'] as String? ?? datagram.address.address;
                final host = DiscoveredHost(
                  ip: ip,
                  port: json['port'] as int? ?? defaultPort,
                  deviceName: json['device_name'] as String? ?? 'Unknown Host',
                  discoveredAt: DateTime.now(),
                );

                // Only add if new or update existing
                if (!_discoveredHosts.containsKey(ip)) {
                  debugPrint('🔍 Discovered host: $host');
                  _discoveredHosts[ip] = host;
                  if (!_discoveredHostsController.isClosed) {
                    _discoveredHostsController.add(host);
                  }
                  if (!_statusController.isClosed) {
                    _statusController.add(
                      'Found ${_discoveredHosts.length} host(s)',
                    );
                  }
                }
              }
            } catch (e) {
              debugPrint('❌ Discovery parse error: $e');
            }
          }
        }
      });
    } catch (e) {
      debugPrint('❌ Failed to start discovery listener: $e');
      if (!_statusController.isClosed) {
        _statusController.add('Failed to search for hosts: $e');
      }
    }
  }

  /// Stop discovery (both broadcast and listener)
  void stopDiscovery() {
    _discoveryBroadcastTimer?.cancel();
    _discoveryBroadcastTimer = null;
    _discoverySocket?.close();
    _discoverySocket = null;
    _discoveredHosts.clear();
    debugPrint('🔇 Discovery stopped');
  }

  void _handleClientConnection(Socket client) {
    final clientAddress =
        '${client.remoteAddress.address}:${client.remotePort}';
    debugPrint('📱 Client connected: $clientAddress');

    _connectedClients.add(client);
    _clientCountController.add(_connectedClients.length);
    _statusController.add(
      'Client connected: $clientAddress (${_connectedClients.length} total)',
    );

    // Listen for data from this client
    client.listen(
      (data) {
        try {
          final jsonStr = utf8.decode(data);
          // Handle multiple JSON objects if sent together
          for (final line
              in jsonStr.split('\n').where((l) => l.trim().isNotEmpty)) {
            final json = jsonDecode(line) as Map<String, dynamic>;

            // Check message type
            final messageType = json['type'] as String?;

            if (messageType == 'pending_sync') {
              // Handle pending transaction sync
              final pendingSync = PendingTransactionSync.fromJson(json);
              debugPrint(
                '📥 Received pending sync from $clientAddress: $pendingSync',
              );
              if (!_pendingSyncController.isClosed) {
                _pendingSyncController.add(pendingSync);
              }
              // Broadcast to all clients
              _broadcastToClients(line);
            } else {
              // Handle scan data
              final scanData = ScanData.fromJson(json);
              debugPrint('📥 Received from $clientAddress: $scanData');
              if (!_scanDataController.isClosed) {
                _scanDataController.add(scanData);
              }
              // Broadcast to all clients (including sender for confirmation)
              _broadcastToClients(line);
            }
          }
        } catch (e) {
          debugPrint('❌ Error parsing client data: $e');
        }
      },
      onError: (error) {
        debugPrint('❌ Client error ($clientAddress): $error');
        _removeClient(client);
      },
      onDone: () {
        debugPrint('📴 Client disconnected: $clientAddress');
        _removeClient(client);
      },
    );
  }

  void _removeClient(Socket client) {
    _connectedClients.remove(client);
    _clientCountController.add(_connectedClients.length);
    _statusController.add(
      'Client disconnected (${_connectedClients.length} remaining)',
    );
    try {
      client.close();
    } catch (_) {}
  }

  void _broadcastToClients(String message) {
    final data = utf8.encode('$message\n');
    for (final client in List.from(_connectedClients)) {
      try {
        client.add(data);
      } catch (e) {
        debugPrint('❌ Failed to send to client: $e');
        _removeClient(client);
      }
    }
  }

  /// Start as Client and connect to Host
  Future<bool> startAsClient({
    String hostIp = defaultHostIp,
    int port = defaultPort,
    Duration timeout = const Duration(seconds: 10),
    bool autoReconnect = true,
  }) async {
    if (_isRunning) {
      await stop();
    }

    _autoReconnect = autoReconnect;

    return _connectAsClient(hostIp: hostIp, port: port, timeout: timeout);
  }

  bool _autoReconnect = true;
  Timer? _reconnectTimer;

  Future<bool> _connectAsClient({
    required String hostIp,
    required int port,
    required Duration timeout,
  }) async {
    try {
      _port = port;
      _hostIp = hostIp;

      debugPrint('📡 Connecting to $hostIp:$port...');
      if (!_statusController.isClosed) {
        _statusController.add('Connecting to $hostIp:$port...');
      }

      _clientSocket = await Socket.connect(hostIp, port, timeout: timeout);

      _currentRole = SyncRole.client;
      _isRunning = true;

      if (!_statusController.isClosed) {
        _statusController.add('Connected to Host at $hostIp:$port');
      }
      debugPrint('✅ Connected to server at $hostIp:$port');

      // Listen for broadcasts from server
      _clientSocket!.listen(
        (data) {
          try {
            final jsonStr = utf8.decode(data);
            for (final line
                in jsonStr.split('\n').where((l) => l.trim().isNotEmpty)) {
              final json = jsonDecode(line) as Map<String, dynamic>;

              // Ignore heartbeat messages
              if (json['type'] == 'heartbeat') {
                debugPrint('💓 Heartbeat received from server');
                continue;
              }

              // Check message type
              final messageType = json['type'] as String?;

              if (messageType == 'pending_sync') {
                // Handle pending transaction sync from Host
                final pendingSync = PendingTransactionSync.fromJson(json);
                debugPrint('📥 Received pending sync broadcast: $pendingSync');
                if (!_pendingSyncController.isClosed) {
                  _pendingSyncController.add(pendingSync);
                }
              } else {
                // Handle scan data
                final scanData = ScanData.fromJson(json);
                debugPrint('📥 Received broadcast: $scanData');
                if (!_scanDataController.isClosed) {
                  _scanDataController.add(scanData);
                }
              }
            }
          } catch (e) {
            debugPrint('❌ Error parsing broadcast: $e');
          }
        },
        onError: (error) {
          debugPrint('❌ Connection error: $error');
          if (!_statusController.isClosed) {
            _statusController.add('Connection error: $error');
          }
          _handleDisconnect();
        },
        onDone: () {
          debugPrint('🔌 Disconnected from server');
          _handleDisconnect();
        },
      );

      return true;
    } catch (e) {
      debugPrint('❌ Failed to connect: $e');
      if (!_statusController.isClosed) {
        _statusController.add('Failed to connect: $e');
      }
      _handleDisconnect();
      return false;
    }
  }

  void _handleDisconnect() {
    _isRunning = false;
    _clientSocket = null;

    if (_autoReconnect && _hostIp != null && !_isDisposed) {
      debugPrint('🔄 Auto-reconnect in 3 seconds...');
      if (!_statusController.isClosed) {
        _statusController.add('Disconnected. Reconnecting in 3s...');
      }

      _reconnectTimer?.cancel();
      _reconnectTimer = Timer(const Duration(seconds: 3), () {
        if (!_isDisposed && _autoReconnect) {
          _connectAsClient(
            hostIp: _hostIp!,
            port: _port,
            timeout: const Duration(seconds: 10),
          );
        }
      });
    } else {
      _currentRole = SyncRole.none;
      if (!_statusController.isClosed) {
        _statusController.add('Disconnected from server');
      }
    }
  }

  /// Send scan data
  /// As Host: broadcasts to all clients and processes locally
  /// As Client: sends to Host which will broadcast back
  Future<bool> sendScanData(ScanData scanData) async {
    if (!_isRunning) {
      debugPrint('⚠️ Service not running');
      return false;
    }

    final message = jsonEncode(scanData.toJson());

    try {
      if (_currentRole == SyncRole.host) {
        // Host: Add locally and broadcast to all clients
        if (!_scanDataController.isClosed) {
          _scanDataController.add(scanData);
        }
        _broadcastToClients(message);
        debugPrint('📤 Host broadcasted: $scanData');
      } else if (_currentRole == SyncRole.client) {
        // Client: First add locally for immediate display
        if (!_scanDataController.isClosed) {
          _scanDataController.add(scanData);
        }
        // Then send to server (Host will broadcast back to all)
        _clientSocket?.write('$message\n');
        debugPrint('📤 Client sent: $scanData');
      }
      return true;
    } catch (e) {
      debugPrint('❌ Failed to send scan data: $e');
      return false;
    }
  }

  /// Send pending transaction sync
  /// Broadcasts pending transaction state to all connected devices
  Future<bool> sendPendingSync(PendingTransactionSync pendingSync) async {
    if (!_isRunning) {
      debugPrint('⚠️ Service not running');
      return false;
    }

    final message = jsonEncode(pendingSync.toJson());

    try {
      if (_currentRole == SyncRole.host) {
        // Host: Add locally and broadcast to all clients
        if (!_pendingSyncController.isClosed) {
          _pendingSyncController.add(pendingSync);
        }
        _broadcastToClients(message);
        debugPrint('📤 Host broadcasted pending: $pendingSync');
      } else if (_currentRole == SyncRole.client) {
        // Client: Add locally and send to server
        if (!_pendingSyncController.isClosed) {
          _pendingSyncController.add(pendingSync);
        }
        _clientSocket?.write('$message\n');
        debugPrint('📤 Client sent pending: $pendingSync');
      }
      return true;
    } catch (e) {
      debugPrint('❌ Failed to send pending sync: $e');
      return false;
    }
  }

  /// Stop the service
  Future<void> stop() async {
    if (!_isRunning && _reconnectTimer == null) return;

    debugPrint('🛑 Stopping WiFi Sync Service...');

    _isRunning = false;
    _autoReconnect = false; // Disable auto-reconnect when manually stopped
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    _heartbeatTimer?.cancel();
    _heartbeatTimer = null;
    stopDiscovery(); // Stop discovery broadcast/listener

    // Close server
    if (_serverSocket != null) {
      for (final client in List.from(_connectedClients)) {
        try {
          await client.close();
        } catch (_) {}
      }
      _connectedClients.clear();
      await _serverSocket?.close();
      _serverSocket = null;
    }

    // Close client connection
    if (_clientSocket != null) {
      await _clientSocket?.close();
      _clientSocket = null;
    }

    _currentRole = SyncRole.none;

    // Only add events if controllers are not closed
    if (!_clientCountController.isClosed) {
      _clientCountController.add(0);
    }
    if (!_statusController.isClosed) {
      _statusController.add('Service stopped');
    }
    debugPrint('✅ Service stopped');
  }

  bool _isDisposed = false;

  /// Dispose resources
  Future<void> dispose() async {
    if (_isDisposed) return;
    _isDisposed = true;

    await stop();

    if (!_scanDataController.isClosed) {
      await _scanDataController.close();
    }
    if (!_statusController.isClosed) {
      await _statusController.close();
    }
    if (!_clientCountController.isClosed) {
      await _clientCountController.close();
    }
  }
}
