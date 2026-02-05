import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:nearby_connections/nearby_connections.dart';
import 'package:permission_handler/permission_handler.dart';

class NearbyService {
  static final NearbyService _instance = NearbyService._internal();
  factory NearbyService() => _instance;
  NearbyService._internal();

  final Nearby _nearby = Nearby();
  String? _userName;
  final Strategy _strategy =
      Strategy.P2P_CLUSTER; // More flexible than P2P_STAR

  // State
  bool isAdvertising = false;
  bool isDiscovering = false;
  final Set<String> _connectedEndpoints = {};

  // Callbacks
  Function(String data)? onDataReceived;
  Function(String status)? onStatusChanged;

  Future<bool> checkPermissions() async {
    // Android 12+ needs Bluetooth Scan/Connect/Advertise
    // Android <12 needs Location

    Map<Permission, PermissionStatus> statuses = await [
      Permission.location,
      Permission.bluetooth,
      Permission.bluetoothAdvertise,
      Permission.bluetoothConnect,
      Permission.bluetoothScan,
      Permission.nearbyWifiDevices,
    ].request();

    // Simple check: are critical permissions granted?
    final loc = statuses[Permission.location];
    final btConnect = statuses[Permission.bluetoothConnect];

    // You might want more granular checks here
    if (loc == PermissionStatus.granted ||
        btConnect == PermissionStatus.granted) {
      return true;
    }
    return false;
  }

  // STOP Everything
  Future<void> stopAll() async {
    await _nearby.stopAdvertising();
    await _nearby.stopDiscovery();
    await _nearby.stopAllEndpoints();
    isAdvertising = false;
    isDiscovering = false;
    _connectedEndpoints.clear();
  }

  // DRIVER MODE: Advertise
  Future<void> startAdvertising(String plateNo) async {
    await stopAll(); // Ensure clean state
    _userName = 'TNG-BUS-$plateNo';
    try {
      await _nearby.startAdvertising(
        _userName!,
        _strategy,
        serviceId: 'com.wiratsil.tapandgo', // Explicit Service ID
        onConnectionInitiated: _onConnectionInitiated,
        onConnectionResult: (id, status) {
          debugPrint('Connection: $id, Status: $status');
          if (status == Status.CONNECTED) {
            _connectedEndpoints.add(id);
            onStatusChanged?.call('Connected (${_connectedEndpoints.length})');
          }
        },
        onDisconnected: (id) {
          _connectedEndpoints.remove(id);
          onStatusChanged?.call('Connected (${_connectedEndpoints.length})');
        },
      );
      isAdvertising = true;
      debugPrint('Advertising as $_userName');
    } catch (e) {
      debugPrint('Advertise Error: $e');
      onStatusChanged?.call('Error: $e');
    }
  }

  // PASSENGER MODE: Discover
  Future<void> startDiscovery(String targetPlateNo) async {
    await stopAll(); // Ensure clean state
    final targetName = 'TNG-BUS-$targetPlateNo';
    try {
      await _nearby.startDiscovery(
        _userName ?? 'PASSENGER',
        _strategy,
        serviceId: 'com.wiratsil.tapandgo', // Explicit Service ID
        onEndpointFound: (id, name, serviceId) {
          debugPrint('Found: $name ($serviceId)');
          if (serviceId == 'com.wiratsil.tapandgo' && name == targetName) {
            _nearby.requestConnection(
              _userName ?? 'PASSENGER',
              id,
              onConnectionInitiated: _onConnectionInitiated,
              onConnectionResult: (id, status) {
                if (status == Status.CONNECTED) {
                  _connectedEndpoints.add(id);
                  onStatusChanged?.call('Connected to Bus');
                  _nearby.stopDiscovery(); // Stop searching once connected
                }
              },
              onDisconnected: (id) {
                _connectedEndpoints.remove(id);
                onStatusChanged?.call('Disconnected');
                // Restart discovery?
              },
            );
          }
        },
        onEndpointLost: (id) => debugPrint('Lost: $id'),
      );
      isDiscovering = true;
      debugPrint('Discovering for $targetName');
    } catch (e) {
      debugPrint('Discovery Error: $e');
      onStatusChanged?.call('Error: $e');
    }
  }

  // Auto-Accept Connection
  void _onConnectionInitiated(String id, ConnectionInfo info) {
    // For POC, auto-accept everything
    _nearby.acceptConnection(
      id,
      onPayLoadRecieved: (endId, payload) {
        if (payload.type == PayloadType.BYTES) {
          final str = String.fromCharCodes(payload.bytes!);
          onDataReceived?.call(str);
        }
      },
    );
  }

  // Send Data
  Future<void> sendData(Map<String, dynamic> data) async {
    if (_connectedEndpoints.isEmpty) return;
    final jsonStr = jsonEncode(data);

    // Broadcast to ALL connected endpoints
    for (final id in _connectedEndpoints) {
      await _nearby.sendBytesPayload(id, Uint8List.fromList(jsonStr.codeUnits));
    }
  }
}
