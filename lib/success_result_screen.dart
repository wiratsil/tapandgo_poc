import 'package:flutter/material.dart';

import 'dart:async'; // Add Timer import

class SuccessResultScreen extends StatefulWidget {
  final void Function(BuildContext) onDismiss;
  final String title;
  final String message;
  final String price;
  final bool isTapOut; // New parameter to switch modes

  const SuccessResultScreen({
    super.key,
    required this.onDismiss,
    this.title = 'อนุสาวรีย์ชัยฯ',
    this.message = 'ยินดีต้อนรับ',
    this.price = '0.00 ฿',
    this.isTapOut = false,
  });

  @override
  State<SuccessResultScreen> createState() => _SuccessResultScreenState();
}

class _SuccessResultScreenState extends State<SuccessResultScreen> {
  Timer? _timer;

  @override
  void initState() {
    super.initState();
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
    // Theme configurations based on Tap In vs Tap Out
    final List<Color> gradientColors = widget.isTapOut
        ? [const Color(0xFF0D47A1), const Color(0xFF42A5F5)] // Blue Theme
        : [const Color(0xFF004D40), const Color(0xFF00C853)]; // Green Theme

    final String badgeText = widget.isTapOut ? 'PAYMENT OK' : 'SUCCESS';
    final Color badgeTextColor = widget.isTapOut
        ? const Color(0xFF0D47A1)
        : const Color(0xFF2E7D32);

    final IconData mainIcon = widget.isTapOut
        ? Icons.flag
        : Icons.check; // Using Flag for checkered simulation or separate widget
    final Color iconBgTop = widget.isTapOut
        ? Colors.white
        : const Color(0xFF81C784);
    final Color iconBgBottom = widget.isTapOut
        ? Colors.grey[300]!
        : const Color(0xFF4CAF50);
    final Color iconColor = widget.isTapOut ? Colors.black : Colors.white;

    final String priceLabel = widget.isTapOut ? 'ค่าโดยสาร' : 'ราคาเริ่มต้น';
    final Color priceColor = widget.isTapOut
        ? const Color(0xFFFFD600)
        : Colors.white; // Yellow for Tap Out

    final String topLabel = widget.isTapOut ? 'ลงที่:' : 'ขึ้นที่:';

    return Scaffold(
      body: InkWell(
        onTap: () => widget.onDismiss(context),
        child: Container(
          width: double.infinity,
          height: double.infinity,
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: gradientColors,
            ),
          ),
          child: SafeArea(
            child: Column(
              children: [
                // Top Bar
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 20,
                    vertical: 15,
                  ),
                  color: Colors.black.withOpacity(0.1),
                  child: Row(
                    children: [
                      Container(
                        width: 10,
                        height: 10,
                        decoration: const BoxDecoration(
                          color: Colors.greenAccent,
                          shape: BoxShape.circle,
                        ),
                      ),
                      const SizedBox(width: 10),
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            topLabel,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 14,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          Text(
                            widget.title,
                            style: const TextStyle(
                              color: Colors.yellow,
                              fontSize: 20,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),

                const Spacer(),

                // Badge
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 20,
                    vertical: 8,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Text(
                    badgeText,
                    style: TextStyle(
                      color: badgeTextColor,
                      fontWeight: FontWeight.bold,
                      fontSize: 16,
                    ),
                  ),
                ),
                const SizedBox(height: 20),

                // Icon (Checkered Flag or Check)
                widget.isTapOut
                    ? _buildCheckeredFlag() // Custom widget for checkered flag
                    : Container(
                        width: 100,
                        height: 100,
                        decoration: BoxDecoration(
                          color: Colors.white, // Fallback
                          borderRadius: BorderRadius.circular(20),
                          boxShadow: [
                            BoxShadow(
                              color: Colors.black.withOpacity(0.2),
                              offset: const Offset(0, 5),
                              blurRadius: 10,
                            ),
                          ],
                          gradient: LinearGradient(
                            begin: Alignment.topLeft,
                            end: Alignment.bottomRight,
                            colors: [iconBgTop, iconBgBottom],
                          ),
                        ),
                        child: Icon(mainIcon, color: iconColor, size: 60),
                      ),

                const SizedBox(height: 40),

                // Price Card
                Container(
                  margin: const EdgeInsets.symmetric(horizontal: 40),
                  padding: const EdgeInsets.symmetric(
                    vertical: 30,
                    horizontal: 20,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.white.withOpacity(0.2),
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(color: Colors.white.withOpacity(0.3)),
                  ),
                  child: Column(
                    children: [
                      Text(
                        priceLabel,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(height: 10),
                      Text(
                        widget.price,
                        style: TextStyle(
                          color: priceColor,
                          fontSize: 48,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ],
                  ),
                ),

                const SizedBox(height: 30),

                // Bottom Message (Welcome or Balance)
                Text(
                  widget.message,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 20,
                    fontWeight: FontWeight.bold,
                  ),
                ),

                const Spacer(flex: 2),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildCheckeredFlag() {
    return Container(
      width: 100,
      height: 60,
      decoration: BoxDecoration(
        color: Colors.white,
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.2),
            offset: const Offset(0, 5),
            blurRadius: 10,
          ),
        ],
      ),
      child: GridView.builder(
        physics: const NeverScrollableScrollPhysics(),
        itemCount: 24, // 6x4 grid
        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: 6,
        ),
        itemBuilder: (context, index) {
          // Checkerboard pattern logic
          final row = index ~/ 6;
          final col = index % 6;
          final isBlack = (row + col) % 2 == 1;
          return Container(color: isBlack ? Colors.black : Colors.white);
        },
      ),
    );
  }
}
