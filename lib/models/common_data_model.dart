class CommonDataResponse {
  final bool isSuccess;
  final String message;
  final List<CommonDataItem> data;

  CommonDataResponse({
    required this.isSuccess,
    required this.message,
    required this.data,
  });

  factory CommonDataResponse.fromJson(Map<String, dynamic> json) {
    return CommonDataResponse(
      isSuccess: json['isSuccess'] ?? false,
      message: json['message'] ?? '',
      data:
          (json['data'] as List?)
              ?.map((item) => CommonDataItem.fromJson(item))
              .toList() ??
          [],
    );
  }
}

class CommonDataItem {
  final int id;
  final String commonCode;
  final String commonName;
  final String commonType;
  final String values;
  final bool isActive;

  CommonDataItem({
    required this.id,
    required this.commonCode,
    required this.commonName,
    required this.commonType,
    required this.values,
    required this.isActive,
  });

  factory CommonDataItem.fromJson(Map<String, dynamic> json) {
    return CommonDataItem(
      id: json['id'] ?? 0,
      commonCode: json['commonCode'] ?? '',
      commonName: json['commonName'] ?? '',
      commonType: json['commonType'] ?? '',
      values: json['values'] ?? '',
      isActive: json['isActive'] ?? false,
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'commonCode': commonCode,
      'commonName': commonName,
      'commonType': commonType,
      'valuesText':
          values, // Renamed to avoid reserved keyword issues if any, matches DB schema
      'isActive': isActive ? 1 : 0,
    };
  }
}
