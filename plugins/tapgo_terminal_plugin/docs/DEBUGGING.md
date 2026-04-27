# Debugging Guide

เอกสารนี้สรุปวิธี debug `tapgo_terminal_plugin` โดยเฉพาะปัญหาฝั่ง Android terminal SDK

## ดู log หลัก

ใช้ logcat โดยกรองด้วย tag สำคัญ:

```powershell
adb logcat | Select-String "TapGoTerminalPlugin|AndroidRuntime|ReaderAIDL|com.reader.service"
```

สิ่งที่ plugin log ออก:

- reader registration
- event stream
- QR status
- errors สำคัญ

## อาการที่เจอบ่อย

### แอป crash ตอนเปิด

ตรวจว่า plugin พยายามแตะ reader service ตอน launch หรือไม่

สถานะปัจจุบัน:

- plugin ถูกปรับให้ไม่ register reader service ตอน `initialize()` แล้ว
- reader จะถูกแตะตอน `startNfc()` เป็นหลัก

### `vendorReaderServiceInstalled=false`

หมายความว่าเครื่องไม่มี package `com.reader.service`

สิ่งที่ต้องทำ:

- ติดตั้ง service ของ vendor
- ตรวจ firmware หรือ ROM ว่าตรงรุ่น

### `Failed resolution of: Ltimber/log/Timber;`

แปลว่า vendor SDK เรียก `Timber` แต่ dependency ยังไม่ครบ

สถานะ:

- plugin เพิ่ม `com.jakewharton.timber:timber:4.5.1` แล้ว

### `Failed resolution of: Lcom/reader/library/R$string;`

เป็นปัญหา resource package ของ reader SDK

สาเหตุ:

- SDK เดิมคาดหวัง resource package `com.reader.library`
- แต่เมื่อย้ายมาอยู่ใน plugin resource จะถูก generate ใต้ package ใหม่
- Android Gradle Plugin ยังมีพฤติกรรม strip R-related classes บางแบบออกจาก runtime artifact

สถานะปัจจุบัน:

- มี `reader-resource-bridge.jar` เพื่อช่วย bridge resource class
- ประเด็นนี้ยังเป็น known compatibility point ที่ต้องทดสอบบนเครื่องจริงต่อ

## วิธีแยกปัญหา

### 1. ตรวจว่าแอปเปิดได้ก่อนหรือไม่

ถ้าเปิดแอปไม่ขึ้น ให้แก้ปัญหา lifecycle / startup crash ก่อน

### 2. ตรวจ capability

เรียก:

```dart
final caps = await terminal.getCapabilities();
```

ให้ดูค่า:

- `vendorReaderServiceInstalled`
- `hasNfcFeature`
- `hasCameraFeature`

### 3. ตรวจ system status

เรียก:

```dart
final status = await terminal.getSystemStatus();
```

ดูค่า:

- `reader`
- `readerDetail`
- `readerContext`

### 4. เริ่มทีละ subsystem

ลำดับแนะนำ:

1. `initialize()`
2. `getCapabilities()`
3. `getSystemStatus()`
4. `playBuzzer()`
5. `showGreenLed()`
6. `startQr()`
7. `startNfc()`

แบบนี้จะช่วยแยกได้ว่า crash มาจาก subsystem ไหน

## คำสั่ง build/test ที่ใช้ใน repo นี้

จากโฟลเดอร์ plugin:

```powershell
..\ .fvm\flutter_sdk\bin\flutter.bat analyze
..\ .fvm\flutter_sdk\bin\flutter.bat test
```

จากโฟลเดอร์ example:

```powershell
..\..\ .fvm\flutter_sdk\bin\flutter.bat build apk --debug
..\..\ .fvm\flutter_sdk\bin\flutter.bat run
```

## ถ้าจะ debug ต่อในระดับลึก

จุดที่ควรดูใน Android code:

- [TapgoTerminalPlugin.kt](D:/Project/Futter_TapAndGO_POC/tapgo_terminal_plugin/android/src/main/kotlin/com/tapgo/tapgo_terminal_plugin/TapgoTerminalPlugin.kt)
- [android/build.gradle](D:/Project/Futter_TapAndGO_POC/tapgo_terminal_plugin/android/build.gradle)
- [android/libs](D:/Project/Futter_TapAndGO_POC/tapgo_terminal_plugin/android/libs)
- [android/vendor/reader_service](D:/Project/Futter_TapAndGO_POC/tapgo_terminal_plugin/android/vendor/reader_service)

## ข้อเสนอแนะสำหรับ production hardening

- แยก reader registration ออกจาก app startup ให้ชัด
- เพิ่ม feature flags สำหรับเปิด/ปิด subsystem
- เพิ่ม crash guard รอบ reader service callback ถ้าทำได้
- ทำ compatibility matrix ตามรุ่นเครื่องและ firmware
- เขียน integration checklist สำหรับเครื่องใหม่ทุกครั้งก่อน deploy
