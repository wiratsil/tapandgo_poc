class TerminalSystemStatus {
  const TerminalSystemStatus({
    required this.gps,
    required this.reader,
    required this.readerDetail,
    required this.readerContext,
    required this.qr,
    required this.network,
    required this.bluetooth,
  });

  final String gps;
  final String reader;
  final String readerDetail;
  final String readerContext;
  final String qr;
  final String network;
  final String bluetooth;

  factory TerminalSystemStatus.fromMap(Map<String, dynamic> map) {
    return TerminalSystemStatus(
      gps: map['gps']?.toString() ?? 'UNKNOWN',
      reader: map['reader']?.toString() ?? 'UNKNOWN',
      readerDetail: map['readerDetail']?.toString() ?? '',
      readerContext: map['readerContext']?.toString() ?? 'UNKNOWN',
      qr: map['qr']?.toString() ?? 'UNKNOWN',
      network: map['network']?.toString() ?? 'UNKNOWN',
      bluetooth: map['bluetooth']?.toString() ?? 'UNKNOWN',
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'gps': gps,
      'reader': reader,
      'readerDetail': readerDetail,
      'readerContext': readerContext,
      'qr': qr,
      'network': network,
      'bluetooth': bluetooth,
    };
  }
}
