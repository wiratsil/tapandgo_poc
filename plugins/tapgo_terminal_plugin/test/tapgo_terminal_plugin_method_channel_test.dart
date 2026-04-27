import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tapgo_terminal_plugin/tapgo_terminal_plugin_method_channel.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final platform = MethodChannelTapgoTerminalPlugin();
  const channel = MethodChannel('tapgo_terminal_plugin/methods');

  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (MethodCall methodCall) async {
          if (methodCall.method == 'getDeviceId') {
            return 'device-42';
          }
          return <String, dynamic>{};
        });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('getDeviceId', () async {
    expect(await platform.getDeviceId(), 'device-42');
  });
}
