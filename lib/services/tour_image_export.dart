import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:screenshot/screenshot.dart';

class TourImageExport {
  static const double shareWidth = 600;
  static const double _maxDimension = 8000;
  static const double _maxPixels = 12000000;

  static Future<Uint8List> captureForSharing({
    required BuildContext context,
    required Widget graphic,
    required int estimatedEvents,
    required GlobalKey fallbackBoundaryKey,
  }) async {
    try {
      final estimatedHeight = 760.0 + estimatedEvents * 95.0;
      final pixelRatio = recommendedPixelRatio(
        Size(shareWidth, estimatedHeight),
      );
      return await ScreenshotController().captureFromLongWidget(
        InheritedTheme.captureAll(
          context,
          MediaQuery(
            data: MediaQuery.of(context),
            child: SizedBox(
              width: shareWidth,
              child: graphic,
            ),
          ),
        ),
        context: context,
        delay: const Duration(milliseconds: 50),
        pixelRatio: pixelRatio,
        constraints: const BoxConstraints(
          minWidth: shareWidth,
          maxWidth: shareWidth,
        ),
      );
    } catch (error, stackTrace) {
      assert(() {
        debugPrint('Offscreen-Tourgrafik fehlgeschlagen: $error');
        debugPrintStack(stackTrace: stackTrace);
        return true;
      }());
      return capture(fallbackBoundaryKey);
    }
  }

  static Future<Uint8List> capture(GlobalKey boundaryKey) async {
    final renderObject = boundaryKey.currentContext?.findRenderObject();
    if (renderObject is! RenderRepaintBoundary) {
      throw StateError('Die Tourgrafik ist noch nicht bereit.');
    }
    if (renderObject.size.isEmpty) {
      throw StateError('Die Tourgrafik hat keine gültige Größe.');
    }

    final pixelRatio = recommendedPixelRatio(renderObject.size);

    final image = await renderObject.toImage(pixelRatio: pixelRatio);
    try {
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      if (data == null) {
        throw StateError('Die Tourgrafik konnte nicht erzeugt werden.');
      }
      return data.buffer.asUint8List();
    } finally {
      image.dispose();
    }
  }

  static double recommendedPixelRatio(Size size) {
    if (size.isEmpty) return 1;
    final width = size.width;
    final height = size.height;
    var pixelRatio = 2.0;
    pixelRatio = math.min(pixelRatio, _maxDimension / width);
    pixelRatio = math.min(pixelRatio, _maxDimension / height);
    pixelRatio = math.min(
      pixelRatio,
      math.sqrt(_maxPixels / (width * height)),
    );
    return pixelRatio;
  }
}
