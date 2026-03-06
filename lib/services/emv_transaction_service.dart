import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import '../models/emv_transaction_model.dart';

class EmvTransactionService {
  static const String _baseUrl =
      'https://tng-platform-dev.atlasicloud.com/api/tng/tap/transactions/emv';

  /// Submit an EMV transaction.
  /// Returns `true` on success (HTTP 2xx), `false` otherwise.
  Future<bool> submitEmvTransaction(EmvTransactionRequest request) async {
    try {
      debugPrint('[DEBUG] 📤 Submitting EMV Transaction to $_baseUrl');
      debugPrint('[DEBUG] 📦 Payload: ${jsonEncode(request.toJson())}');

      final response = await http.post(
        Uri.parse(_baseUrl),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode(request.toJson()),
      );

      if (response.statusCode >= 200 && response.statusCode < 300) {
        debugPrint(
          '[DEBUG] ✅ EMV Transaction submitted successfully (${response.statusCode})',
        );
        return true;
      } else {
        debugPrint(
          '[DEBUG] ❌ EMV Transaction failed: ${response.statusCode} - ${response.body}',
        );
        return false;
      }
    } catch (e) {
      debugPrint('[DEBUG] ❌ Error submitting EMV Transaction: $e');
      return false;
    }
  }
}
