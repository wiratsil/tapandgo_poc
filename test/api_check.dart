import 'dart:convert';
import 'package:http/http.dart' as http;

Future<void> main() async {
  const String url =
      'https://tng-platform-dev.atlasicloud.com/api/tng/data/commons';
  print('Fetching data from: $url');

  try {
    final response = await http.get(Uri.parse(url));

    if (response.statusCode == 200) {
      print('Success: ${response.statusCode}');
      final Map<String, dynamic> jsonResponse = jsonDecode(
        utf8.decode(response.bodyBytes),
      );
      print('Response: $jsonResponse');

      if (jsonResponse['isSuccess'] == true) {
        print('API returned Success=true');
        List data = jsonResponse['data'];
        print('Data count: ${data.length}');
        for (var item in data) {
          print(
            ' - ${item['commonName']} (${item['commonCode']}): ${item['values']}',
          );
        }
      } else {
        print('API returned Success=false');
      }
    } else {
      print('Failed: ${response.statusCode}');
      print('Body: ${response.body}');
    }
  } catch (e) {
    print('Error: $e');
  }
}
