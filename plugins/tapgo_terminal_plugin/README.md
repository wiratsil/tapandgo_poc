# tapgo_terminal_plugin

Flutter plugin สำหรับห่อ Android terminal SDK ของ TapGo ให้นำกลับไปใช้ซ้ำในโปรเจกต์อื่นได้ง่ายขึ้น

ปลั๊กอินนี้ออกแบบมาสำหรับอุปกรณ์ Android แบบเฉพาะทางที่มี vendor reader service, hardware scanner, NFC reader, LED, buzzer และ SDK binaries ชุดเดียวกับโปรเจกต์ Tap&Go เดิม

## สรุปสั้น

- Platform: Android only
- Use case: terminal / handheld Android device ที่มี reader service ของ vendor
- Included binaries:
  - `demoSDK_v2.28.20241212.aar`
  - `library-release.aar`
  - `core-3.1.0.jar`
  - `reader-resource-bridge.jar`
- Flutter API ที่มีแล้ว:
  - initialize
  - getDeviceId
  - getPlatformInfo
  - getCapabilities
  - getSystemStatus
  - events stream
  - start/stop NFC
  - start/stop QR
  - LED controls
  - buzzer

## เหมาะกับกรณีไหน

ใช้เมื่อคุณต้องการ:

- reuse การเชื่อมต่อ hardware terminal เดิมในหลายโปรเจกต์ Flutter
- แยก native SDK coupling ออกจาก business logic ของแอปหลัก
- มี example app สำหรับทดสอบ reader/QR/LED/buzzer แยกจากโปรเจกต์ production

ไม่เหมาะถ้า:

- ต้องการให้ทำงานบน iOS, desktop หรือ Android ทั่วไปทุกเครื่อง
- ต้องการ plugin ที่ไม่ผูกกับ vendor service
- ต้องการ public package ที่เผยแพร่ได้โดยไม่ต้องเคลียร์สิทธิ์ของ AAR/JAR ก่อน

## สถาปัตยกรรม

ปลั๊กอินแบ่งเป็น 3 ชั้นหลัก:

1. Dart API
   - อยู่ใน [lib/tapgo_terminal_plugin.dart](D:/Project/Futter_TapAndGO_POC/tapgo_terminal_plugin/lib/tapgo_terminal_plugin.dart)
   - ให้ public interface ที่โปรเจกต์ Flutter อื่นเรียกได้โดยไม่ต้องรู้ MethodChannel

2. Flutter platform interface / method channel
   - แปลง method calls และ event stream ระหว่าง Dart กับ native Android

3. Android native layer
   - อยู่ใน [android/src/main/kotlin/com/tapgo/tapgo_terminal_plugin/TapgoTerminalPlugin.kt](D:/Project/Futter_TapAndGO_POC/tapgo_terminal_plugin/android/src/main/kotlin/com/tapgo/tapgo_terminal_plugin/TapgoTerminalPlugin.kt)
   - ห่อ vendor SDK, reader service, QR scanner, LED, buzzer, diagnostics

## โครงสร้างโฟลเดอร์สำคัญ

- [lib](D:/Project/Futter_TapAndGO_POC/tapgo_terminal_plugin/lib)
  - Dart API, models, platform abstraction
- [android](D:/Project/Futter_TapAndGO_POC/tapgo_terminal_plugin/android)
  - Android plugin implementation
- [android/libs](D:/Project/Futter_TapAndGO_POC/tapgo_terminal_plugin/android/libs)
  - binary dependencies ที่ bundle มากับ plugin
- [android/vendor](D:/Project/Futter_TapAndGO_POC/tapgo_terminal_plugin/android/vendor)
  - extracted vendor artifacts ที่ใช้ตอน build
- [example](D:/Project/Futter_TapAndGO_POC/tapgo_terminal_plugin/example)
  - แอปตัวอย่างสำหรับทดสอบ plugin
- [docs/API.md](D:/Project/Futter_TapAndGO_POC/tapgo_terminal_plugin/docs/API.md)
  - รายละเอียด API และ event
- [docs/DEBUGGING.md](D:/Project/Futter_TapAndGO_POC/tapgo_terminal_plugin/docs/DEBUGGING.md)
  - คู่มือ debug และ known issues

## ความต้องการของอุปกรณ์

อย่างน้อยควรมี:

- Android 7.0+ ตาม minSdk ของ plugin
- NFC hardware
- กล้องหรือ hardware QR scanner ตามเครื่อง
- vendor package `com.reader.service`
- firmware / ROM ที่เข้ากันกับ SDK ชุดนี้

สิ่งสำคัญคือ plugin นี้ไม่ได้พึ่งแค่ feature ของ Android ปกติ แต่พึ่ง vendor service และ library เฉพาะเครื่องด้วย

## การติดตั้ง

### แบบ git dependency

```yaml
dependencies:
  tapgo_terminal_plugin:
    git:
      url: https://github.com/your-org/tapgo_terminal_plugin.git
```

### แบบ path dependency ระหว่างพัฒนา

```yaml
dependencies:
  tapgo_terminal_plugin:
    path: ../tapgo_terminal_plugin
```

## ข้อกำหนดฝั่ง Android host app

- plugin นี้ประกาศ Android manifest และ permissions ที่จำเป็นไว้แล้วบางส่วน
- แอป host ยังควรจัดการ runtime permissions เองเมื่อจำเป็น
- ควรทดสอบบนอุปกรณ์จริง ไม่ใช่ emulator
- ถ้าเครื่องไม่มี `com.reader.service` บางความสามารถจะใช้ไม่ได้

