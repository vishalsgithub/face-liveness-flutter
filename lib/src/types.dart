import 'dart:ui';

/// Pixel layout of raw image bytes passed to `FaceLiveness.detectInPixels`.
enum LivenessPixelFormat {
  rgb(0),
  bgr(1),
  rgba(2),
  bgra(3),

  /// Contiguous Y plane followed by interleaved VU (Android camera default).
  nv21(4),

  /// Contiguous Y plane followed by interleaved UV.
  nv12(5);

  const LivenessPixelFormat(this.code);
  final int code;
}

/// EXIF orientation describing how to turn the pixels into an upright image.
enum LivenessImageOrientation {
  up(1),
  upMirrored(2),
  down(3),
  downMirrored(4),
  leftMirrored(5),

  /// Pixels must be rotated 90° clockwise to be upright.
  right(6),
  rightMirrored(7),

  /// Pixels must be rotated 90° counter-clockwise to be upright.
  left(8);

  const LivenessImageOrientation(this.exif);
  final int exif;

  /// Orientation for pixels that must be rotated clockwise by [degrees] (0, 90, 180, 270).
  static LivenessImageOrientation fromRotation(int degrees) {
    switch (((degrees % 360) + 360) % 360) {
      case 90:
        return LivenessImageOrientation.right;
      case 180:
        return LivenessImageOrientation.down;
      case 270:
        return LivenessImageOrientation.left;
      default:
        return LivenessImageOrientation.up;
    }
  }
}

/// A detected face and its liveness result.
class LivenessFace {
  const LivenessFace({
    required this.bounds,
    required this.detectionConfidence,
    required this.livenessScore,
    required this.isLive,
  });

  /// Face bounds in pixels of the upright image.
  final Rect bounds;

  /// Face detector confidence in [0, 1].
  final double detectionConfidence;

  /// Probability that the face is real (not a photo, screen or mask) in [0, 1].
  final double livenessScore;

  /// `livenessScore >= livenessThreshold` at detection time.
  final bool isLive;

  @override
  String toString() =>
      'LivenessFace(bounds: $bounds, detection: ${detectionConfidence.toStringAsFixed(3)}, '
      'liveness: ${livenessScore.toStringAsFixed(4)}, isLive: $isLive)';
}

/// Thrown when the native engine reports an error.
class FaceLivenessException implements Exception {
  const FaceLivenessException(this.code, this.message);

  final int code;
  final String message;

  static FaceLivenessException fromCode(int code) {
    switch (code) {
      case -100:
        return FaceLivenessException(code, 'Models are not loaded.');
      case -101:
        return FaceLivenessException(code, 'Invalid image.');
      case -102:
        return FaceLivenessException(code, 'Invalid liveness model config.');
      case -103:
        return FaceLivenessException(
            code, 'Failed to load the face detection model.');
      case -104:
        return FaceLivenessException(
            code, 'Failed to load the liveness models.');
      default:
        return FaceLivenessException(code, 'Engine error $code.');
    }
  }

  @override
  String toString() => 'FaceLivenessException($code): $message';
}
