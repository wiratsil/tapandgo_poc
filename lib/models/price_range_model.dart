class PriceRangeResponse {
  final bool isSuccess;
  final String message;
  final List<PriceRange> data;

  PriceRangeResponse({
    required this.isSuccess,
    required this.message,
    required this.data,
  });

  factory PriceRangeResponse.fromJson(Map<String, dynamic> json) {
    return PriceRangeResponse(
      isSuccess: json['isSuccess'] ?? false,
      message: json['message'] ?? '',
      data:
          (json['data'] as List?)
              ?.map((item) => PriceRange.fromJson(item))
              .toList() ??
          [],
    );
  }
}

class PriceRange {
  final int id;
  final int routeDetailStartId;
  final int routeDetailEndId;
  final double price;
  final int priceGroupId;
  final int routeId;
  final int afterExpressBusstopId;
  final int routeDetailStartSeq;
  final int routeDetailEndSeq;

  PriceRange({
    required this.id,
    required this.routeDetailStartId,
    required this.routeDetailEndId,
    required this.price,
    required this.priceGroupId,
    required this.routeId,
    required this.afterExpressBusstopId,
    required this.routeDetailStartSeq,
    required this.routeDetailEndSeq,
  });

  factory PriceRange.fromJson(Map<String, dynamic> json) {
    return PriceRange(
      id: json['id'] ?? 0,
      routeDetailStartId: json['routeDetailStartId'] ?? 0,
      routeDetailEndId: json['routeDetailEndId'] ?? 0,
      price: (json['price'] as num?)?.toDouble() ?? 0.0,
      priceGroupId: json['priceGroupId'] ?? 0,
      routeId: json['routeId'] ?? 0,
      afterExpressBusstopId: json['afterExpressBusstopId'] ?? 0,
      routeDetailStartSeq: json['routeDetailStartSeq'] ?? 0,
      routeDetailEndSeq: json['routeDetailEndSeq'] ?? 0,
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'routeDetailStartId': routeDetailStartId,
      'routeDetailEndId': routeDetailEndId,
      'price': price,
      'priceGroupId': priceGroupId,
      'routeId': routeId,
      'afterExpressBusstopId': afterExpressBusstopId,
      'routeDetailStartSeq': routeDetailStartSeq,
      'routeDetailEndSeq': routeDetailEndSeq,
    };
  }
}
