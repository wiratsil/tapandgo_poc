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
      id: json['id'] ?? json['i'] ?? 0,
      routeDetailStartId: json['routeDetailStartId'] ?? json['s'] ?? 0,
      routeDetailEndId: json['routeDetailEndId'] ?? json['e'] ?? 0,
      price: (json['price'] ?? json['p'] as num?)?.toDouble() ?? 0.0,
      priceGroupId: json['priceGroupId'] ?? json['g'] ?? 0,
      routeId:
          json['routeId'] ?? json['ri'] ?? 0, // Assuming routeId might be 'ri'
      afterExpressBusstopId:
          json['afterExpressBusstopId'] ??
          json['ae'] ??
          0, // Assuming this might be 'ae'
      routeDetailStartSeq: json['routeDetailStartSeq'] ?? json['ss'] ?? 0,
      routeDetailEndSeq: json['routeDetailEndSeq'] ?? json['se'] ?? 0,
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
