import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

class ReceiptImageField {
  final String label;
  final String value;
  final bool highlight;

  const ReceiptImageField({
    required this.label,
    required this.value,
    this.highlight = false,
  });
}

class ReceiptImageService {
  static const double _canvasWidth = 384;
  static const double _horizontalPadding = 24;
  static const double _sectionGap = 14;
  static const double _lineGap = 10;
  static const double _cardInset = 16;
  static const double _logoWidth = 80;

  static Future<Uint8List> buildReceiptImage({
    required String logoAssetPath,
    required String title,
    required String statusText,
    required String timestampText,
    required String sectionTitle,
    required List<ReceiptImageField> fields,
    required String totalLabel,
    required String totalValue,
    required String paymentMethod,
    required String discountText,
    required String transactionNo,
    required String footerText,
  }) async {
    final logoBytes = await rootBundle.load(logoAssetPath);
    final logoCodec = await ui.instantiateImageCodec(
      logoBytes.buffer.asUint8List(),
      targetWidth: _logoWidth.toInt(),
    );
    final logoFrame = await logoCodec.getNextFrame();
    final logoImage = logoFrame.image;

    final titleStyle = _textStyle(
      fontSize: 30,
      fontWeight: FontWeight.w800,
      color: const Color(0xFF202124),
    );
    final statusStyle = _textStyle(
      fontSize: 26,
      fontWeight: FontWeight.w700,
      color: const Color(0xFF202124),
    );
    final timestampStyle = _textStyle(
      fontSize: 20,
      fontWeight: FontWeight.w500,
      color: const Color(0xFF5F6368),
    );
    final sectionStyle = _textStyle(
      fontSize: 24,
      fontWeight: FontWeight.w700,
      color: const Color(0xFF202124),
    );
    final labelStyle = _textStyle(
      fontSize: 21,
      fontWeight: FontWeight.w500,
      color: const Color(0xFF5F6368),
    );
    final valueStyle = _textStyle(
      fontSize: 21,
      fontWeight: FontWeight.w700,
      color: const Color(0xFF202124),
    );
    final totalLabelStyle = _textStyle(
      fontSize: 25,
      fontWeight: FontWeight.w800,
      color: const Color(0xFF202124),
    );
    final totalValueStyle = _textStyle(
      fontSize: 28,
      fontWeight: FontWeight.w800,
      color: const Color(0xFF202124),
    );
    final footerStyle = _textStyle(
      fontSize: 20,
      fontWeight: FontWeight.w600,
      color: const Color(0xFF5F6368),
    );

    final contentWidth = _canvasWidth - (_horizontalPadding * 2);
    final valueColumnWidth = 178.0;
    final labelColumnWidth = contentWidth - valueColumnWidth - 8;

    final titlePainter = _layoutCentered(title, titleStyle, contentWidth);
    final statusPainter =
        _layoutCentered(statusText, statusStyle, contentWidth - _logoWidth - 16);
    final timestampPainter =
        _layoutCentered(timestampText, timestampStyle, contentWidth - _logoWidth - 16);
    final sectionPainter =
        _layoutLeft(sectionTitle, sectionStyle, contentWidth);
    final footerPainter = _layoutCentered(footerText, footerStyle, contentWidth);
    final methodPainter = _layoutField(
      label: 'ช่องทางการชำระเงิน',
      value: paymentMethod,
      labelStyle: labelStyle,
      valueStyle: valueStyle,
      labelWidth: labelColumnWidth,
      valueWidth: valueColumnWidth,
    );
    final discountPainter = _layoutField(
      label: 'สิทธิลดหย่อน',
      value: discountText,
      labelStyle: labelStyle,
      valueStyle: valueStyle,
      labelWidth: labelColumnWidth,
      valueWidth: valueColumnWidth,
    );
    final txnPainter = _layoutField(
      label: 'เลขที่ทำรายการ',
      value: transactionNo,
      labelStyle: labelStyle,
      valueStyle: valueStyle,
      labelWidth: labelColumnWidth,
      valueWidth: valueColumnWidth,
    );
    final totalPainter = _layoutField(
      label: totalLabel,
      value: totalValue,
      labelStyle: totalLabelStyle,
      valueStyle: totalValueStyle,
      labelWidth: labelColumnWidth,
      valueWidth: valueColumnWidth,
    );

    final fieldLayouts = fields
        .map(
          (field) => _layoutField(
            label: field.label,
            value: field.value,
            labelStyle: labelStyle,
            valueStyle: field.highlight ? totalValueStyle : valueStyle,
            labelWidth: labelColumnWidth,
            valueWidth: valueColumnWidth,
          ),
        )
        .toList();

    double y = _horizontalPadding;
    y += titlePainter.height;
    y += 18;
    final statusBlockHeight =
        statusPainter.height + 8 + timestampPainter.height;
    y += statusBlockHeight > logoImage.height
        ? statusBlockHeight
        : logoImage.height.toDouble();
    y += _sectionGap;
    y += 1;
    y += _sectionGap;
    y += sectionPainter.height;
    y += _sectionGap;
    y += 1;
    y += _sectionGap;
    for (final field in fieldLayouts) {
      y += field.height + _lineGap;
    }
    y += 1;
    y += _sectionGap;
    y += totalPainter.height;
    y += _sectionGap;
    y += 1;
    y += _sectionGap;
    y += methodPainter.height + _lineGap;
    y += discountPainter.height + _lineGap;
    y += txnPainter.height + _lineGap;
    y += _sectionGap;
    y += footerPainter.height;
    y += _horizontalPadding;

    final recorder = ui.PictureRecorder();
    final canvas = Canvas(
      recorder,
      Rect.fromLTWH(0, 0, _canvasWidth, y),
    );

    final whitePaint = Paint()..color = Colors.white;
    canvas.drawRect(Rect.fromLTWH(0, 0, _canvasWidth, y), whitePaint);

    final cardPaint = Paint()..color = const Color(0xFFF8F9FA);
    final cardRect = RRect.fromRectAndRadius(
      Rect.fromLTWH(
        _cardInset,
        _cardInset,
        _canvasWidth - (_cardInset * 2),
        y - (_cardInset * 2),
      ),
      const Radius.circular(18),
    );
    canvas.drawRRect(cardRect, cardPaint);

    double drawY = _horizontalPadding;
    _paintCentered(canvas, titlePainter, drawY, contentWidth);
    drawY += titlePainter.height + 18;

    final statusBlockTop = drawY;
    final statusX = _horizontalPadding;
    statusPainter.paint(canvas, Offset(statusX, statusBlockTop));
    timestampPainter.paint(
      canvas,
      Offset(statusX, statusBlockTop + statusPainter.height + 8),
    );

    final logoX = _canvasWidth - _horizontalPadding - logoImage.width.toDouble();
    final logoY = statusBlockTop +
        (((statusBlockHeight > logoImage.height
                    ? statusBlockHeight
                    : logoImage.height.toDouble()) -
                logoImage.height) /
            2);
    canvas.drawImage(logoImage, Offset(logoX, logoY), Paint());

    drawY += statusBlockHeight > logoImage.height
        ? statusBlockHeight
        : logoImage.height.toDouble();
    drawY += _sectionGap;
    _drawDivider(canvas, drawY);
    drawY += _sectionGap;

    sectionPainter.paint(canvas, Offset(_horizontalPadding, drawY));
    drawY += sectionPainter.height + _sectionGap;
    _drawDivider(canvas, drawY);
    drawY += _sectionGap;

    for (final field in fieldLayouts) {
      field.paint(canvas, Offset(_horizontalPadding, drawY));
      drawY += field.height + _lineGap;
    }

    _drawDivider(canvas, drawY);
    drawY += _sectionGap;
    totalPainter.paint(canvas, Offset(_horizontalPadding, drawY));
    drawY += totalPainter.height + _sectionGap;
    _drawDivider(canvas, drawY);
    drawY += _sectionGap;

    methodPainter.paint(canvas, Offset(_horizontalPadding, drawY));
    drawY += methodPainter.height + _lineGap;
    discountPainter.paint(canvas, Offset(_horizontalPadding, drawY));
    drawY += discountPainter.height + _lineGap;
    txnPainter.paint(canvas, Offset(_horizontalPadding, drawY));
    drawY += txnPainter.height + _sectionGap;

    _paintCentered(canvas, footerPainter, drawY, contentWidth);

    final picture = recorder.endRecording();
    final image = await picture.toImage(_canvasWidth.toInt(), y.ceil());
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    return bytes!.buffer.asUint8List();
  }

