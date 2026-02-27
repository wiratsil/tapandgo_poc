import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

class SyncDownloadService {
  /// ดาวน์โหลดไฟล์ .json.gz จาก URL และแตกไฟล์ (Decompress) กลับมาเป็น JSON String
  Future<String?> downloadAndDecompressJson(String url) async {
    try {
      debugPrint('Downloading from: \$url');
      final response = await http.get(Uri.parse(url));

      if (response.statusCode == 200) {
        // ใช้ GZipCodec เพื่อแตกไฟล์ (Decompress) ข้อมูล byte ที่ถูกบีบอัด
        final decompressedBytes = gzip.decode(response.bodyBytes);

        // แปลง byte กลับเป็น String รูปแบบ UTF-8 (JSON)
        final jsonString = utf8.decode(decompressedBytes);

        debugPrint('Successfully downloaded and decompressed JSON from \$url');
        return jsonString;
      } else {
        debugPrint(
          'Failed to download file. Status code: \${response.statusCode}',
        );
        return null;
      }
    } catch (e) {
      debugPrint('Error downloading or decompressing file: \$e');
      return null;
    }
  }

  /// ฟังก์ชันช่วยเหลือสำหรับแปลง JSON String เป็น List<Map<String, dynamic>>
  List<dynamic>? parseJsonList(String jsonString) {
    try {
      final decodedData = jsonDecode(jsonString);
      if (decodedData is List) {
        return decodedData;
      }
      return [decodedData]; // ห่อไว้ใน List ถ้าไม่ใช่ List
    } catch (e) {
      debugPrint('Error parsing JSON string: \$e');
      return null;
    }
  }
}
