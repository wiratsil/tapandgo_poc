import 'package:flutter_test/flutter_test.dart';
import 'package:tapandgo_poc/services/mqtt_service.dart';

void main() {
  test('MQTT Service connect and disconnect', () async {
    final service = MqttService();
    // Use a mock plate number
    final plateNo = '12-3456';

    // Subscribe to test topic
    bool connected = await service.connect(plateNo);
    expect(connected, isTrue);

    // Wait for a few seconds to allow messages
    await Future.delayed(const Duration(seconds: 5));

    service.disconnect();
  });
}
