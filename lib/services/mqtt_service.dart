import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:mqtt_client/mqtt_client.dart';
import 'package:mqtt_client/mqtt_server_client.dart';
import '../models/gps_data_model.dart';
import '../models/bus_trip_mqtt_model.dart';
import 'data_sync_service.dart';
import 'dart:math';

class MqttService {
  late MqttServerClient client;
  final String server = 'wss://tng-platform-dev.atlasicloud.com/mqtt';
  final int port = 443;
  final String username = 'tngemq';
  final String password = 'b6KMpX2ucf6P8NNY';

  // Stream controller to broadcast GPS data
  final StreamController<GpsData> _gpsDataController =
      StreamController<GpsData>.broadcast();
  Stream<GpsData> get gpsStream => _gpsDataController.stream;

  // Stream controller to broadcast Bus Trip data (Optional, currently directly triggers sync)
  final StreamController<BusTripMqttData> _busTripController =
      StreamController<BusTripMqttData>.broadcast();
  Stream<BusTripMqttData> get busTripStream => _busTripController.stream;

  String? _currentPlateNo;
  StreamSubscription? _updatesSubscription;

  MqttService() {
    _initializeClient();
  }

  void _initializeClient() {
    final clientId = 'tapandgo_poc_${Random().nextInt(100000)}';
    client = MqttServerClient.withPort(server, clientId, port);
    client.setProtocolV311();

    client.useWebSocket = true;
    // client.secure = true; // Must be false to use wss:// with useWebSocket=true
    client.logging(on: true);
    client.keepAlivePeriod = 60;
    client.onDisconnected = onDisconnected;
    client.onConnected = onConnected;
    client.onSubscribed = onSubscribed;
    client.pongCallback = pong;

    // Setting up web socket protocols if needed, usually 'mqtt'
    // This is often needed for mosquitto and emqx over websockets
    client.websocketProtocols = MqttClientConstants.protocolsSingleDefault;

    // Setup connection message
    final connMess = MqttConnectMessage()
        .withClientIdentifier(clientId)
        .authenticateAs(username, password);

    client.connectionMessage = connMess;
  }

  Future<bool> connect(String plateNo) async {
    if (client.connectionStatus?.state == MqttConnectionState.connected &&
        _currentPlateNo == plateNo) {
      debugPrint('[MQTT] Already connected and subscribed to $plateNo');
      return true;
    }

    if (client.connectionStatus?.state == MqttConnectionState.connected ||
        client.connectionStatus?.state == MqttConnectionState.connecting) {
      debugPrint(
        '[MQTT] Disconnecting previous connection for: $_currentPlateNo',
      );
      client.disconnect();
    }

    _currentPlateNo = plateNo;

    try {
      debugPrint('[MQTT] Connecting to $server...');
      await client.connect();
    } on NoConnectionException catch (e) {
      debugPrint('[MQTT] NoConnectionException: $e');
      client.disconnect();
      return false;
    } on SocketException catch (e) {
      debugPrint('[MQTT] SocketException: $e');
      client.disconnect();
      return false;
    } catch (e) {
      debugPrint('[MQTT] Error: $e');
      client.disconnect();
      return false;
    }

    if (client.connectionStatus!.state == MqttConnectionState.connected) {
      debugPrint('[MQTT] ✅ เชื่อมต่อ MQTT สำเร็จ (Connected successfully)');

      if (_currentPlateNo != null && _currentPlateNo!.isNotEmpty) {
        // Subscribe to the GPS topic
        final gpsTopic = '/gps/$_currentPlateNo';
        debugPrint('[MQTT] Subscribing to $gpsTopic');
        client.subscribe(gpsTopic, MqttQos.atLeastOnce);

        // Subscribe to the Trip topic
        final tripTopic = '/trip/$_currentPlateNo';
        debugPrint('[MQTT] Subscribing to $tripTopic');
        client.subscribe(tripTopic, MqttQos.atLeastOnce);
      } else {
        debugPrint(
          '[MQTT] No plate number provided. Connected but not subscribing to GPS topic.',
        );
      }

      _updatesSubscription?.cancel();
      _updatesSubscription = client.updates!.listen((
        List<MqttReceivedMessage<MqttMessage?>>? c,
      ) {
        if (c == null || c.isEmpty) return;

        final recMess = c[0].payload as MqttPublishMessage;
        final payload = MqttPublishPayload.bytesToStringAsString(
          recMess.payload.message,
        );

        try {
          final Map<String, dynamic> data = jsonDecode(payload);

          if (c[0].topic.contains('/trip/')) {
            final tripData = BusTripMqttData.fromJson(data);
            debugPrint(
              '[MQTT] Received TRIP message on topic: <${c[0].topic}>, parsed: ${tripData.toJson()}',
            );

            _busTripController.add(tripData);

            // Trigger DataSyncService if ActualDateTimeToDestination (td) is null
            // which implies a new trip started. Wait! The prompt says "if data NO ActualDateTimeToDestination comes with it" -> meaning td == null.
            if (tripData.td == null) {
              debugPrint(
                '[MQTT] 🔄 New Trip started Activity (td is null). Triggering Data Sync...',
              );
              final syncService = DataSyncService();
              syncService.syncAllData(plateNo: _currentPlateNo ?? '');
            }
          } else {
            // Assume GPS payload
            final gpsData = GpsData.fromJson(data);
            debugPrint(
              '[MQTT] Received GPS message on topic: <${c[0].topic}>, parsed: ${gpsData.toJson()}',
            );
            _gpsDataController.add(gpsData);
          }
        } catch (e) {
          debugPrint('[MQTT] Error parsing payload "$payload": $e');
        }
      });
      return true;
    } else {
      debugPrint(
        '[MQTT] ❌ เชื่อมต่อ MQTT ไม่สำเร็จ (Connection failed). State is: ${client.connectionStatus!.state}',
      );
      client.disconnect();
      return false;
    }
  }

  void disconnect() {
    debugPrint('[MQTT] Disconnecting client');
    _updatesSubscription?.cancel();
    client.disconnect();
  }

  void onConnected() {
    debugPrint('[MQTT] Connected callback invoked');
  }

  void onDisconnected() {
    debugPrint('[MQTT] Disconnected callback invoked');
    // Implement auto-reconnect if desired
    debugPrint('[MQTT] Attempting to reconnect in 5 seconds...');
    Future.delayed(const Duration(seconds: 5), () {
      connect(_currentPlateNo ?? '');
    });
  }

  void onSubscribed(String topic) {
    debugPrint('[MQTT] Successfully subscribed to topic: $topic');
  }

  void pong() {
    debugPrint('[MQTT] Ping response received');
  }
}
