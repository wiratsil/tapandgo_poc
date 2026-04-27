class TerminalCapabilities {
  const TerminalCapabilities({
    required this.isAndroid,
    required this.hasNfcFeature,
    required this.hasBluetoothFeature,
    required this.hasWifiDirectFeature,
    required this.hasCameraFeature,
    required this.hasGpsFeature,
    required this.vendorReaderServiceInstalled,
    required this.vendorReaderSdkBundled,
    required this.vendorUtilitySdkBundled,
    required this.zxingBundled,
  });

  final bool isAndroid;
  final bool hasNfcFeature;
  final bool hasBluetoothFeature;
  final bool hasWifiDirectFeature;
  final bool hasCameraFeature;
  final bool hasGpsFeature;
  final bool vendorReaderServiceInstalled;
  final bool vendorReaderSdkBundled;
  final bool vendorUtilitySdkBundled;
  final bool zxingBundled;

  factory TerminalCapabilities.fromMap(Map<String, dynamic> map) {
    return TerminalCapabilities(
      isAndroid: map['isAndroid'] == true,
      hasNfcFeature: map['hasNfcFeature'] == true,
      hasBluetoothFeature: map['hasBluetoothFeature'] == true,
      hasWifiDirectFeature: map['hasWifiDirectFeature'] == true,
      hasCameraFeature: map['hasCameraFeature'] == true,
      hasGpsFeature: map['hasGpsFeature'] == true,
      vendorReaderServiceInstalled: map['vendorReaderServiceInstalled'] == true,
      vendorReaderSdkBundled: map['vendorReaderSdkBundled'] == true,
      vendorUtilitySdkBundled: map['vendorUtilitySdkBundled'] == true,
      zxingBundled: map['zxingBundled'] == true,
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'isAndroid': isAndroid,
      'hasNfcFeature': hasNfcFeature,
      'hasBluetoothFeature': hasBluetoothFeature,
      'hasWifiDirectFeature': hasWifiDirectFeature,
      'hasCameraFeature': hasCameraFeature,
      'hasGpsFeature': hasGpsFeature,
      'vendorReaderServiceInstalled': vendorReaderServiceInstalled,
      'vendorReaderSdkBundled': vendorReaderSdkBundled,
      'vendorUtilitySdkBundled': vendorUtilitySdkBundled,
      'zxingBundled': zxingBundled,
    };
  }
}
