import 'dart:async';
import 'dart:io';

import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'face_liveness_engine.dart';
import 'types.dart';

/// Result of one processed camera frame.
class LivenessResult {
  const LivenessResult({
    required this.face,
    required this.imageSize,
    required this.processingTime,
    required this.consecutiveLiveFrames,
    required this.isVerified,
  });

  /// Largest face in the frame, or null when no face was found.
  final LivenessFace? face;

  /// Size of the upright camera frame that [face] bounds refer to.
  final Size imageSize;

  /// Inference time for this frame.
  final Duration processingTime;

  /// Number of consecutive frames (including this one) with a live face.
  final int consecutiveLiveFrames;

  /// True once a face has been live for `requiredLiveFrames` consecutive frames.
  final bool isVerified;
}

/// Front-camera preview that checks every frame for a real face.
///
/// ```dart
/// FaceLivenessCamera(
///   onVerified: (result) => print('Real face: ${result.face!.livenessScore}'),
/// )
/// ```
class FaceLivenessCamera extends StatefulWidget {
  const FaceLivenessCamera({
    super.key,
    this.onResult,
    this.onVerified,
    this.onError,
    this.engine,
    this.livenessThreshold = FaceLiveness.defaultLivenessThreshold,
    this.requiredLiveFrames = 8,
    this.lensDirection = CameraLensDirection.front,
    this.resolution = ResolutionPreset.medium,
    this.showFaceOverlay = true,
    this.liveColor = Colors.greenAccent,
    this.spoofColor = Colors.redAccent,
    this.placeholder,
  });

  /// Called for every processed frame.
  final ValueChanged<LivenessResult>? onResult;

  /// Called once each time a face becomes verified (live for [requiredLiveFrames] frames in a row).
  final ValueChanged<LivenessResult>? onVerified;

  /// Called when the camera or the engine can't be started.
  final ValueChanged<Object>? onError;

  /// Engine to use. When null, the widget creates and disposes its own.
  final FaceLiveness? engine;

  final double livenessThreshold;
  final int requiredLiveFrames;
  final CameraLensDirection lensDirection;
  final ResolutionPreset resolution;
  final bool showFaceOverlay;
  final Color liveColor;
  final Color spoofColor;

  /// Shown while the camera starts. Defaults to a progress indicator.
  final Widget? placeholder;

  @override
  State<FaceLivenessCamera> createState() => _FaceLivenessCameraState();
}

