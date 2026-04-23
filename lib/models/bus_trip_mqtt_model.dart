class BusTripMqttData {
  final int id;
  final int rid;
  final int blid;
  final int bid;
  final String pn;
  final String bn;
  final DateTime? fs;
  final DateTime? td;
  final bool fr;
  final double fp;

  BusTripMqttData({
    required this.id,
    required this.rid,
    required this.blid,
    required this.bid,
    required this.pn,
    required this.bn,
    this.fs,
    this.td,
    this.fr = false,
    this.fp = 0,
  });

  factory BusTripMqttData.fromJson(Map<String, dynamic> json) {
    return BusTripMqttData(
      id: _parseInt(json['id']),
      rid: _parseInt(json['rid']),
      blid: _parseInt(json['blid']),
      bid: _parseInt(json['bid']),
      pn: json['pn']?.toString() ?? '',
      bn: json['bn']?.toString() ?? '',
      fs: json['fs'] != null ? DateTime.tryParse(json['fs'].toString()) : null,
      td: json['td'] != null ? DateTime.tryParse(json['td'].toString()) : null,
      fr: _parseBool(json['fr']),
      fp: _parseDouble(json['fp']),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'rid': rid,
      'blid': blid,
      'bid': bid,
      'pn': pn,
      'bn': bn,
      'fs': fs?.toIso8601String(),
      'td': td?.toIso8601String(),
      'fr': fr ? 1 : 0,
      'fp': fp,
    };
  }

  static int _parseInt(dynamic value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    if (value is String) return int.tryParse(value) ?? 0;
    return 0;
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
