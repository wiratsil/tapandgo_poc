import 'package:flutter/foundation.dart';

import 'common_data_service.dart';
import 'route_service.dart';
import 'database_helper.dart';
import 'check_version_service.dart';
import 'sync_download_service.dart';
import '../models/check_version_model.dart';
import '../models/route_detail_model.dart';
import '../models/price_range_model.dart';

class DataSyncService {
  final CommonDataService _commonDataService = CommonDataService();
  final RouteService _routeService = RouteService();
  final DatabaseHelper _dbHelper = DatabaseHelper();
  final CheckVersionService _checkVersionService = CheckVersionService();
  final SyncDownloadService _syncDownloadService = SyncDownloadService();

  // Default plate number
  static const String _defaultPlateNo = '';

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

      // Note: Fetch Bus Trips first to determine the active routeId
      debugPrint('📥 Fetching Bus Trips for $plateNo...');
      final busTripsResponse = await _routeService.getBusTrips(plateNo);
      if (busTripsResponse == null || !busTripsResponse.isSuccess) {
        debugPrint('[DEBUG] ❌ Failed to fetch Bus Trips');
        return false;
      }
      debugPrint('[DEBUG] 📦 Bus Trips items: ${busTripsResponse.data.length}');

      // Find active trip: actualDatetimeToDestination is null
      // If multiple, pick the one with the latest actualDatetimeFromSource
      int activeRouteId = 0; // Default fallback if no active trip found

      var activeTrips = busTripsResponse.data
          .where(
            (trip) =>
                trip.actualDatetimeToDestination == null &&
                trip.actualDatetimeFromSource != null,
          )
          .toList();

      if (activeTrips.isNotEmpty) {
        // Sort descending by actualDatetimeFromSource
        activeTrips.sort(
          (a, b) => b.actualDatetimeFromSource!.compareTo(
            a.actualDatetimeFromSource!,
          ),
        );
        activeRouteId = activeTrips.first.routeId;
        debugPrint('[DEBUG] � Found Active Trip! RouteId: $activeRouteId');
      } else {
        debugPrint(
          '[DEBUG] ⚠️ No active trip found. Using RouteId: $activeRouteId',
        );
      }

      debugPrint(
        '📥 Checking Version for $plateNo with routeId $activeRouteId...',
      );

      final checkVersionRequest = CheckVersionRequest(
        deviceInfo: DeviceInfo(
          deviceId: "EDC-K9-12345", // TODO: Replace with real Device ID
          plateNo: plateNo,
          appVersion: "1.2.0", // TODO: Replace with real App Version
        ),
        currentVersions: CurrentVersions(
          masterDataVersion: "", // Always fetch new version
          routeId: activeRouteId,
        ),
      );

      final checkVersionResponse = await _checkVersionService.checkVersion(
        checkVersionRequest,
      );

      List<RouteDetail> newRouteDetails = [];
      List<PriceRange> newPriceRanges = [];
      bool downloadSuccess = false;

      if (checkVersionResponse != null &&
          checkVersionResponse.isSuccess &&
          checkVersionResponse.data != null) {
        final versionData = checkVersionResponse.data!;

        // We now ignore updateRequired and always download the files to clear DB.
        debugPrint(
          '[DEBUG] 📦 Fetching new files. New version: ${versionData.newVersion}',
        );

        // Track if we actually downloaded anything
        bool hasFiles = versionData.files.isNotEmpty;

        for (var file in versionData.files) {
          debugPrint('[DEBUG] 📥 Downloading file from: ${file.url}');
          final jsonString = await _syncDownloadService
              .downloadAndDecompressJson(file.url);
          if (jsonString != null) {
            debugPrint(
              '[DEBUG] ✅ Decompressed JSON string length: ${jsonString.length}',
            );
            final parsedList = _syncDownloadService.parseJsonList(jsonString);
            if (parsedList != null) {
              if (file.module == 'route_details') {
                newRouteDetails = parsedList
                    .map((item) => RouteDetail.fromJson(item))
                    .toList();
                debugPrint(
                  '[DEBUG] 📦 Downloaded Route Details: ${newRouteDetails.length}',
                );
              } else if (file.module == 'price_ranges') {
                newPriceRanges = parsedList
                    .map((item) => PriceRange.fromJson(item))
                    .toList();
                debugPrint(
                  '[DEBUG] 📦 Downloaded Price Ranges: ${newPriceRanges.length}',
                );
              }
            }
          }
        }

        downloadSuccess = hasFiles;
      } else {
        debugPrint('[DEBUG] ❌ Failed to check version.');
      }

      // 2. Clear existing data and insert new data
      if (downloadSuccess) {
        debugPrint(
          '[DEBUG] 🧹 Update required: Clearing entirely existing database...',
        );
        await _dbHelper.clearAllData();

        debugPrint(
          '[DEBUG] 💾 Inserting new Master Data, Common Data & Bus Trips...',
        );
        await _dbHelper.insertRouteDetails(newRouteDetails);
        await _dbHelper.insertPriceRanges(newPriceRanges);
        await _dbHelper.insertCommonData(commonDataResponse.data);
        await _dbHelper.insertBusTrips(busTripsResponse.data);
      } else {
        debugPrint(
          '[DEBUG] ⏩ Skipping full DB clear and Master Data insert because download failed or no files.',
        );
        // We still need to clear common_data and bus_trips since they update frequently
        final db = await _dbHelper.database;
        await db.delete('common_data');
        await db.delete('bus_trips');

        debugPrint('[DEBUG] 💾 Inserting Common Data & Bus Trips...');
        await _dbHelper.insertCommonData(commonDataResponse.data);
        await _dbHelper.insertBusTrips(busTripsResponse.data);
      }

      debugPrint('[DEBUG] ✅ Data Sync Completed Successfully!');
      return true;
    } catch (e) {
      debugPrint('[DEBUG] ❌ Error during Data Sync: $e');
      return false;
    }
  }
}
