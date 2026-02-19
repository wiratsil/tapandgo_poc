import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tapandgo_poc/services/common_data_service.dart';

void main() {
  test('CommonDataService fetches and parses data correctly', () async {
    final service = CommonDataService();
    final result = await service.getCommonData();

    if (result != null) {
      debugPrint('Success: ${result.isSuccess}');
      debugPrint('Message: ${result.message}');
      for (var item in result.data) {
        debugPrint(
          'Item: ${item.commonName} (${item.commonCode}) - Value: ${item.values}',
        );
      }
      expect(result.isSuccess, true);
      expect(result.data.isNotEmpty, true);
    } else {
      debugPrint('Failed to fetch data');
      fail('Failed to fetch data');
    }
  });
}
