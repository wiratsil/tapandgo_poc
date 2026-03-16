import 'package:flutter/material.dart';

import 'dart:async'; // Add Timer import

class SuccessResultScreen extends StatefulWidget {
  final void Function(BuildContext) onDismiss;
  final String title;
  final String message;
  final String? price; // Optional price
  final String? balance; // Optional balance (new)
  final bool isTapOut;
  final String? topStatus; // "เริ่มต้นเดินทาง" or "PAYMENT OK"
  final String? instruction; // "กรุณาแตะบัตรอีกครั้ง..."

  const SuccessResultScreen({
    super.key,
    required this.onDismiss,
    this.title = 'อนุสาวรีย์ชัยฯ',
    this.message = 'ยินดีต้อนรับ',
    this.price,
    this.balance,
    this.isTapOut = false,
    this.topStatus,
    this.instruction,
  });

  @override
  State<SuccessResultScreen> createState() => _SuccessResultScreenState();
}

class _SuccessResultScreenState extends State<SuccessResultScreen> {
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _timer = Timer(const Duration(seconds: 3), () {
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
    if (widget.isTapOut) {
      return _buildTapOutView(context);
    } else {
      return _buildTapInView(context);
    }
  }

  Widget _buildTapInView(BuildContext context) {
    final now = DateTime.now();
    final timeString =
        '${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}';

    return Scaffold(
      backgroundColor: const Color(0xFF20A07B), // Teal-green background
      body: InkWell(
        onTap: () => widget.onDismiss(context),
        child: SafeArea(
          child: LayoutBuilder(
            builder: (context, constraints) {
              return SingleChildScrollView(
                child: ConstrainedBox(
                  constraints: BoxConstraints(minHeight: constraints.maxHeight),
                  child: IntrinsicHeight(
                    child: Column(
                      children: [
                        // Top Bar
                        Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 24.0,
                            vertical: 16.0,
                          ),
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              const Text(
                                'TAP-IN SUCCESS',
                                style: TextStyle(
                                  color: Colors.white70,
                                  fontSize: 14,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                              Text(
                                timeString,
                                style: const TextStyle(
                                  color: Colors.white70,
                                  fontSize: 14,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ],
                          ),
                        ),

                        const SizedBox(height: 20), // Reduced from 40
                        // Center Graphic
                        Container(
                          width: 160, // Reduced from 180
                          height: 160, // Reduced from 180
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            border: Border.all(color: Colors.white24, width: 2),
                          ),
                          child: Center(
                            child: Row(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Container(
                                  padding: const EdgeInsets.all(4),
                                  decoration: BoxDecoration(
                                    color: const Color(0xFF5C9CFF),
                                    borderRadius: BorderRadius.circular(4),
                                  ),
                                  child: const Icon(
                                    Icons.arrow_forward,
                                    color: Colors.white,
                                    size: 24,
                                  ), // Reduced
                                ),
                                const SizedBox(width: 8),
                                const Icon(
                                  Icons.credit_card,
                                  size: 64,
                                  color: Color(0xFF5C9CFF),
                                ), // Reduced
                              ],
                            ),
                          ),
                        ),

                        const SizedBox(height: 20), // Reduced from 40
                        // Main Texts
                        const Text(
                          'แตะขึ้นสำเร็จ',
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 32, // Reduced from 36
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        const SizedBox(height: 8),
                        const Text(
                          'ENTRY RECORDED',
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 16, // Reduced from 18
                            fontWeight: FontWeight.bold,
                          ),
                        ),

                        const SizedBox(height: 20), // Reduced from 40
                        // Details Card
                        Container(
                          margin: const EdgeInsets.symmetric(horizontal: 32),
                          padding: const EdgeInsets.symmetric(
                            vertical: 20,
                            horizontal: 16,
                          ), // Reduced padding
                          width: double.infinity,
                          decoration: BoxDecoration(
                            color: Colors.white.withOpacity(0.1),
                            borderRadius: BorderRadius.circular(24),
                            border: Border.all(color: Colors.white24),
                          ),
                          child: Column(
                            children: const [
                              Text(
                                'ข้อมูลการเดินทาง',
                                style: TextStyle(
                                  color: Colors.white70,
                                  fontSize: 14,
                                ),
                              ),
                              SizedBox(height: 8),
                              Text(
                                'เริ่มบันทึกจุดขึ้นรถ',
                                style: TextStyle(
                                  color: Colors.white,
                                  fontSize: 20, // Reduced from 24
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                              SizedBox(height: 12),
                              Text(
                                'ราคาจะคำนวณจากระยะทางจริง',
                                style: TextStyle(
                                  color: Colors.white70,
                                  fontSize: 12,
                                ), // Reduced
                              ),
                            ],
                          ),
                        ),

                        const Spacer(),

                        // Bottom Pill
                        Container(
                          margin: const EdgeInsets.only(
                            top: 20,
                            bottom: 32,
                          ), // Added top margin
                          padding: const EdgeInsets.symmetric(
                            horizontal: 20,
                            vertical: 12,
                          ), // Reduced padding
                          decoration: BoxDecoration(
                            color: Colors.white,
                            borderRadius: BorderRadius.circular(30),
                            boxShadow: [
                              BoxShadow(
                                color: Colors.black.withOpacity(0.1),
                                blurRadius: 10,
                                offset: const Offset(0, 5),
                              ),
                            ],
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: const [
                              Icon(
                                Icons.notifications_active,
                                color: Colors.amber,
                                size: 20,
                              ), // Reduced
                              SizedBox(width: 8),
                              Text(
                                'อย่าลืมแตะออกเมื่อถึงจุดหมาย',
                                style: TextStyle(
                                  color: Colors.black87,
                                  fontWeight: FontWeight.bold,
                                  fontSize: 14, // Reduced from 16
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      ),
    );
  }

  Widget _buildTapOutView(BuildContext context) {
    final now = DateTime.now();
    final timeString =
        '${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}';

    return Scaffold(
      body: InkWell(
        onTap: () => widget.onDismiss(context),
        child: Container(
          width: double.infinity,
          height: double.infinity,
          decoration: const BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [
                Color(0xFF2C5A6B), // Top lighter ocean blue
                Color(0xFF13323D), // Bottom dark navy/teal
              ],
            ),
          ),
          child: SafeArea(
            child: LayoutBuilder(
              builder: (context, constraints) {
                return SingleChildScrollView(
                  child: ConstrainedBox(
                    constraints: BoxConstraints(
                      minHeight: constraints.maxHeight,
                    ),
                    child: IntrinsicHeight(
                      child: Column(
                        children: [
                          // Top Bar
                          Padding(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 24.0,
                              vertical: 16.0,
                            ),
                            child: Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                const Text(
                                  'TAP-OUT SUCCESS',
                                  style: TextStyle(
                                    color: Colors.white70,
                                    fontSize: 14,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                                Text(
                                  timeString,
                                  style: const TextStyle(
                                    color: Colors.white70,
                                    fontSize: 14,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                              ],
                            ),
                          ),

                          const SizedBox(height: 20),

                          // Center Graphic
                          Container(
                            width: 160,
                            height: 160,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              border: Border.all(
                                color: Colors.white24,
                                width: 2,
                              ),
                            ),
                            child: Center(
                              child: Row(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  const Icon(
                                    Icons.credit_card,
                                    size: 56,
                                    color: Color(0xFF5C9CFF),
                                  ), // Card
                                  const SizedBox(width: 8),
                                  Container(
                                    padding: const EdgeInsets.all(4),
                                    decoration: BoxDecoration(
                                      color: const Color(0xFF5C9CFF),
                                      borderRadius: BorderRadius.circular(4),
                                    ),
                                    child: const Icon(
                                      Icons.arrow_forward,
                                      color: Colors.white,
                                      size: 24,
                                    ), // Arrow Right
                                  ),
                                ],
                              ),
                            ),
                          ),

                          const SizedBox(height: 30),

                          // Main Texts
                          const Text(
                            'แตะลงสำเร็จ',
                            style: TextStyle(
                              color: Colors.white,
                              fontSize: 32,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          const SizedBox(height: 8),
                          const Text(
                            'EXIT RECORDED',
                            style: TextStyle(
                              color: Colors.white,
                              fontSize: 16,
                              fontWeight: FontWeight.bold,
                            ),
                          ),

                          const SizedBox(height: 30),

                          // Details Card
                          Container(
                            margin: const EdgeInsets.symmetric(horizontal: 32),
                            padding: const EdgeInsets.symmetric(
                              vertical: 24,
                              horizontal: 16,
                            ),
                            width: double.infinity,
                            decoration: BoxDecoration(
                              color: Colors.white.withOpacity(0.08),
                              borderRadius: BorderRadius.circular(24),
                              border: Border.all(color: Colors.white24),
                            ),
                            child: Column(
                              children: [
                                const Text(
                                  'สถานะค่าโดยสาร',
                                  style: TextStyle(
                                    color: Colors.white70,
                                    fontSize: 12,
                                  ),
                                ),
                                const SizedBox(height: 12),
                                Row(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  children: const [
                                    Text('⏳', style: TextStyle(fontSize: 24)),
                                    SizedBox(width: 8),
                                    Text(
                                      'รอประมวลผล',
                                      style: TextStyle(
                                        color: Color(0xFFFFCC00), // Yellow gold
                                        fontSize: 22,
                                        fontWeight: FontWeight.bold,
                                      ),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 16),
                                const Text(
                                  'ระบบได้รับจุดลงรถของท่านแล้ว\nกำลังคำนวณยอดเงินตามระยะทาง',
                                  textAlign: TextAlign.center,
                                  style: TextStyle(
                                    color: Colors.white70,
                                    fontSize: 13,
                                    height: 1.5,
                                  ),
                                ),
                              ],
                            ),
                          ),

                          const Spacer(),

                          // Bottom Text
                          const Padding(
                            padding: EdgeInsets.only(top: 20, bottom: 40),
                            child: Text(
                              'ขอบคุณที่ใช้บริการ BMTA ✨',
                              style: TextStyle(
                                color: Colors.white70,
                                fontSize: 14,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        ),
      ),
    );
  }
}
