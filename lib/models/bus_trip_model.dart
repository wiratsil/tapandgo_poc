class BusTripResponse {
  final bool isSuccess;
  final String message;
  final List<BusTrip> data;

  BusTripResponse({
    required this.isSuccess,
    required this.message,
    required this.data,
  });

  factory BusTripResponse.fromJson(Map<String, dynamic> json) {
    return BusTripResponse(
      isSuccess: json['isSuccess'] ?? false,
      message: json['message'] ?? '',
      data: (json['data'] as List?)
              ?.map((item) => BusTrip.fromJson(item))
              .toList() ??
          [],
    );
  }
}

class BusTrip {
  final int id;
  final int routeId;
  final int buslineId;
  final int businfoId;
  final String licensePlate;
  final String busno;
  final DateTime? actualDatetimeFromSource;
  final DateTime? actualDatetimeToDestination;
  final bool isFlatRate;
  final double flatPrice;

  BusTrip({
    required this.id,
    required this.routeId,
    required this.buslineId,
    required this.businfoId,
    required this.licensePlate,
    required this.busno,
    this.actualDatetimeFromSource,
    this.actualDatetimeToDestination,
    this.isFlatRate = false,
    this.flatPrice = 0,
  });

  factory BusTrip.fromJson(Map<String, dynamic> json) {
    return BusTrip(
      id: json['id'] ?? 0,
      routeId: json['routeId'] ?? 0,
      buslineId: json['buslineId'] ?? 0,
      businfoId: json['businfoId'] ?? 0,
      licensePlate: json['licensePlate'] ?? '',
      busno: json['busno'] ?? '',
      actualDatetimeFromSource: json['actualDatetimeFromSource'] != null
          ? DateTime.tryParse(json['actualDatetimeFromSource'].toString())
          : null,
      actualDatetimeToDestination: json['actualDatetimeToDestination'] != null
          ? DateTime.tryParse(json['actualDatetimeToDestination'].toString())
          : null,
      isFlatRate: _parseBool(json['isFlatRate']),
      flatPrice: _parseDouble(json['flatPrice']),
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'routeId': routeId,
      'buslineId': buslineId,
      'businfoId': businfoId,
      'licensePlate': licensePlate,
      'busno': busno,
      'actualDatetimeFromSource': actualDatetimeFromSource?.toIso8601String(),
      'actualDatetimeToDestination':
          actualDatetimeToDestination?.toIso8601String(),
      'isFlatRate': isFlatRate ? 1 : 0,
      'flatPrice': flatPrice,
    };
  }

  static bool _parseBool(dynamic value) {
    if (value is bool) return value;
    if (value is num) return value != 0;
    if (value is String) {
      final normalized = value.toLowerCase().trim();
      return normalized == 'true' || normalized == '1';
    }
    return false;
  }

  static double _parseDouble(dynamic value) {
    if (value is num) return value.toDouble();
    if (value is String) return double.tryParse(value) ?? 0;
    return 0;
  }
}
