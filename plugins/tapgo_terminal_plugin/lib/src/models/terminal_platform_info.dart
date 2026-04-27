class TerminalPlatformInfo {
  const TerminalPlatformInfo({
    required this.platform,
    required this.androidVersion,
    required this.sdkInt,
    required this.manufacturer,
    required this.brand,
    required this.model,
    required this.device,
    required this.hardware,
  });

  final String platform;
  final String androidVersion;
  final int sdkInt;
  final String manufacturer;
  final String brand;
  final String model;
  final String device;
  final String hardware;

  factory TerminalPlatformInfo.fromMap(Map<String, dynamic> map) {
    return TerminalPlatformInfo(
      platform: map['platform']?.toString() ?? 'android',
      androidVersion: map['androidVersion']?.toString() ?? '',
      sdkInt: (map['sdkInt'] as num?)?.toInt() ?? 0,
      manufacturer: map['manufacturer']?.toString() ?? '',
      brand: map['brand']?.toString() ?? '',
      model: map['model']?.toString() ?? '',
      device: map['device']?.toString() ?? '',
      hardware: map['hardware']?.toString() ?? '',
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'platform': platform,
      'androidVersion': androidVersion,
      'sdkInt': sdkInt,
      'manufacturer': manufacturer,
      'brand': brand,
      'model': model,
      'device': device,
      'hardware': hardware,
    };
  }
}
