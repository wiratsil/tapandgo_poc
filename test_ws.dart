import 'package:mqtt_client/mqtt_server_client.dart';

void main() {
  final client = MqttServerClient.withPort('test', '123', 443);
  print(client.useWebSocket);
  print(client.port);
}
