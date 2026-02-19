import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import '../models/common_data_model.dart';

class CommonDataService {
  static const String _baseUrl =
      'https://tng-platform-dev.atlasicloud.com/api/tng/data/commons';

  Future<CommonDataResponse?> getCommonData() async {
    try {
      final response = await http.get(Uri.parse(_baseUrl));

      if (response.statusCode == 200) {
        final Map<String, dynamic> jsonResponse = jsonDecode(
          utf8.decode(response.bodyBytes),
        );
        return CommonDataResponse.fromJson(jsonResponse);
      } else {
        debugPrint('Failed to load common data: ${response.statusCode}');
        return null;
      }
    } catch (e) {
      debugPrint('Error fetching common data: $e');
      return null;
    }
  }
}
