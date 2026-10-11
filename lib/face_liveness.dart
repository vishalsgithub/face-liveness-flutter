/// On-device face liveness (anti-spoofing) detection for Flutter.
///
/// Runs on ncnn and is called directly from Dart through `dart:ffi`
/// (no platform channels).
library;

export 'package:camera/camera.dart' show CameraLensDirection, ResolutionPreset;

export 'src/face_liveness_camera.dart' show FaceLivenessCamera, LivenessResult;
export 'src/face_liveness_engine.dart' show FaceLiveness;
export 'src/types.dart';
