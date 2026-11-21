import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('v69 adaptive foreground mark stays inside the safe zone',
      () async {
    final bytes = await File(
            'android/app/src/main/res/mipmap-xxxhdpi/ic_launcher_foreground.png')
        .readAsBytes();
    final codec = await ui.instantiateImageCodec(bytes);
    final frame = await codec.getNextFrame();
    final image = frame.image;
    final data =
        await image.toByteData(format: ui.ImageByteFormat.rawRgba);
    final pixels = data!.buffer.asUint8List();
    final w = image.width;
    final h = image.height;
    var minX = w, maxX = -1, minY = h, maxY = -1;
    for (var y = 0; y < h; y++) {
      for (var x = 0; x < w; x++) {
        final a = pixels[(y * w + x) * 4 + 3];
        if (a > 128) {
          if (x < minX) minX = x;
          if (x > maxX) maxX = x;
          if (y < minY) minY = y;
          if (y > maxY) maxY = y;
        }
      }
    }
    // v61 drew the mark filling the whole 66dp safe zone (19%-79%
    // of the canvas). His HiOS launcher scales the safe zone to
    // fill the tile, so the mark landed at 1%-97% of the tile and
    // the mask corners cut the Z tail and the dot. v69 draws it at
    // ~26%-73%, which displays at ~12%-88% with padding all round.
    expect(minX / w, greaterThanOrEqualTo(0.24));
    expect(maxX / w, lessThanOrEqualTo(0.76));
    expect(minY / h, greaterThanOrEqualTo(0.24));
    expect(maxY / h, lessThanOrEqualTo(0.76));
  });
}
