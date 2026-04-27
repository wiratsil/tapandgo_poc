import 'package:plugin_platform_interface/plugin_platform_interface.dart';

import 'src/models/terminal_capabilities.dart';
import 'src/models/terminal_command_result.dart';
import 'src/models/terminal_event.dart';
import 'src/models/terminal_platform_info.dart';
import 'src/models/terminal_system_status.dart';
import 'tapgo_terminal_plugin_method_channel.dart';

abstract class TapgoTerminalPluginPlatform extends PlatformInterface {
  TapgoTerminalPluginPlatform() : super(token: _token);

  static final Object _token = Object();

  static TapgoTerminalPluginPlatform _instance =
      MethodChannelTapgoTerminalPlugin();

  static TapgoTerminalPluginPlatform get instance => _instance;

  static set instance(TapgoTerminalPluginPlatform instance) {
    PlatformInterface.verifyToken(instance, _token);
    _instance = instance;
  }

  Stream<TerminalEvent> get events {
    throw UnimplementedError('events has not been implemented.');
  }

  Future<TerminalCommandResult> initialize() {
    throw UnimplementedError('initialize() has not been implemented.');
  }

  Future<String> getDeviceId() {
    throw UnimplementedError('getDeviceId() has not been implemented.');
  }

  Future<TerminalPlatformInfo> getPlatformInfo() {
    throw UnimplementedError('getPlatformInfo() has not been implemented.');
  }

  Future<TerminalCapabilities> getCapabilities() {
    throw UnimplementedError('getCapabilities() has not been implemented.');
  }

  Future<TerminalSystemStatus> getSystemStatus() {
    throw UnimplementedError('getSystemStatus() has not been implemented.');
  }

  Future<TerminalCommandResult> startNfc({bool simulate = false}) {
    throw UnimplementedError('startNfc() has not been implemented.');
  }

  Future<TerminalCommandResult> stopNfc() {
    throw UnimplementedError('stopNfc() has not been implemented.');
  }

  Future<TerminalCommandResult> startQr() {
    throw UnimplementedError('startQr() has not been implemented.');
  }

  Future<TerminalCommandResult> stopQr() {
    throw UnimplementedError('stopQr() has not been implemented.');
  }

  Future<TerminalCommandResult> showGreenLed({int holdMs = 2000}) {
    throw UnimplementedError('showGreenLed() has not been implemented.');
  }

  Future<TerminalCommandResult> showYellowLed({int holdMs = 2000}) {
    throw UnimplementedError('showYellowLed() has not been implemented.');
  }

  Future<TerminalCommandResult> showRedLed({int holdMs = 2000}) {
    throw UnimplementedError('showRedLed() has not been implemented.');
  }

  Future<TerminalCommandResult> playBuzzer({int durationMs = 120}) {
    throw UnimplementedError('playBuzzer() has not been implemented.');
  }
}
