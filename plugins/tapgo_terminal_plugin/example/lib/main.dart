import 'package:flutter/material.dart';
import 'package:tapgo_terminal_plugin/tapgo_terminal_plugin.dart';

void main() {
  runApp(const MyApp());
}

class MyApp extends StatefulWidget {
  const MyApp({super.key});

  @override
  State<MyApp> createState() => _MyAppState();
}

class _MyAppState extends State<MyApp> {
  final terminal = TapgoTerminalPlugin.instance;
  final scaffoldMessengerKey = GlobalKey<ScaffoldMessengerState>();

  String deviceId = 'Unknown';
  String platform = 'Unknown';
  String model = 'Unknown';
  String capabilities = 'Loading...';
  String systemStatus = 'Loading...';
  String readerDetail = 'Loading...';
  String readerContext = 'Loading...';
  String lastQr = '-';
  String lastCard = '-';
  final List<String> events = <String>[];

  @override
  void initState() {
    super.initState();
    terminal.events.listen((event) {
      if (!mounted) {
        return;
      }
      setState(() {
        if (event.type == 'qrScanned') {
          lastQr = event.payload['code']?.toString() ?? '-';
        }
        if (event.type == 'nfcResult') {
          final pan = event.payload['pan']?.toString() ?? '-';
          final exp = event.payload['expiry']?.toString() ?? '-';
          final label = event.payload['label']?.toString() ?? '-';
          lastCard = 'PAN=$pan EXP=$exp LABEL=$label';
        }
        final payloadText = event.payload.isEmpty ? '' : ' ${event.payload}';
        events.insert(0, '${event.type}: ${event.message ?? '-'}$payloadText');
        if (events.length > 12) {
          events.removeLast();
        }
      });
    });
    _load();
  }

  Future<void> _load() async {
    await terminal.initialize();
    final fetchedDeviceId = await terminal.getDeviceId();
    final info = await terminal.getPlatformInfo();
    final caps = await terminal.getCapabilities();
    final status = await terminal.getSystemStatus();

    if (!mounted) {
      return;
    }

    setState(() {
      deviceId = fetchedDeviceId;
      platform = '${info.platform} ${info.androidVersion}';
      model = '${info.manufacturer} ${info.model}';
      capabilities =
          'NFC=${caps.hasNfcFeature}, BT=${caps.hasBluetoothFeature}, '
          'WFD=${caps.hasWifiDirectFeature}, ReaderSvc=${caps.vendorReaderServiceInstalled}';
      systemStatus =
          'GPS=${status.gps}, Reader=${status.reader}, QR=${status.qr}, '
          'Network=${status.network}, BT=${status.bluetooth}';
      readerDetail = status.readerDetail;
      readerContext = status.readerContext;
    });
  }

  Future<void> _runPendingCommand(
    Future<TerminalCommandResult> Function() action,
  ) async {
    final result = await action();
    if (!mounted) {
      return;
    }
    final snackBar = SnackBar(content: Text(result.message ?? 'No message'));
    scaffoldMessengerKey.currentState?.showSnackBar(snackBar);
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      scaffoldMessengerKey: scaffoldMessengerKey,
      home: Scaffold(
        appBar: AppBar(title: const Text('TapGo Terminal Plugin')),
        body: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text('Device ID: $deviceId'),
              Text('Platform: $platform'),
              Text('Model: $model'),
              Text('Capabilities: $capabilities'),
              Text('System: $systemStatus'),
              Text('Reader Detail: $readerDetail'),
              Text('Reader Context: $readerContext'),
              Text('Last QR: $lastQr'),
              Text('Last Card: $lastCard'),
              const SizedBox(height: 16),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: <Widget>[
                  ElevatedButton(
                    onPressed: () {
                      _runPendingCommand(() => terminal.startNfc());
                    },
                    child: const Text('Start NFC'),
                  ),
                  ElevatedButton(
                    onPressed: () {
                      _runPendingCommand(() => terminal.stopNfc());
                    },
                    child: const Text('Stop NFC'),
                  ),
                  ElevatedButton(
                    onPressed: () {
                      _runPendingCommand(() => terminal.startQr());
                    },
                    child: const Text('Start QR'),
                  ),
                  ElevatedButton(
                    onPressed: () {
                      _runPendingCommand(() => terminal.stopQr());
                    },
                    child: const Text('Stop QR'),
                  ),
                  ElevatedButton(
                    onPressed: () {
                      _runPendingCommand(() => terminal.playBuzzer());
                    },
                    child: const Text('Play Buzzer'),
                  ),
                  ElevatedButton(
                    onPressed: () {
                      _runPendingCommand(() => terminal.showGreenLed());
                    },
                    child: const Text('Green LED'),
                  ),
                  ElevatedButton(
                    onPressed: _load,
                    child: const Text('Refresh Status'),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              const Text('Events'),
              const SizedBox(height: 8),
              Expanded(
                child: ListView.builder(
                  itemCount: events.length,
                  itemBuilder: (context, index) {
                    return Text(events[index]);
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
