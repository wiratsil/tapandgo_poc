class GpsData {
  final String box;
  final double lat;
  final double lng;
  final DateTime? rec;
  final double spd;

  GpsData({
    required this.box,
    required this.lat,
    required this.lng,
    this.rec,
    required this.spd,
  });

  factory GpsData.fromJson(Map<String, dynamic> json) {
    return GpsData(
      box: json['box']?.toString() ?? '',
      lat: (json['lat'] ?? 0.0).toDouble(),
      lng: (json['lng'] ?? 0.0).toDouble(),
      rec: json['rec'] != null
          ? DateTime.tryParse(
              json['rec'],
            )?.toUtc().add(const Duration(hours: 7))
          : null,
      spd: (json['spd'] ?? 0.0).toDouble(),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'box': box,
      'lat': lat,
      'lng': lng,
      'rec': rec?.toIso8601String(),
      'spd': spd,
    };
  }
}