  static TextStyle _textStyle({
    required double fontSize,
    required FontWeight fontWeight,
    required Color color,
  }) {
    return TextStyle(
      fontSize: fontSize,
      fontWeight: fontWeight,
      color: color,
      height: 1.2,
    );
  }

  static TextPainter _layoutCentered(
    String text,
    TextStyle style,
    double maxWidth,
  ) {
    final painter = TextPainter(
      text: TextSpan(text: text, style: style),
      textDirection: TextDirection.ltr,
      textAlign: TextAlign.center,
      maxLines: null,
    )..layout(maxWidth: maxWidth);
    return painter;
  }

  static TextPainter _layoutLeft(
    String text,
    TextStyle style,
    double maxWidth,
  ) {
    final painter = TextPainter(
      text: TextSpan(text: text, style: style),
      textDirection: TextDirection.ltr,
      textAlign: TextAlign.left,
      maxLines: null,
    )..layout(maxWidth: maxWidth);
    return painter;
  }

  static _FieldLayout _layoutField({
    required String label,
    required String value,
    required TextStyle labelStyle,
    required TextStyle valueStyle,
    required double labelWidth,
    required double valueWidth,
  }) {
    final labelPainter = _layoutLeft('$label :', labelStyle, labelWidth);
    final valuePainter = TextPainter(
      text: TextSpan(text: value, style: valueStyle),
      textDirection: TextDirection.ltr,
      textAlign: TextAlign.right,
      maxLines: null,
    )..layout(maxWidth: valueWidth);

    return _FieldLayout(
      labelPainter: labelPainter,
      valuePainter: valuePainter,
      labelWidth: labelWidth,
      valueWidth: valueWidth,
    );
  }

  static void _paintCentered(
    Canvas canvas,
    TextPainter painter,
    double top,
    double contentWidth,
  ) {
    final left = _horizontalPadding + ((contentWidth - painter.width) / 2);
    painter.paint(canvas, Offset(left, top));
  }

  static void _drawDivider(Canvas canvas, double y) {
    final paint = Paint()
      ..color = const Color(0xFFDADCE0)
      ..strokeWidth = 1;
    canvas.drawLine(
      Offset(_horizontalPadding, y),
      Offset(_canvasWidth - _horizontalPadding, y),
      paint,
    );
  }
}

class _FieldLayout {
  final TextPainter labelPainter;
  final TextPainter valuePainter;
  final double labelWidth;
  final double valueWidth;

  _FieldLayout({
    required this.labelPainter,
    required this.valuePainter,
    required this.labelWidth,
    required this.valueWidth,
  });

  double get height =>
      labelPainter.height > valuePainter.height
          ? labelPainter.height
          : valuePainter.height;

  void paint(Canvas canvas, Offset offset) {
    labelPainter.paint(canvas, offset);
    valuePainter.paint(
      canvas,
      Offset(offset.dx + labelWidth + 8, offset.dy),
    );
  }
}
