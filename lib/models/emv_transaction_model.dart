/// Location data for EMV tap (with bus stop + GPS box details)
class EmvTapLocation {
  final double? latitude; // GPS จากเครื่อง POS (null ถ้าดึงไม่ได้)
  final double? longitude; // GPS จากเครื่อง POS (null ถ้าดึงไม่ได้)
  final int busstopId; // master data BMS (route_details)
  final String busstopName; // master data BMS (route_details)
  final double busstopLatitude; // master data BMS (route_details)
  final double busstopLongitude; // master data BMS (route_details)
  final double busstopDistance; // คำนวณระยะห่าง gps_busstop <-> busstop
  final String gpsbusstopName; // GPS จาก morgan (MQTT) → ชื่อป้ายใกล้สุด
  final double gpsbusstopLatitude; // GPS จาก morgan (MQTT) → lat
  final double gpsbusstopLongitude; // GPS จาก morgan (MQTT) → lng
  final String gpsBoxId;
  final String gpsRecDatetime;
  final double gpsSpeed;

  EmvTapLocation({
    this.latitude,
    this.longitude,
    required this.busstopId,
    required this.busstopName,
    required this.busstopLatitude,
    required this.busstopLongitude,
    required this.busstopDistance,
    required this.gpsbusstopName,
    required this.gpsbusstopLatitude,
    required this.gpsbusstopLongitude,
    required this.gpsBoxId,
    required this.gpsRecDatetime,
    required this.gpsSpeed,
  });

  Map<String, dynamic> toJson() {
    return {
      'latitude': latitude,
      'longitude': longitude,
      'busstop_id': busstopId,
      'busstop_name': busstopName,
      'busstop_latitude': busstopLatitude,
      'busstop_longitude': busstopLongitude,
      'busstop_distance': busstopDistance,
      'gps_busstop_name': gpsbusstopName,
      'gps_busstop_latitude': gpsbusstopLatitude,
      'gps_busstop_longitude': gpsbusstopLongitude,
      'gps_box_id': gpsBoxId,
      'gps_rec_datetime': gpsRecDatetime,
      'gps_speed': gpsSpeed,
    };
  }
}

/// Fare breakdown info for an EMV transaction
class EmvFareInfo {
  final int bustripId;
  final int routeId;
  final int buslineId;
  final int businfoId;
  final String busNo;
  final bool isMorning;
  final bool isExpress;
  final double morningAmount;
  final double expressAmount;
  final double fareAmount;
  final double totalAmount;
  final bool isFlatRate;
  final double flatPrice;

  EmvFareInfo({
    required this.bustripId,
    required this.routeId,
    required this.buslineId,
    required this.businfoId,
    required this.busNo,
    required this.isMorning,
    required this.isExpress,
    required this.morningAmount,
    required this.expressAmount,
    required this.fareAmount,
    required this.totalAmount,
    this.isFlatRate = false,
    this.flatPrice = 0,
  });

  Map<String, dynamic> toJson() {
    return {
      'bustrip_id': bustripId,
      'route_id': routeId,
      'busline_id': buslineId,
      'businfo_id': businfoId,
      'bus_no': busNo,
      'is_morning': isMorning,
      'is_express': isExpress,
      'morning_amount': morningAmount,
      'express_amount': expressAmount,
      'fare_amount': fareAmount,
      'total_amount': totalAmount,
      'isFlatRate': isFlatRate,
      'flatPrice': flatPrice,
    };
  }
}

/// A single EMV transaction item
class EmvTransactionItem {
  final String txnId;
  final String assetId;
  final String assetType;
  final String tapInTime;
  final EmvTapLocation tapInLoc;
  final String tapOutTime;
  final EmvTapLocation tapOutLoc;
  final EmvFareInfo fareInfo;

  EmvTransactionItem({
    required this.txnId,
    required this.assetId,
    required this.assetType,
    required this.tapInTime,
    required this.tapInLoc,
    required this.tapOutTime,
    required this.tapOutLoc,
    required this.fareInfo,
  });

  Map<String, dynamic> toJson() {
    return {
      'txn_id': txnId,
      'asset_id': assetId,
      'asset_type': assetType,
      'tap_in_time': tapInTime,
      'tap_in_loc': tapInLoc.toJson(),
      'tap_out_time': tapOutTime,
      'tap_out_loc': tapOutLoc.toJson(),
      'fare_info': fareInfo.toJson(),
    };
  }
}

/// Request body for POST /tap/transactions/emv
class EmvTransactionRequest {
  final String deviceId;
  final String plateNo;
  final List<EmvTransactionItem> transactions;
  final bool? isFlatRate;
  final double? flatPrice;

  EmvTransactionRequest({
    required this.deviceId,
    required this.plateNo,
    required this.transactions,
    this.isFlatRate,
    this.flatPrice,
  });

  Map<String, dynamic> toJson() {
    final json = {
      'device_id': deviceId,
      'plate_no': plateNo,
      'transactions': transactions.map((e) => e.toJson()).toList(),
    };
    if (isFlatRate != null) {
      json['isFlatRate'] = isFlatRate as Object;
    }
    if (flatPrice != null) {
      json['flatPrice'] = flatPrice as Object;
    }
    return json;
  }
}
