import 'dart:async';

import 'package:flutter/material.dart';

import 'models/gps_data_model.dart';

class SystemChecklistScreen extends StatefulWidget {
  final String routeLabel;
  final String busLabel;
  final bool internetReady;
  final bool initialGpsReady;
  final bool tripReady;
  final bool readerReady;
  final bool audioReady;
  final String tripStatusLabel;
  final Stream<GpsData>? gpsStream;

  const SystemChecklistScreen({
    super.key,
    required this.routeLabel,
    required this.busLabel,
    required this.internetReady,
    required this.initialGpsReady,
    required this.tripReady,
    required this.readerReady,
    required this.audioReady,
    required this.tripStatusLabel,
    this.gpsStream,
  });

  @override
  State<SystemChecklistScreen> createState() => _SystemChecklistScreenState();
}

class _SystemChecklistScreenState extends State<SystemChecklistScreen> {
  static const Color _backgroundColor = Color(0xFF171819);
  static const Color _panelColor = Color(0xFF2B2C2F);
  static const Color _rowColor = Color(0xFF353638);
  static const Color _readyColor = Color(0xFF45D47A);
  static const Color _errorColor = Color(0xFFFF5B6E);

  late bool _gpsReady;
  StreamSubscription<GpsData>? _gpsSubscription;

  @override
  void initState() {
    super.initState();
    _gpsReady = widget.initialGpsReady;
    _gpsSubscription = widget.gpsStream?.listen((gps) {
      if (!_gpsReady && _isValidGps(gps) && mounted) {
        setState(() => _gpsReady = true);
      }
    });
  }

  @override
  void dispose() {
    _gpsSubscription?.cancel();
    super.dispose();
  }

  bool get _allReady =>
      widget.internetReady &&
      _gpsReady &&
      widget.tripReady &&
      widget.readerReady &&
      widget.audioReady;

