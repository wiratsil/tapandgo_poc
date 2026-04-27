import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'src/models/terminal_capabilities.dart';
import 'src/models/terminal_command_result.dart';
import 'src/models/terminal_event.dart';
import 'src/models/terminal_platform_info.dart';
import 'src/models/terminal_system_status.dart';
import 'tapgo_terminal_plugin_platform_interface.dart';

class MethodChannelTapgoTerminalPlugin extends TapgoTerminalPluginPlatform {
  @visibleForTesting
  final MethodChannel methodChannel = const MethodChannel(
    'tapgo_terminal_plugin/methods',
  );

  @visibleForTesting
  final EventChannel eventChannel = const EventChannel(
    'tapgo_terminal_plugin/events',
  );

  Stream<TerminalEvent>? _events;

  @override
  Stream<TerminalEvent> get events {
    return _events ??= eventChannel.receiveBroadcastStream().map((
      dynamic event,
    ) {
      final map = Map<String, dynamic>.from(event as Map);
      return TerminalEvent.fromMap(map);
    });
  }

  @override
  Future<TerminalCommandResult> initialize() async {
    final map = await _invokeMap('initialize');
    return TerminalCommandResult.fromMap(map);
  }

  @override
  Future<String> getDeviceId() async {
    final value = await methodChannel.invokeMethod<String>('getDeviceId');
    return value ?? '';
  }

  @override
  Future<TerminalPlatformInfo> getPlatformInfo() async {
    final map = await _invokeMap('getPlatformInfo');
    return TerminalPlatformInfo.fromMap(map);
  }

  @override
  Future<TerminalCapabilities> getCapabilities() async {
    final map = await _invokeMap('getCapabilities');
    return TerminalCapabilities.fromMap(map);
  }

  @override
  Future<TerminalSystemStatus> getSystemStatus() async {
    final map = await _invokeMap('getSystemStatus');
    return TerminalSystemStatus.fromMap(map);
  }

  @override
  Future<TerminalCommandResult> startNfc({bool simulate = false}) async {
    final map = await _invokeMap('startNfc', {'simulate': simulate});
    return TerminalCommandResult.fromMap(map);
  }

  @override
  Future<TerminalCommandResult> stopNfc() async {
    final map = await _invokeMap('stopNfc');
    return TerminalCommandResult.fromMap(map);
  }

  @override
  Future<TerminalCommandResult> startQr() async {
    final map = await _invokeMap('startQr');
    return TerminalCommandResult.fromMap(map);
  }

  @override
  Future<TerminalCommandResult> stopQr() async {
    final map = await _invokeMap('stopQr');
    return TerminalCommandResult.fromMap(map);
  }

  @override
  Future<TerminalCommandResult> showGreenLed({int holdMs = 2000}) async {
    final map = await _invokeMap('showGreenLed', {'holdMs': holdMs});
    return TerminalCommandResult.fromMap(map);
  }

  @override
  Future<TerminalCommandResult> showYellowLed({int holdMs = 2000}) async {
    final map = await _invokeMap('showYellowLed', {'holdMs': holdMs});
    return TerminalCommandResult.fromMap(map);
  }

  @override
  Future<TerminalCommandResult> showRedLed({int holdMs = 2000}) async {
    final map = await _invokeMap('showRedLed', {'holdMs': holdMs});
    return TerminalCommandResult.fromMap(map);
  }

  @override
  Future<TerminalCommandResult> playBuzzer({int durationMs = 120}) async {
    final map = await _invokeMap('playBuzzer', {'durationMs': durationMs});
    return TerminalCommandResult.fromMap(map);
  }

  Future<Map<String, dynamic>> _invokeMap(
    String method, [
    Map<String, dynamic>? arguments,
  ]) async {
    final raw = await methodChannel.invokeMapMethod<dynamic, dynamic>(
      method,
      arguments,
    );
    return Map<String, dynamic>.from(raw ?? const <String, dynamic>{});
  }
}
