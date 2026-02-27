class RouteDetailResponse {
  final bool isSuccess;
  final String message;
  final List<RouteDetail> data;

  RouteDetailResponse({
    required this.isSuccess,
    required this.message,
    required this.data,
  });

  factory RouteDetailResponse.fromJson(Map<String, dynamic> json) {
    return RouteDetailResponse(
      isSuccess: json['isSuccess'] ?? false,
      message: json['message'] ?? '',
      data:
          (json['data'] as List?)
              ?.map((item) => RouteDetail.fromJson(item))
              .toList() ??
          [],
    );
  }
}

class RouteDetail {
  final int id;
  final int routeId;
  final int seq;
  final int busstopId;
  final String busstopDesc;
  final bool isExpress;
  final int? afterExpressBusstopId;
  final double latitude;
  final double longitude;

  RouteDetail({
    required this.id,
    required this.routeId,
    required this.seq,
    required this.busstopId,
    required this.busstopDesc,
    required this.isExpress,
    this.afterExpressBusstopId,
    required this.latitude,
    required this.longitude,
  });

  factory RouteDetail.fromJson(Map<String, dynamic> json) {
    return RouteDetail(
      id: json['id'] ?? json['i'] ?? 0,
      routeId:
          json['routeId'] ?? json['ri'] ?? 0, // Fallback if routeId is minified
      seq: json['seq'] ?? json['s'] ?? 0,
      busstopId: json['busstopId'] ?? json['b'] ?? 0,
      busstopDesc: json['busstopDesc'] ?? json['d'] ?? '',
      isExpress:
          json['isExpress'] == true ||
          json['isExpress'] == 1 ||
          json['e'] == true ||
          json['e'] == 1,
      afterExpressBusstopId: json['afterExpressBusstopId'] ?? json['ae'],
      latitude: (json['latitude'] ?? json['la'] as num?)?.toDouble() ?? 0.0,
      longitude: (json['longitude'] ?? json['lo'] as num?)?.toDouble() ?? 0.0,
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'routeId': routeId,
      'seq': seq,
      'busstopId': busstopId,
      'busstopDesc': busstopDesc,
      'isExpress': isExpress ? 1 : 0,
      'afterExpressBusstopId': afterExpressBusstopId,
      'latitude': latitude,
      'longitude': longitude,
    };
  }
}