  bool _isValidGps(GpsData gps) => gps.lat != 0 && gps.lng != 0;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _backgroundColor,
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(12),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: Container(
                decoration: BoxDecoration(
                  color: _panelColor,
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: const Color(0xFF424347)),
                  boxShadow: const [
                    BoxShadow(
                      color: Color(0x66000000),
                      blurRadius: 20,
                      offset: Offset(0, 10),
                    ),
                  ],
                ),
                clipBehavior: Clip.antiAlias,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _buildHeader(context),
                    const Divider(height: 1, color: Color(0xFF45464A)),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(21, 20, 21, 20),
                      child: Column(
                        children: [
                          _buildStatusTile(
                            icon: Icons.signal_cellular_alt_rounded,
                            iconColor: const Color(0xFF6FA6FF),
                            title: 'สัญญาณ Internet (5G)',
                            ready: widget.internetReady,
                            readyText: 'ปกติ',
                            errorText: 'ผิดปกติ',
                          ),
                          const SizedBox(height: 15),
                          _buildStatusTile(
                            icon: Icons.location_on_rounded,
                            iconColor: const Color(0xFFFF4B95),
                            title: 'พิกัดตำแหน่ง\n(GPS)',
                            ready: _gpsReady,
                            readyText: 'ปกติ',
                            errorText: 'ไม่พบ\nสัญญาณ',
                          ),
                          const SizedBox(height: 15),
                          _buildStatusTile(
                            icon: Icons.calendar_month_rounded,
                            iconColor: const Color(0xFF7C9DFF),
                            title: 'สถานะเที่ยวรถ (${widget.tripStatusLabel})',
                            ready: widget.tripReady,
                            readyText: 'พร้อม',
                            errorText: 'ไม่พร้อม',
                          ),
                          const SizedBox(height: 15),
                          _buildStatusTile(
                            icon: Icons.credit_card_rounded,
                            iconColor: const Color(0xFF43C0E8),
                            title: 'เครื่องอ่านบัตร / QR',
                            ready: widget.readerReady,
                            readyText: 'พร้อม',
                            errorText: 'ไม่พร้อม',
                          ),
                          const SizedBox(height: 15),
                          _buildStatusTile(
                            icon: Icons.volume_up_rounded,
                            iconColor: const Color(0xFFFFC34D),
                            title: 'ระบบเสียง (Audio)',
                            ready: widget.audioReady,
                            readyText: 'พร้อม',
                            errorText: 'ไม่พร้อม',
                          ),
                          const SizedBox(height: 26),
                          _buildSystemMessage(),
                          const SizedBox(height: 20),
                          SizedBox(
                            width: double.infinity,
                            height: 52,
                            child: ElevatedButton(
                              onPressed: _allReady
                                  ? () {
                                      ScaffoldMessenger.of(context)
                                          .showSnackBar(
                                        const SnackBar(
                                          content:
                                              Text('ระบบพร้อมเริ่มเดินรถแล้ว'),
                                          duration: Duration(seconds: 2),
                                        ),
                                      );
                                    }
                                  : null,
                              style: ElevatedButton.styleFrom(
                                backgroundColor: _allReady
                                    ? _readyColor
                                    : const Color(0xFF5E6064),
                                disabledBackgroundColor:
                                    const Color(0xFF5E6064),
                                foregroundColor: Colors.white,
                                disabledForegroundColor:
                                    const Color(0xFFB4B5B8),
                                elevation: 0,
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(8),
                                ),
                              ),
                              child: const Text(
                                'เริ่มเดินรถ',
                                style: TextStyle(
                                  fontSize: 16,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildHeader(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 17, 12, 18),
      child: Row(
        children: [
          SizedBox(
            width: 40,
            child: IconButton(
              onPressed: () => Navigator.of(context).pop(),
              icon: const Icon(Icons.arrow_back_ios_new_rounded),
              color: Colors.white,
              iconSize: 20,
              splashRadius: 20,
              tooltip: 'กลับ',
            ),
          ),
          Expanded(
            child: Column(
              children: [
                const Text(
                  'ตรวจสอบความพร้อม ระบบ',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 18,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 1.2,
                  ),
                ),
                const SizedBox(height: 7),
                Text(
                  'สายรถ: ${widget.routeLabel} | รถเมล์: ${widget.busLabel}',
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    color: Color(0xFFC7C8CD),
                    fontSize: 13,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 40),
        ],
      ),
    );
  }

  Widget _buildStatusTile({
    required IconData icon,
    required Color iconColor,
    required String title,
    required bool ready,
    required String readyText,
    required String errorText,
  }) {
    final statusColor = ready ? _readyColor : _errorColor;
    final statusText = ready ? readyText : errorText;

    return Container(
      constraints: const BoxConstraints(minHeight: 46),
      decoration: BoxDecoration(
        color: _rowColor,
        borderRadius: BorderRadius.circular(8),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 10),
      child: Row(
        children: [
          SizedBox(
            width: 28,
            child: Icon(icon, color: iconColor, size: 22),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              title,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 16,
                height: 1.08,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          const SizedBox(width: 12),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 15,
                height: 15,
                decoration: BoxDecoration(
                  color: statusColor,
                  shape: BoxShape.circle,
                  boxShadow: [
                    BoxShadow(
                      color: statusColor.withOpacity(0.45),
                      blurRadius: 8,
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              SizedBox(
                width: 54,
                child: Text(
                  statusText,
                  textAlign: TextAlign.left,
                  style: TextStyle(
                    color: statusColor,
                    fontSize: 15,
                    height: 1.05,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildSystemMessage() {
    if (_allReady) {
      return Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 13),
        decoration: BoxDecoration(
          color: _readyColor.withOpacity(0.08),
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: _readyColor),
        ),
        child: const Text(
          'ระบบพร้อมปฏิบัติงาน\nสามารถเริ่มเดินรถได้',
          textAlign: TextAlign.center,
          style: TextStyle(
            color: _readyColor,
            fontSize: 13,
            height: 1.35,
            fontWeight: FontWeight.w700,
          ),
        ),
      );
    }

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 13),
      decoration: BoxDecoration(
        color: _errorColor.withOpacity(0.05),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: _errorColor),
      ),
      child: const Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                Icons.warning_amber_rounded,
                color: _errorColor,
                size: 18,
              ),
              SizedBox(width: 4),
              Text(
                'ระบบไม่พร้อมปฏิบัติงาน',
                style: TextStyle(
                  color: _errorColor,
                  fontSize: 13,
                  height: 1.35,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
          SizedBox(height: 3),
          Text(
            'กรุณาเคลื่อนรถไปในที่โล่งเพื่อรับสัญญาณ GPS',
            textAlign: TextAlign.center,
            style: TextStyle(
              color: _errorColor,
              fontSize: 13,
              height: 1.35,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }
}
