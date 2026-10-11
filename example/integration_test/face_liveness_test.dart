// Runs the real native engine on a device or simulator:
//   flutter test integration_test

import 'dart:ui' as ui;

import 'package:face_liveness/face_liveness.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  late FaceLiveness engine;
  late Uint8List jpeg;

  setUpAll(() async {
    engine = await FaceLiveness.create();
    final data = await rootBundle.load('assets/face.jpeg');
    jpeg = data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
  });

  tearDownAll(() => engine.dispose());

  Future<(Uint8List, int, int)> decodeRgba() async {
    final codec = await ui.instantiateImageCodec(jpeg);
    final image = (await codec.getNextFrame()).image;
    final data = (await image.toByteData(format: ui.ImageByteFormat.rawRgba))!;
    return (data.buffer.asUint8List(), image.width, image.height);
  }

  testWidgets('detects a live face in the sample photo', (tester) async {
    final faces = await engine.detectInImageBytes(jpeg);
    expect(faces, hasLength(1));
    expect(faces.first.detectionConfidence, greaterThan(0.9));
    expect(faces.first.livenessScore, greaterThan(0.9));
    expect(faces.first.isLive, isTrue);
    expect(faces.first.bounds.width, greaterThan(300));
  });

  testWidgets('orientation is undone for rotated pixels', (tester) async {
    final (rgba, w, h) = await decodeRgba();
    final upright = (await engine.detectInPixels(rgba, width: w, height: h)).first;

    // Rotate the pixels 90° counter-clockwise; orientation `right` turns them back.
    final rotated = Uint8List(rgba.length);
    for (var y = 0; y < h; y++) {
      for (var x = 0; x < w; x++) {
        final src = (y * w + x) * 4;
        final dst = ((w - 1 - x) * h + y) * 4;
        rotated.setRange(dst, dst + 4, rgba, src);
      }
    }
    final face = (await engine.detectInPixels(rotated,
            width: h, height: w, orientation: LivenessImageOrientation.right))
        .first;
    expect(face.bounds.left, closeTo(upright.bounds.left, 4));
    expect(face.bounds.top, closeTo(upright.bounds.top, 4));
    expect(face.livenessScore, closeTo(upright.livenessScore, 0.05));
  });

  testWidgets('NV21 frames give the same face', (tester) async {
    final (rgba, w, h) = await decodeRgba();
    final evenW = w & ~1, evenH = h & ~1;
    // Encode RGBA -> NV21 (BT.601) to exercise the camera code path.
    final nv21 = Uint8List(evenW * evenH * 3 ~/ 2);
    for (var y = 0; y < evenH; y++) {
      for (var x = 0; x < evenW; x++) {
        final i = (y * w + x) * 4;
        final r = rgba[i], g = rgba[i + 1], b = rgba[i + 2];
        nv21[y * evenW + x] = ((66 * r + 129 * g + 25 * b + 128) >> 8) + 16;
        if (y.isEven && x.isEven) {
          final o = evenW * evenH + (y ~/ 2) * evenW + x;
          nv21[o] = ((112 * r - 94 * g - 18 * b + 128) >> 8) + 128;
          nv21[o + 1] = ((-38 * r - 74 * g + 112 * b + 128) >> 8) + 128;
        }
      }
    }
    final upright = (await engine.detectInImageBytes(jpeg)).first;
    final face = (await engine.detectInPixels(nv21,
            width: evenW, height: evenH, format: LivenessPixelFormat.nv21))
        .first;
    expect(face.bounds.left, closeTo(upright.bounds.left, 6));
    expect(face.livenessScore, greaterThan(0.85));
  });

  testWidgets('blank image has no face', (tester) async {
    final gray = Uint8List(320 * 240 * 4)..fillRange(0, 320 * 240 * 4, 128);
    expect(await engine.detectInPixels(gray, width: 320, height: 240), isEmpty);
  });

  testWidgets('threshold controls the verdict', (tester) async {
    engine.livenessThreshold = 0.999;
    expect((await engine.detectInImageBytes(jpeg)).first.isLive, isFalse);
    engine.livenessThreshold = 0.5;
    expect((await engine.detectInImageBytes(jpeg)).first.isLive, isTrue);
    engine.livenessThreshold = FaceLiveness.defaultLivenessThreshold;
  });

  testWidgets('invalid image throws', (tester) async {
    expect(
      engine.detectInPixels(Uint8List(10), width: 0, height: 0),
      throwsA(isA<FaceLivenessException>()),
    );
  });
}
