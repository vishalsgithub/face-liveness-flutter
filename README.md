# face_liveness

[![pub package](https://img.shields.io/pub/v/face_liveness.svg)](https://pub.dev/packages/face_liveness)

On-device **face liveness (anti-spoofing) detection** for Flutter. It checks whether the face in front of the camera is real or a presentation attack (printed photo, screen replay, mask) from ordinary camera frames. The user doesn't have to blink or turn their head, and nothing leaves the device.

- Android and iOS
- `FaceLivenessCamera`: a ready-made front-camera widget with a live verdict
- `FaceLiveness`: an engine for photos, files, raw pixels and camera frames
- Calls native code directly through `dart:ffi`, with no method channels
- Inference runs on a background isolate, so the UI never stutters
- Models are included (about 5.5 MB)

## Installation

```sh
flutter pub add face_liveness
```

or add it to `pubspec.yaml`:

```yaml
dependencies:
  face_liveness: ^1.0.0
```

**iOS:** add the camera permission text to `ios/Runner/Info.plist`:

```xml
<key>NSCameraUsageDescription</key>
<string>The camera is used to check that a real person is in front of the device.</string>
```

**Android:** nothing to add. The camera permission is merged from the `camera` plugin and requested at runtime. The first Android build downloads the prebuilt ncnn engine (about 21 MB) into `~/.face_liveness`; set `FACE_LIVENESS_NCNN_DIR` to use another folder.

The minimum versions are iOS 13 and Android API 24.

## Usage

### Camera widget

```dart
import 'package:face_liveness/face_liveness.dart';

FaceLivenessCamera(
  onVerified: (result) {
    // A real face was seen for 8 consecutive frames.
    print('Real face, score ${result.face!.livenessScore}');
  },
  onResult: (result) {
    // Every processed frame: result.face is null when no face is visible.
  },
  onError: (error) => print(error),   // e.g. camera permission denied
)
```

| Parameter | Default | Meaning |
| --- | --- | --- |
| `livenessThreshold` | `0.915` | Minimum score for a face to count as live |
| `requiredLiveFrames` | `8` | Consecutive live frames before `onVerified` is called |
| `lensDirection` | `front` | Which camera to use |
| `resolution` | `medium` | Camera resolution. Higher resolution doesn't improve accuracy. |
| `showFaceOverlay` | `true` | Draw a green or red box around the face |
| `engine` | `null` | Share an existing `FaceLiveness` instead of creating one |

### Photos and frames

```dart
final liveness = await FaceLiveness.create();

final faces = await liveness.detectInFile(path);   // or detectInImageBytes(jpegBytes)
if (faces.isNotEmpty) {
  final face = faces.first;                        // largest face
  print('${face.isLive} ${face.livenessScore} ${face.bounds}');
}

await liveness.dispose();
```

Other entry points:

- `detectInPixels(bytes, width:, height:, format:, orientation:)` for raw RGBA/BGRA/RGB/BGR/NV21/NV12 pixels
- `detectInCameraImage(cameraImage, rotationDegrees:)` for frames from your own `CameraController`

Face `bounds` are in pixels of the upright image. Pass `allFaces: true` to evaluate every face instead of only the largest.

A single frame is noisy. For a verification flow, require several consecutive live frames, as `FaceLivenessCamera` does with `requiredLiveFrames`.

## How it works

1. **Face detection**: an SSD-style detector finds faces in a 192 px version of the frame.
2. **Liveness**: two MiniFASNet models look at the face at 2.7× and 4.0× context (resized to 80×80). Each outputs a "real face" probability, and the two are averaged.

The C++ engine runs on [ncnn](https://github.com/Tencent/ncnn), and Dart calls it through `dart:ffi` on a background isolate.

## Related packages

- iOS (Swift Package Manager): [vishalsgithub/face-liveness](https://github.com/vishalsgithub/face-liveness)

## License

Apache-2.0. See [LICENSE](LICENSE). ncnn is distributed under BSD-3-Clause.