## การใช้งานพื้นฐาน

```dart
import 'package:tapgo_terminal_plugin/tapgo_terminal_plugin.dart';

final terminal = TapgoTerminalPlugin.instance;

await terminal.initialize();

final deviceId = await terminal.getDeviceId();
final info = await terminal.getPlatformInfo();
final caps = await terminal.getCapabilities();
final status = await terminal.getSystemStatus();

terminal.events.listen((event) {
  print('${event.type}: ${event.message} ${event.payload}');
});
```

## ตัวอย่างใช้งาน

### ตรวจ capability ก่อนเริ่มงาน

```dart
final caps = await terminal.getCapabilities();
if (!caps.vendorReaderServiceInstalled) {
  throw Exception('Reader service is not installed on this device.');
}
```

### เริ่ม NFC

```dart
final result = await terminal.startNfc();
print(result.message);
```

### เริ่ม QR scanner

```dart
final result = await terminal.startQr();
print(result.message);
```

### ควบคุม LED และ buzzer

```dart
await terminal.showGreenLed();
await terminal.showYellowLed();
await terminal.showRedLed();
await terminal.playBuzzer(durationMs: 120);
```

## Event stream

plugin ส่ง event สำคัญออกทาง `terminal.events` เช่น:

- `streamReady`
- `initialized`
- `activityAttached`
- `status`
- `qrStatus`
- `readerService`
- `readerServiceError`
- `nfcResult`
- `qrScanned`
- `led`
- `buzzer`

ดูรายละเอียด payload ของแต่ละ event ได้ที่ [docs/API.md](D:/Project/Futter_TapAndGO_POC/tapgo_terminal_plugin/docs/API.md)

## สถานะปัจจุบันของฟีเจอร์

### ใช้งานได้ในระดับ plugin

- device info
- capabilities
- system status
- event logging
- QR scanner flow ระดับ native
- NFC start/stop flow ระดับ native
- LED / buzzer

### ยังมีข้อจำกัด

- reader service บางเครื่องยังมี compatibility issue จาก resource/runtime behavior ของ vendor SDK
- business logic ของ Tap&Go เดิม เช่น fare calc, sync, local DB ไม่ได้อยู่ใน plugin นี้
- ยังไม่ได้ห่อ Bluetooth / Wi-Fi Direct / multipath networking แบบครบ production

## Known issue สำคัญ

ช่วงนี้ประเด็นหลักอยู่ที่ reader service integration โดยเฉพาะ stack ของ `library-release.aar`

อาการที่เคยเจอ:

- `Failed resolution of: Ltimber/log/Timber;`
- `Failed resolution of: Lcom/reader/library/R$string;`

รายละเอียดและวิธี debug ดูต่อที่ [docs/DEBUGGING.md](D:/Project/Futter_TapAndGO_POC/tapgo_terminal_plugin/docs/DEBUGGING.md)

## การดู log

plugin พิมพ์ diagnostics ออกที่ Android logcat ด้วย tag:

- `TapGoTerminalPlugin`

คำสั่งแนะนำ:

```powershell
adb logcat | Select-String "TapGoTerminalPlugin|AndroidRuntime|ReaderAIDL|com.reader.service"
```

## การทดสอบ example

รันจาก [example](D:/Project/Futter_TapAndGO_POC/tapgo_terminal_plugin/example)

```powershell
..\..\ .fvm\flutter_sdk\bin\flutter.bat run
```

หรือ build apk:

```powershell
..\..\ .fvm\flutter_sdk\bin\flutter.bat build apk --debug
```

example ใช้ตรวจ:

- device info
- capability detection
- current system status
- NFC start/stop
- QR start/stop
- LED and buzzer
- event stream

## การใช้งานร่วมกับโปรเจกต์อื่น

แนะนำขั้นตอน:

1. แยกโฟลเดอร์ [tapgo_terminal_plugin](D:/Project/Futter_TapAndGO_POC/tapgo_terminal_plugin) ไปเป็น git repo ของตัวเอง
2. อัปเดต `homepage`, `repository`, `issue_tracker` ใน [pubspec.yaml](D:/Project/Futter_TapAndGO_POC/tapgo_terminal_plugin/pubspec.yaml)
3. เพิ่ม `.gitignore` และ CI ตามมาตรฐานทีม
4. ทดสอบผ่าน path dependency ในโปรเจกต์ Flutter ใหม่หนึ่งโปรเจกต์
5. ทดสอบบน hardware เป้าหมายจริง

## Licensing และ redistribution

ก่อนเผยแพร่ repo นี้ให้บุคคลภายนอก ต้องตรวจสิทธิ์ของ binary เหล่านี้ก่อน:

- `demoSDK_v2.28.20241212.aar`
- `library-release.aar`
- `core-3.1.0.jar`
- `reader-resource-bridge.jar`

โดยเฉพาะถ้าจะทำ public repository หรือส่งมอบข้ามองค์กร

## เอกสารเพิ่มเติม

- [docs/API.md](D:/Project/Futter_TapAndGO_POC/tapgo_terminal_plugin/docs/API.md)
- [docs/DEBUGGING.md](D:/Project/Futter_TapAndGO_POC/tapgo_terminal_plugin/docs/DEBUGGING.md)

## Repository hygiene

- plugin นี้ตั้งใจ bundle เฉพาะ binary ที่จำเป็นเท่านั้น
- transaction backup database จากแอปเดิมไม่ได้ถูกนำมารวมไว้
- focus ของ plugin คือ hardware abstraction ไม่ใช่ business logic
