import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import '../models/route_detail_model.dart';
import '../models/price_range_model.dart';
import '../models/bus_trip_model.dart';

class RouteService {
  static const String _routeDetailsUrl =
      'https://tng-platform-dev.atlasicloud.com/api/tng/data/route-details';
  static const String _priceRangesUrl =
      'https://tng-platform-dev.atlasicloud.com/api/tng/data/price-ranges';
  static const String _busTripsUrl =
      'https://tng-platform-dev.atlasicloud.com/api/tng/data/bus-trips';

  Future<RouteDetailResponse?> getRouteDetails(String plateNo) async {
    try {
      final uri = Uri.parse('$_routeDetailsUrl?PlateNo=$plateNo');
      final response = await http.get(uri);

      if (response.statusCode == 200) {
        final Map<String, dynamic> jsonResponse = jsonDecode(
          utf8.decode(response.bodyBytes),
        );
        return RouteDetailResponse.fromJson(jsonResponse);
      } else {
        debugPrint('Failed to load route details: ${response.statusCode}');
        return null;
      }
    } catch (e) {
      debugPrint('Error fetching route details: $e');
      return null;
    }
  }

  Future<PriceRangeResponse?> getPriceRanges(String plateNo) async {
    try {
      final uri = Uri.parse('$_priceRangesUrl?PlateNo=$plateNo');
      final response = await http.get(uri);

      if (response.statusCode == 200) {
        final Map<String, dynamic> jsonResponse = jsonDecode(
          utf8.decode(response.bodyBytes),
        );
        return PriceRangeResponse.fromJson(jsonResponse);
      } else {
        debugPrint('Failed to load price ranges: ${response.statusCode}');
        return null;
      }
    } catch (e) {
      debugPrint('Error fetching price ranges: $e');
      return null;
    }
  }

  Future<BusTripResponse?> getBusTrips(String plateNo) async {
    try {
      final uri = Uri.parse('$_busTripsUrl?PlateNo=$plateNo');
      final response = await http.get(uri);

      if (response.statusCode == 200) {
        final Map<String, dynamic> jsonResponse = jsonDecode(
          utf8.decode(response.bodyBytes),
        );
        return BusTripResponse.fromJson(jsonResponse);
      } else {
        debugPrint('Failed to load bus trips: ${response.statusCode}');
        return null;
      }
    } catch (e) {
      debugPrint('Error fetching bus trips: $e');
      return null;
    }
  }
}
