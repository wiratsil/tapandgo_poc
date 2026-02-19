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
      debugPrint('🔄 Starting Data Sync...');

      // 1. Fetch all data from APIs
      // We do this first to ensure we have all data before clearing DB

      debugPrint('📥 Fetching Common Data...');
      final commonDataResponse = await _commonDataService.getCommonData();
      if (commonDataResponse == null || !commonDataResponse.isSuccess) {
        debugPrint('❌ Failed to fetch Common Data');
        return false;
      }

      debugPrint('📥 Fetching Route Details for $plateNo...');
      final routeDetailsResponse = await _routeService.getRouteDetails(plateNo);
      if (routeDetailsResponse == null || !routeDetailsResponse.isSuccess) {
        debugPrint('❌ Failed to fetch Route Details');
        return false;
      }

      debugPrint('📥 Fetching Price Ranges for $plateNo...');
      final priceRangesResponse = await _routeService.getPriceRanges(plateNo);
      if (priceRangesResponse == null || !priceRangesResponse.isSuccess) {
        debugPrint('❌ Failed to fetch Price Ranges');
        return false;
      }

      debugPrint('📥 Fetching Bus Trips for $plateNo...');
      final busTripsResponse = await _routeService.getBusTrips(plateNo);
      if (busTripsResponse == null || !busTripsResponse.isSuccess) {
        debugPrint('❌ Failed to fetch Bus Trips');
        return false;
      }

      // 2. Clear existing data and insert new data
      debugPrint('🧹 Clearing existing database...');
      await _dbHelper.clearAllData();

      debugPrint('💾 Inserting new data...');
      await _dbHelper.insertCommonData(commonDataResponse.data);
      await _dbHelper.insertRouteDetails(routeDetailsResponse.data);
      await _dbHelper.insertPriceRanges(priceRangesResponse.data);
      await _dbHelper.insertBusTrips(busTripsResponse.data);

      debugPrint('✅ Data Sync Completed Successfully!');
      return true;
    } catch (e) {
      debugPrint('❌ Error during Data Sync: $e');
      return false;
    }
  }
}
