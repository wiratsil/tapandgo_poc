import 'package:flutter/material.dart';
import 'dart:async';

class ErrorResultScreen extends StatefulWidget {
  final void Function(BuildContext) onDismiss;
  final String errorMessage;
  final String errorTitle;

  const ErrorResultScreen({
    super.key,
    required this.onDismiss,
    this.errorMessage =
        'ยอดเงินไม่พอ / บัตรไม่ถูกต้อง\nInsufficient Funds / Invalid Card',
    this.errorTitle = 'ทำรายการไม่สำเร็จ',
  });

  @override
  State<ErrorResultScreen> createState() => _ErrorResultScreenState();
}

class _ErrorResultScreenState extends State<ErrorResultScreen> {
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    // Auto-dismiss after 5 seconds same as success screen
    _timer = Timer(const Duration(seconds: 5), () {
      if (mounted) {
        widget.onDismiss(context);
      }
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFD32F2F), // Red background
      body: SafeArea(
        child: InkWell(
          onTap: () => widget.onDismiss(context),
          child: Column(
            children: [
              // Header
              Padding(
                padding: const EdgeInsets.all(24.0),
                child: Row(
                  children: const [
                    Text(
                      'SYSTEM ALERT',
                      style: TextStyle(
                        color: Colors.white70,
                        fontWeight: FontWeight.bold,
                        fontSize: 14,
                        letterSpacing: 1.0,
                      ),
                    ),
                  ],
                ),
              ),

              const Spacer(),

              // Warning Icon
              const Icon(
                Icons.warning_amber_rounded,
                size: 100,
                color: Color(0xFFFFCA28), // Amber color
              ),

              const SizedBox(height: 24),

              // Main Title
              Text(
                widget.errorTitle,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 28,
                  fontWeight: FontWeight.bold,
                ),
              ),

              const SizedBox(height: 32),

              // Error Details Box
              Container(
                margin: const EdgeInsets.symmetric(horizontal: 32),
                padding: const EdgeInsets.symmetric(
                  vertical: 24,
                  horizontal: 20,
                ),
                width: double.infinity,
                decoration: BoxDecoration(
                  color: Colors.black.withOpacity(0.2),
                  borderRadius: BorderRadius.circular(24),
                  border: Border.all(color: Colors.white.withOpacity(0.1)),
                ),
                child: Column(
                  children: [
                    Text(
                      widget.errorMessage.split('\n')[0],
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    if (widget.errorMessage.contains('\n')) ...[
                      const SizedBox(height: 8),
                      Text(
                        widget.errorMessage.split('\n')[1],
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                          color: Color(
                            0xFFFFCA28,
                          ), // Amber text for English/Sub
                          fontSize: 16,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ],
                  ],
                ),
              ),

              const Spacer(),

              // Try Again Button
              Padding(
                padding: const EdgeInsets.only(bottom: 48.0),
                child: GestureDetector(
                  onTap: () => widget.onDismiss(context),
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 40,
                      vertical: 12,
                    ),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(30),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withOpacity(0.2),
                          blurRadius: 8,
                          offset: const Offset(0, 4),
                        ),
                      ],
                    ),
                    child: const Text(
                      'ลองใหม่อีกครั้ง',
                      style: TextStyle(
                        color: Color(0xFFD32F2F),
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
