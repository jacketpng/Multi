import 'dart:math' as math;

import 'package:flutter/material.dart';

/// The app mark, drawn rather than shipped as an image so it stays
/// sharp at any size and takes its colour from the theme.
///
/// It is a multitool: two handles splayed into the stems of an M, with
/// a blade and a cap lifter swung out of them to meet in the middle as
/// the V. Nothing floats — every stroke turns about a pin a real
/// multitool would have, which is the whole constraint the shape is
/// built around.
class MultiLogo extends StatelessWidget {
  final double size;

  /// The mark itself. One colour, throughout.
  final Color color;

  /// What shows through between overlapping parts. This has to be
  /// whatever the mark is sitting on, because the gaps are how the
  /// tools read as separate objects without any shading.
  final Color gap;

  const MultiLogo({
    super.key,
    required this.size,
    required this.color,
    required this.gap,
  });

  @override
  Widget build(BuildContext context) => SizedBox(
        width: size,
        height: size,
        child: CustomPaint(painter: _MultiLogoPainter(color, gap)),
      );
}

class _MultiLogoPainter extends CustomPainter {
  final Color color;
  final Color gap;
  _MultiLogoPainter(this.color, this.gap);

  // The drawing is laid out on a 128x128 grid and scaled to fit, so
  // these numbers match packaging/multi.svg exactly.
  static const _grid = 128.0;
  static const _leftPin = Offset(33, 29);
  static const _rightPin = Offset(95, 29);
  static const _splay = 10.6; // degrees the handles lean apart
  static const _swing = 22.5; // degrees the tools are swung inward

  static double _rad(double degrees) => degrees * math.pi / 180;

  /// A knife blade: straight spine, curved belly, point at the end.
  static final Path _blade = Path()
    ..moveTo(-8, 0)
    ..lineTo(8, 0)
    ..lineTo(8, 57)
    ..cubicTo(7.8, 68, 5.4, 77, 0.8, 83)
    ..cubicTo(-3, 74, -8, 64, -8, 53)
    ..close();

  /// A cap lifter: the notch is up the shaft, where the real one is.
  static final Path _capLifter = Path()
    ..moveTo(-7.5, 0)
    ..lineTo(7.5, 0)
    ..lineTo(7.5, 33)
    ..lineTo(1.8, 33)
    ..lineTo(1.8, 48)
    ..lineTo(7.5, 48)
    ..lineTo(6.5, 64)
    ..lineTo(3, 79)
    ..lineTo(-3, 79)
    ..lineTo(-6, 54)
    ..close();

  static final Path _handle = Path()
    ..addRRect(RRect.fromRectAndRadius(
        const Rect.fromLTWH(-11.5, -11.5, 23, 90), const Radius.circular(11.5)));

  @override
  void paint(Canvas canvas, Size size) {
    final fill = Paint()..color = color;
    final separator = Paint()
      ..color = gap
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.8
      ..strokeJoin = StrokeJoin.round;
    final cut = Paint()..color = gap;

    canvas.save();
    canvas.scale(size.shortestSide / _grid);

    void part(Offset pin, double degrees, Path path) {
      canvas.save();
      canvas.translate(pin.dx, pin.dy);
      canvas.rotate(_rad(degrees));
      // The tang is a disc around the pin; the handle covers it later,
      // exactly as it does on the real thing.
      canvas.drawCircle(Offset.zero, 8.5, fill);
      canvas.drawCircle(Offset.zero, 8.5, separator);
      canvas.drawPath(path, fill);
      canvas.drawPath(path, separator);
      canvas.restore();
    }

    part(_rightPin, _swing, _capLifter);
    part(_leftPin, -_swing, _blade);
    part(_leftPin, _splay, _handle);
    part(_rightPin, -_splay, _handle);

    // Pins and the rivets at the far end of each handle.
    canvas.drawCircle(_leftPin, 4.2, cut);
    canvas.drawCircle(_rightPin, 4.2, cut);
    for (final (pin, degrees) in [(_leftPin, _splay), (_rightPin, -_splay)]) {
      canvas.save();
      canvas.translate(pin.dx, pin.dy);
      canvas.rotate(_rad(degrees));
      canvas.drawCircle(const Offset(0, 70.8), 3.4, cut);
      canvas.restore();
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(_MultiLogoPainter old) =>
      old.color != color || old.gap != gap;
}
