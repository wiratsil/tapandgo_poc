class TerminalCommandResult {
  const TerminalCommandResult({
    required this.success,
    required this.implemented,
    this.message,
    this.data = const <String, dynamic>{},
  });

  final bool success;
  final bool implemented;
  final String? message;
  final Map<String, dynamic> data;

  bool get pendingMigration => !implemented;

  factory TerminalCommandResult.fromMap(Map<String, dynamic> map) {
    return TerminalCommandResult(
      success: map['success'] == true,
      implemented: map['implemented'] != false,
      message: map['message']?.toString(),
      data: Map<String, dynamic>.from(
        map['data'] as Map? ?? const <String, dynamic>{},
      ),
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'success': success,
      'implemented': implemented,
      'message': message,
      'data': data,
    };
  }
}
