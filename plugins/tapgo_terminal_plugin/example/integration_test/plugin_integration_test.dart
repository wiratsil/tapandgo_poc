// This is a basic Flutter integration test.
//
// Since integration tests run in a full Flutter application, they can interact
// with the host side of a plugin implementation, unlike Dart unit tests.
//
// For more information about Flutter integration tests, please see
// https://flutter.dev/to/integration-testing
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:tapgo_terminal_plugin/tapgo_terminal_plugin.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('plugin exposes a non-empty device id', (
    WidgetTester tester,
  ) async {
    final plugin = TapgoTerminalPlugin.instance;
    await plugin.initialize();
    final deviceId = await plugin.getDeviceId();
    expect(deviceId.isNotEmpty, true);
  });
}
