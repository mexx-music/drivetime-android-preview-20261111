import 'dart:typed_data';

import 'package:driverroute_eta/services/tour_image_export.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Grafikexport nutzt für normale Touren doppelte Auflösung', () {
    expect(
      TourImageExport.recommendedPixelRatio(const Size(600, 3000)),
      2,
    );
  });

  test('Grafikexport begrenzt sehr lange Touren auf sichere Bildgrößen', () {
    final ratio = TourImageExport.recommendedPixelRatio(const Size(600, 12000));

    expect(ratio, lessThan(1));
    expect(12000 * ratio, lessThanOrEqualTo(8000));
  });

  testWidgets('Geteilte Grafik hat auch auf dem Handy eine feste Breite',
      (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final boundaryKey = GlobalKey();
    late BuildContext exportContext;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Builder(builder: (context) {
          exportContext = context;
          return RepaintBoundary(
            key: boundaryKey,
            child: const SizedBox(width: 100, height: 100),
          );
        }),
      ),
    ));

    final png = await tester.runAsync(
      () => TourImageExport.captureForSharing(
        context: exportContext,
        graphic: const ColoredBox(
          color: Colors.green,
          child: SizedBox(height: 300),
        ),
        estimatedEvents: 0,
        fallbackBoundaryKey: boundaryKey,
      ),
    );

    expect(png, isNotNull);
    expect(png!.sublist(1, 4), [80, 78, 71]);
    expect(ByteData.sublistView(png).getUint32(16), 1200);
  });
}
