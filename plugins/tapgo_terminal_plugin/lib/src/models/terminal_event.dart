class TerminalEvent {
  const TerminalEvent({
    required this.type,
    this.message,
    this.payload = const <String, dynamic>{},
  });

  final String type;
  final String? message;
  final Map<String, dynamic> payload;

  factory TerminalEvent.fromMap(Map<String, dynamic> map) {
    return TerminalEvent(
      type: map['type']?.toString() ?? 'unknown',
      message: map['message']?.toString(),
      payload: Map<String, dynamic>.from(
        map['payload'] as Map? ?? const <String, dynamic>{},
      ),
    );
  }

  Map<String, dynamic> toMap() {
    return {'type': type, 'message': message, 'payload': payload};
  }
}