class _FaceLivenessCameraState extends State<FaceLivenessCamera> with WidgetsBindingObserver {
  CameraController? _controller;
  FaceLiveness? _engine;
  bool _ownsEngine = false;
  bool _busy = false;
  bool _starting = false;
  bool _verifiedNotified = false;
  int _consecutiveLive = 0;
  LivenessResult? _last;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _start();
  }

  @override
  void didUpdateWidget(FaceLivenessCamera oldWidget) {
    super.didUpdateWidget(oldWidget);
    _engine?.livenessThreshold = widget.livenessThreshold;
    if (oldWidget.lensDirection != widget.lensDirection || oldWidget.resolution != widget.resolution) {
      _stopCamera().then((_) => _start());
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.inactive || state == AppLifecycleState.paused) {
      _stopCamera();
    } else if (state == AppLifecycleState.resumed && _controller == null) {
      _start();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _stopCamera();
    if (_ownsEngine) _engine?.dispose();
    super.dispose();
  }

  Future<void> _start() async {
    if (_starting || _controller != null) return;
    _starting = true;
    try {
      if (_engine == null) {
        if (widget.engine != null) {
          _engine = widget.engine;
        } else {
          _engine = await FaceLiveness.create(livenessThreshold: widget.livenessThreshold);
          _ownsEngine = true;
        }
      }
      _engine!.livenessThreshold = widget.livenessThreshold;

      final cameras = await availableCameras();
      if (cameras.isEmpty) throw CameraException('NoCamera', 'No camera available.');
      final camera = cameras.firstWhere(
        (c) => c.lensDirection == widget.lensDirection,
        orElse: () => cameras.first,
      );
      final controller = CameraController(
        camera,
        widget.resolution,
        enableAudio: false,
        imageFormatGroup: Platform.isIOS ? ImageFormatGroup.bgra8888 : ImageFormatGroup.yuv420,
      );
      await controller.initialize();
      if (!mounted) {
        await controller.dispose();
        return;
      }
      await controller.startImageStream(_onFrame);
      setState(() => _controller = controller);
    } catch (e) {
      widget.onError?.call(e);
    } finally {
      _starting = false;
    }
  }

  Future<void> _stopCamera() async {
    final controller = _controller;
    _controller = null;
    _consecutiveLive = 0;
    _verifiedNotified = false;
    if (controller == null) return;
    if (mounted) setState(() => _last = null);
    try {
      if (controller.value.isStreamingImages) await controller.stopImageStream();
    } catch (_) {}
    await controller.dispose();
  }

  /// Clockwise rotation that turns a camera frame upright for the current device orientation.
  int _frameRotation(CameraController controller) {
    final sensor = controller.description.sensorOrientation;
    if (Platform.isIOS) {
      // camera_avfoundation streams frames in the sensor's landscape orientation.
      return sensor;
    }
    const degrees = {
      DeviceOrientation.portraitUp: 0,
      DeviceOrientation.landscapeLeft: 90,
      DeviceOrientation.portraitDown: 180,
      DeviceOrientation.landscapeRight: 270,
    };
    final device = degrees[controller.value.deviceOrientation] ?? 0;
    return controller.description.lensDirection == CameraLensDirection.front
        ? (sensor + device) % 360
        : (sensor - device + 360) % 360;
  }

  Future<void> _onFrame(CameraImage image) async {
    final controller = _controller;
    final engine = _engine;
    if (_busy || controller == null || engine == null) return;
    _busy = true;
    try {
      final rotation = _frameRotation(controller);
      final stopwatch = Stopwatch()..start();
      final faces = await engine.detectInCameraImage(image, rotationDegrees: rotation);
      stopwatch.stop();
      if (!mounted || _controller != controller) return;

      final swap = rotation == 90 || rotation == 270;
      final size = swap
          ? Size(image.height.toDouble(), image.width.toDouble())
          : Size(image.width.toDouble(), image.height.toDouble());
      final face = faces.isEmpty ? null : faces.first;

      if (face != null && face.isLive) {
        _consecutiveLive++;
      } else {
        _consecutiveLive = 0;
        _verifiedNotified = false;
      }
      final result = LivenessResult(
        face: face,
        imageSize: size,
        processingTime: stopwatch.elapsed,
        consecutiveLiveFrames: _consecutiveLive,
        isVerified: _consecutiveLive >= widget.requiredLiveFrames,
      );
      setState(() => _last = result);
      widget.onResult?.call(result);
      if (result.isVerified && !_verifiedNotified) {
        _verifiedNotified = true;
        widget.onVerified?.call(result);
      }
    } catch (e) {
      if (kDebugMode) debugPrint('face_liveness: $e');
    } finally {
      _busy = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) {
      return ColoredBox(
        color: Colors.black,
        child: Center(child: widget.placeholder ?? const CircularProgressIndicator()),
      );
    }

    // The preview is upright; lay it out at frame size and cover the available space.
    final previewSize = controller.value.previewSize!;
    final portrait = MediaQuery.orientationOf(context) == Orientation.portrait;
    final width = portrait ? previewSize.height : previewSize.width;
    final height = portrait ? previewSize.width : previewSize.height;
    final mirrored = controller.description.lensDirection == CameraLensDirection.front;

    return ClipRect(
      child: FittedBox(
        fit: BoxFit.cover,
        child: SizedBox(
          width: width,
          height: height,
          child: Stack(
            fit: StackFit.expand,
            children: [
              CameraPreview(controller),
              if (widget.showFaceOverlay && _last?.face != null)
                CustomPaint(
                  painter: _FacePainter(
                    result: _last!,
                    mirrored: mirrored,
                    color: _last!.face!.isLive ? widget.liveColor : widget.spoofColor,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _FacePainter extends CustomPainter {
  _FacePainter({required this.result, required this.mirrored, required this.color});

  final LivenessResult result;
  final bool mirrored;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final face = result.face;
    if (face == null || result.imageSize.isEmpty) return;
    final sx = size.width / result.imageSize.width;
    final sy = size.height / result.imageSize.height;
    var rect = Rect.fromLTRB(face.bounds.left * sx, face.bounds.top * sy,
        face.bounds.right * sx, face.bounds.bottom * sy);
    if (mirrored) {
      rect = Rect.fromLTRB(size.width - rect.right, rect.top, size.width - rect.left, rect.bottom);
    }
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = size.shortestSide / 120;
    canvas.drawRRect(RRect.fromRectAndRadius(rect, Radius.circular(rect.width / 12)), paint);
  }

  @override
  bool shouldRepaint(_FacePainter old) =>
      old.result != result || old.mirrored != mirrored || old.color != color;
}
