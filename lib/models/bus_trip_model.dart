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
      data:
          (json['data'] as List?)
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

  BusTrip({
    required this.id,
    required this.routeId,
    required this.buslineId,
    required this.businfoId,
    required this.licensePlate,
    required this.busno,
    this.actualDatetimeFromSource,
    this.actualDatetimeToDestination,
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
          ? DateTime.tryParse(json['actualDatetimeFromSource'])
          : null,
      actualDatetimeToDestination: json['actualDatetimeToDestination'] != null
          ? DateTime.tryParse(json['actualDatetimeToDestination'])
          : null,
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
      'actualDatetimeToDestination': actualDatetimeToDestination
          ?.toIso8601String(),
    };
  }
}
