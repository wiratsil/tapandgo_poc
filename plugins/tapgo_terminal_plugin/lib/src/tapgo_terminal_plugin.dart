import '../tapgo_terminal_plugin_platform_interface.dart';
import 'models/terminal_capabilities.dart';
import 'models/terminal_command_result.dart';
import 'models/terminal_event.dart';
import 'models/terminal_platform_info.dart';
import 'models/terminal_system_status.dart';

class TapgoTerminalPlugin {
  TapgoTerminalPlugin._();

  static final TapgoTerminalPlugin instance = TapgoTerminalPlugin._();

  Stream<TerminalEvent> get events =>
      TapgoTerminalPluginPlatform.instance.events;

  Future<TerminalCommandResult> initialize() {
    return TapgoTerminalPluginPlatform.instance.initialize();
  }

  Future<String> getDeviceId() {
    return TapgoTerminalPluginPlatform.instance.getDeviceId();
  }

  Future<TerminalPlatformInfo> getPlatformInfo() {
    return TapgoTerminalPluginPlatform.instance.getPlatformInfo();
  }

  Future<TerminalCapabilities> getCapabilities() {
    return TapgoTerminalPluginPlatform.instance.getCapabilities();
  }

  Future<TerminalSystemStatus> getSystemStatus() {
    return TapgoTerminalPluginPlatform.instance.getSystemStatus();
  }

  Future<TerminalCommandResult> startNfc({bool simulate = false}) {
    return TapgoTerminalPluginPlatform.instance.startNfc(simulate: simulate);
  }

  Future<TerminalCommandResult> stopNfc() {
    return TapgoTerminalPluginPlatform.instance.stopNfc();
  }

  Future<TerminalCommandResult> startQr() {
    return TapgoTerminalPluginPlatform.instance.startQr();
  }

  Future<TerminalCommandResult> stopQr() {
    return TapgoTerminalPluginPlatform.instance.stopQr();
  }

  Future<TerminalCommandResult> showGreenLed({int holdMs = 2000}) {
    return TapgoTerminalPluginPlatform.instance.showGreenLed(holdMs: holdMs);
  }

  Future<TerminalCommandResult> showYellowLed({int holdMs = 2000}) {
    return TapgoTerminalPluginPlatform.instance.showYellowLed(holdMs: holdMs);
  }

  Future<TerminalCommandResult> showRedLed({int holdMs = 2000}) {
    return TapgoTerminalPluginPlatform.instance.showRedLed(holdMs: holdMs);
  }

  Future<TerminalCommandResult> playBuzzer({int durationMs = 120}) {
    return TapgoTerminalPluginPlatform.instance.playBuzzer(
      durationMs: durationMs,
    );
  }
}
