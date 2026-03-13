class BusTripMqttData {
  final int id;
  final int rid;
  final int blid;
  final int bid;
  final String pn;
  final String bn;
  final DateTime? fs;
  final DateTime? td;

  BusTripMqttData({
    required this.id,
    required this.rid,
    required this.blid,
    required this.bid,
    required this.pn,
    required this.bn,
    this.fs,
    this.td,
  });

  factory BusTripMqttData.fromJson(Map<String, dynamic> json) {
    return BusTripMqttData(
      id: json['id'] as int,
      rid: json['rid'] as int,
      blid: json['blid'] as int,
      bid: json['bid'] as int,
      pn: json['pn'] as String,
      bn: json['bn'] as String,
      fs: json['fs'] != null
          ? DateTime.tryParse(json['fs'].toString())
          : null,
      td: json['td'] != null
          ? DateTime.tryParse(json['td'].toString())
          : null,
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
    };
  }
}
