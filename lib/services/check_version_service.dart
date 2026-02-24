import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import '../models/check_version_model.dart';

class CheckVersionService {
  static const String _baseUrl =
      'https://tng-platform-dev.atlasicloud.com/api/tng/data/check-version';

  Future<CheckVersionResponse?> checkVersion(
    CheckVersionRequest request,
  ) async {
    try {
      final response = await http.post(
        Uri.parse(_baseUrl),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode(request.toJson()),
      );

      if (response.statusCode == 200) {
        final Map<String, dynamic> jsonResponse = jsonDecode(
          utf8.decode(response.bodyBytes),
        );
        return CheckVersionResponse.fromJson(jsonResponse);
      } else {
        debugPrint('Failed to check version: ${response.statusCode}');
        return null;
      }
    } catch (e) {
      debugPrint('Error checking version: $e');
      return null;
    }
  }
}
