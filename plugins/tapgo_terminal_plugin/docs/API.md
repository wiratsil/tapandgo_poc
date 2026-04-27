# API Reference

เอกสารนี้สรุป public API ของ `tapgo_terminal_plugin` ตามสถานะปัจจุบันของโค้ด

## Main entry point

ใช้งานผ่าน singleton:

```dart
final terminal = TapgoTerminalPlugin.instance;
```

## Methods

### initialize

```dart
Future<TerminalCommandResult> initialize()
```

ใช้สำหรับเตรียม plugin ฝั่ง Flutter และเริ่ม event stream ฝั่ง native

หมายเหตุ:

- ปัจจุบัน `initialize()` ไม่ register reader service ทันทีแล้ว
- การแตะ reader จะเกิดตอนเรียก `startNfc()` เป็นหลัก เพื่อลด crash ตอนเปิดแอป

### getDeviceId

```dart
Future<String> getDeviceId()
```

คืนค่า Android device ID

### getPlatformInfo

```dart
Future<TerminalPlatformInfo> getPlatformInfo()
```

คืนข้อมูล platform เช่น:

- `platform`
- `androidVersion`
- `sdkInt`
- `manufacturer`
- `brand`
- `model`
- `device`
- `hardware`

### getCapabilities

```dart
Future<TerminalCapabilities> getCapabilities()
```

คืนค่าความสามารถของเครื่องและ plugin เช่น:

- `isAndroid`
- `hasNfcFeature`
- `hasBluetoothFeature`
- `hasWifiDirectFeature`
- `hasCameraFeature`
- `hasGpsFeature`
- `vendorReaderServiceInstalled`
- `vendorReaderSdkBundled`
- `vendorUtilitySdkBundled`
- `zxingBundled`

### getSystemStatus

```dart
Future<TerminalSystemStatus> getSystemStatus()
```

คืนสถานะล่าสุดของ subsystem หลัก:

- `gps`
- `reader`
- `readerDetail`
- `readerContext`
- `qr`
- `network`
- `bluetooth`

ตัวอย่างสถานะ reader:

- `IDLE`
- `SERVICE_MISSING`
- `REGISTERING`
- `REGISTERED_WAITING_CALLBACK`
- `REGISTER_FAILED`
- `READY`

### startNfc

```dart
Future<TerminalCommandResult> startNfc({bool simulate = false})
```

เริ่ม flow ของ NFC reader

หมายเหตุ:

- เมื่อ `simulate=true` ใช้สำหรับ flow ทดสอบโดยไม่พึ่ง hardware จริงในบางกรณี
- เมื่อ `simulate=false` จะพยายาม register reader service และเปิด NFC flow จริง

### stopNfc

```dart
Future<TerminalCommandResult> stopNfc()
```

หยุด NFC session ปัจจุบัน

### startQr

```dart
Future<TerminalCommandResult> startQr()
```

เปิด QR hardware scanner

### stopQr

```dart
Future<TerminalCommandResult> stopQr()
```

หยุด QR hardware scanner

### showGreenLed

```dart
Future<TerminalCommandResult> showGreenLed({int holdMs = 2000})
```

### showYellowLed

```dart
Future<TerminalCommandResult> showYellowLed({int holdMs = 2000})
```

### showRedLed

```dart
Future<TerminalCommandResult> showRedLed({int holdMs = 2000})
```

ใช้ควบคุมไฟ LED ของอุปกรณ์

### playBuzzer

```dart
Future<TerminalCommandResult> playBuzzer({int durationMs = 120})
```

ใช้สั่ง buzzer ของอุปกรณ์

## Return models

### TerminalCommandResult

```dart
class TerminalCommandResult {
  final bool success;
  final bool implemented;
  final String? message;
  final Map<String, dynamic> data;
}
```

คำอธิบาย:

- `success`: คำสั่งสำเร็จหรือไม่
- `implemented`: feature นี้ implement จริงแล้วหรือยัง
- `message`: ข้อความสรุป
- `data`: payload เพิ่มเติม

### TerminalEvent

```dart
class TerminalEvent {
  final String type;
  final String? message;
  final Map<String, dynamic> payload;
}
```

## Event types

### General lifecycle

- `streamReady`
- `initialized`
- `activityAttached`
- `activityDetached`
- `activityReattached`

### Reader / NFC

- `readerService`
- `readerServiceError`
- `status`
- `nfcResult`

`nfcResult` payload อาจมี:

- `pan`
- `expiry`
- `label`

### QR

- `qrStatus`
- `qrScanned`

`qrScanned` payload:

- `code`

### Device feedback

- `led`
- `buzzer`

## Example event handling

```dart
terminal.events.listen((event) {
  switch (event.type) {
    case 'readerServiceError':
      print('Reader error: ${event.message} ${event.payload}');
      break;
    case 'nfcResult':
      print('Card: ${event.payload}');
      break;
    case 'qrScanned':
      print('QR: ${event.payload['code']}');
      break;
  }
});
```

## Compatibility note

แม้ API ฝั่ง Dart จะค่อนข้างเสถียรแล้ว แต่ behavior ฝั่ง native ยังขึ้นกับ:

- hardware model
- vendor service version
- firmware ของเครื่อง
- binary SDK compatibility

ดังนั้นการมี method ใน API ไม่ได้แปลว่าเครื่องทุกเครื่องจะทำงานได้เท่ากัน
