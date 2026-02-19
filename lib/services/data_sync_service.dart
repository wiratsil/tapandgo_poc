import 'package:flutter/foundation.dart';

import 'common_data_service.dart';
import 'route_service.dart';
import 'database_helper.dart';

class DataSyncService {
  final CommonDataService _commonDataService = CommonDataService();
  final RouteService _routeService = RouteService();
  final DatabaseHelper _dbHelper = DatabaseHelper();

  // Hardcoded default plate number as per requirement/convention
  static const String _defaultPlateNo = '12-2587';

  Future<bool> syncAllData({String plateNo = _defaultPlateNo}) async {
    try {
      debugPrint('[DEBUG] 🔄 Starting Data Sync with plateNo: $plateNo');

      // 1. Fetch all data from APIs
      // We do this first to ensure we have all data before clearing DB

      debugPrint('📥 Fetching Common Data...');
      final commonDataResponse = await _commonDataService.getCommonData();
      if (commonDataResponse == null || !commonDataResponse.isSuccess) {
        debugPrint('[DEBUG] ❌ Failed to fetch Common Data');
        return false;
      }
      debugPrint(
        '[DEBUG] 📦 Common Data items: ${commonDataResponse.data.length}',
      );

      debugPrint('📥 Fetching Route Details for $plateNo...');
      final routeDetailsResponse = await _routeService.getRouteDetails(plateNo);
      if (routeDetailsResponse == null || !routeDetailsResponse.isSuccess) {
        debugPrint('[DEBUG] ❌ Failed to fetch Route Details');
        return false;
      }
      debugPrint(
        '[DEBUG] 📦 Route Details items: ${routeDetailsResponse.data.length}',
      );

      debugPrint('📥 Fetching Price Ranges for $plateNo...');
      final priceRangesResponse = await _routeService.getPriceRanges(plateNo);
      if (priceRangesResponse == null || !priceRangesResponse.isSuccess) {
        debugPrint('[DEBUG] ❌ Failed to fetch Price Ranges');
        return false;
      }
      debugPrint(
        '[DEBUG] 📦 Price Ranges items: ${priceRangesResponse.data.length}',
      );

      debugPrint('📥 Fetching Bus Trips for $plateNo...');
      final busTripsResponse = await _routeService.getBusTrips(plateNo);
      if (busTripsResponse == null || !busTripsResponse.isSuccess) {
        debugPrint('[DEBUG] ❌ Failed to fetch Bus Trips');
        return false;
      }
      debugPrint('[DEBUG] 📦 Bus Trips items: ${busTripsResponse.data.length}');

      // 2. Clear existing data and insert new data
      debugPrint('[DEBUG] 🧹 Clearing existing database...');
      await _dbHelper.clearAllData();

      debugPrint('[DEBUG] 💾 Inserting new data...');
      await _dbHelper.insertCommonData(commonDataResponse.data);
      await _dbHelper.insertRouteDetails(routeDetailsResponse.data);
      await _dbHelper.insertPriceRanges(priceRangesResponse.data);
      await _dbHelper.insertBusTrips(busTripsResponse.data);

      debugPrint('[DEBUG] ✅ Data Sync Completed Successfully!');
      return true;
    } catch (e) {
      debugPrint('[DEBUG] ❌ Error during Data Sync: $e');
      return false;
    }
  }
}
