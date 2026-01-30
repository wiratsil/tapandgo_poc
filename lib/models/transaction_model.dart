class QrData {
  final String aid;
  final double bal;
  final String? exp;

  QrData({required this.aid, required this.bal, this.exp});

  factory QrData.fromJson(Map<String, dynamic> json) {
    return QrData(
      aid: json['aid'] as String,
      bal: (json['bal'] as num).toDouble(),
      exp: json['exp'] as String?,
    );
  }
}

class TransactionLocation {
  final double lat;
  final double lng;

  TransactionLocation({required this.lat, required this.lng});

  factory TransactionLocation.fromJson(Map<String, dynamic> json) {
    return TransactionLocation(
      lat: (json['lat'] as num).toDouble(),
      lng: (json['lng'] as num).toDouble(),
    );
  }

  Map<String, dynamic> toJson() {
    return {'lat': lat, 'lng': lng};
  }
}

class TransactionItem {
  final String txnId;
  final String assetId;
  final String assetType;
  final String tapInTime;
  final TransactionLocation tapInLoc;
  final String tapOutTime;
  final TransactionLocation tapOutLoc;

  TransactionItem({
    required this.txnId,
    required this.assetId,
    required this.assetType,
    required this.tapInTime,
    required this.tapInLoc,
    required this.tapOutTime,
    required this.tapOutLoc,
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
    };
  }
}

class TransactionRequest {
  final String deviceId;
  final String plateNo;
  final List<TransactionItem> transactions;

  TransactionRequest({
    required this.deviceId,
    required this.plateNo,
    required this.transactions,
  });

  Map<String, dynamic> toJson() {
    return {
      'device_id': deviceId,
      'plate_no': plateNo,
      'transactions': transactions.map((e) => e.toJson()).toList(),
    };
  }
}

class PendingTransaction {
  final String aid;
  final DateTime tapInTime;
  final TransactionLocation tapInLoc;

  PendingTransaction({
    required this.aid,
    required this.tapInTime,
    required this.tapInLoc,
  });

  factory PendingTransaction.fromJson(Map<String, dynamic> json) {
    return PendingTransaction(
      aid: json['aid'] as String,
      tapInTime: DateTime.parse(json['tapInTime'] as String),
      tapInLoc: TransactionLocation.fromJson(
        json['tapInLoc'] as Map<String, dynamic>,
      ),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'aid': aid,
      'tapInTime': tapInTime.toIso8601String(),
      'tapInLoc': tapInLoc.toJson(),
    };
  }
}
