import 'package:flutter_test/flutter_test.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:tapgo_terminal_plugin/tapgo_terminal_plugin.dart';
import 'package:tapgo_terminal_plugin/tapgo_terminal_plugin_method_channel.dart';
import 'package:tapgo_terminal_plugin/tapgo_terminal_plugin_platform_interface.dart';

class MockTapgoTerminalPluginPlatform
    with MockPlatformInterfaceMixin
    implements TapgoTerminalPluginPlatform {
  @override
  Stream<TerminalEvent> get events => const Stream<TerminalEvent>.empty();

  @override
  Future<TerminalCommandResult> initialize() async {
    return const TerminalCommandResult(
      success: true,
      implemented: true,
      message: 'ok',
    );
  }

  @override
  Future<String> getDeviceId() async => 'device-123';

  @override
  Future<TerminalPlatformInfo> getPlatformInfo() async {
    return const TerminalPlatformInfo(
      platform: 'android',
      androidVersion: '14',
      sdkInt: 34,
      manufacturer: 'TapGo',
      brand: 'TapGo',
      model: 'T1',
      device: 't1',
      hardware: 'terminal',
    );
  }

  @override
  Future<TerminalCapabilities> getCapabilities() async {
    return const TerminalCapabilities(
      isAndroid: true,
      hasNfcFeature: true,
      hasBluetoothFeature: true,
      hasWifiDirectFeature: false,
      hasCameraFeature: true,
      hasGpsFeature: true,
      vendorReaderServiceInstalled: true,
      vendorReaderSdkBundled: true,
      vendorUtilitySdkBundled: true,
      zxingBundled: true,
    );
  }

  @override
  Future<TerminalSystemStatus> getSystemStatus() async {
    return const TerminalSystemStatus(
      gps: 'ONLINE',
      reader: 'READY',
      readerDetail: 'Reader service connected.',
      readerContext: 'android.app.Activity',
      qr: 'READY',
      network: 'ONLINE',
      bluetooth: 'ENABLED',
    );
  }

  @override
  Future<TerminalCommandResult> playBuzzer({int durationMs = 120}) async {
    return const TerminalCommandResult(success: false, implemented: false);
  }

  @override
  Future<TerminalCommandResult> showGreenLed({int holdMs = 2000}) async {
    return const TerminalCommandResult(success: false, implemented: false);
  }

  @override
  Future<TerminalCommandResult> showRedLed({int holdMs = 2000}) async {
    return const TerminalCommandResult(success: false, implemented: false);
  }

  @override
  Future<TerminalCommandResult> showYellowLed({int holdMs = 2000}) async {
    return const TerminalCommandResult(success: false, implemented: false);
  }

  @override
  Future<TerminalCommandResult> startNfc({bool simulate = false}) async {
    return const TerminalCommandResult(success: false, implemented: false);
  }

  @override
  Future<TerminalCommandResult> startQr() async {
    return const TerminalCommandResult(success: false, implemented: false);
  }

  @override
  Future<TerminalCommandResult> stopNfc() async {
    return const TerminalCommandResult(success: false, implemented: false);
  }

  @override
  Future<TerminalCommandResult> stopQr() async {
    return const TerminalCommandResult(success: false, implemented: false);
  }
}

void main() {
  final TapgoTerminalPluginPlatform initialPlatform =
      TapgoTerminalPluginPlatform.instance;

  test('$MethodChannelTapgoTerminalPlugin is the default instance', () {
    expect(initialPlatform, isInstanceOf<MethodChannelTapgoTerminalPlugin>());
  });

  test('getDeviceId delegates to the platform implementation', () async {
    TapgoTerminalPluginPlatform.instance = MockTapgoTerminalPluginPlatform();

    expect(await TapgoTerminalPlugin.instance.getDeviceId(), 'device-123');
  });
}
