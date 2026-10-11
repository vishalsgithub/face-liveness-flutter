import 'dart:async';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:camera/camera.dart';
import 'package:ffi/ffi.dart';
import 'package:flutter/services.dart';

import 'bindings.dart';
import 'types.dart';

const int _maxFaces = 16;

/// Bump when the bundled models change, so stale copies are replaced.
const String _modelsVersion = 'v1';
const List<String> _modelFiles = [
  'detection/detection.param',
  'detection/detection.bin',
  'live/config.json',
  'live/model_1.param',
  'live/model_1.bin',
  'live/model_2.param',
  'live/model_2.bin',
];

/// On-device face detection + liveness (anti-spoofing).
///
/// Inference runs on a background isolate, so calls never block the UI.
/// Create one instance, reuse it, and call [dispose] when done.
class FaceLiveness {
  FaceLiveness._(this._worker, this.livenessThreshold);

  /// Default liveness threshold, same as the original Android sample.
  static const double defaultLivenessThreshold = 0.915;

  /// Faces with `livenessScore >= livenessThreshold` are reported as live.
  double livenessThreshold;

  final _Worker _worker;
  bool _disposed = false;

  /// Loads the bundled models and starts the engine.
  static Future<FaceLiveness> create({
    double livenessThreshold = defaultLivenessThreshold,
    int minFaceSize = 64,
    double faceDetectionThreshold = 0.6,
    int numThreads = 2,
  }) async {
    final modelDir = await _prepareModels();
    final worker = await _Worker.spawn(modelDir);
    final face = FaceLiveness._(worker, livenessThreshold);
    await face.setOptions(
      minFaceSize: minFaceSize,
      faceDetectionThreshold: faceDetectionThreshold,
      numThreads: numThreads,
    );
    return face;
  }

  /// Updates detector options. [minFaceSize] is in pixels of the upright image.
  Future<void> setOptions({
    int minFaceSize = 64,
    double faceDetectionThreshold = 0.6,
    int numThreads = 2,
  }) {
    _checkNotDisposed();
    return _worker.request(['options', minFaceSize, faceDetectionThreshold, numThreads]);
  }

  /// Detects faces in raw pixels. Only the largest face is evaluated unless [allFaces].
  Future<List<LivenessFace>> detectInPixels(
    Uint8List pixels, {
    required int width,
    required int height,
    int? bytesPerRow,
    LivenessPixelFormat format = LivenessPixelFormat.rgba,
    LivenessImageOrientation orientation = LivenessImageOrientation.up,
    bool allFaces = false,
  }) async {
    _checkNotDisposed();
    final result = await _worker.request([
      'detect',
      TransferableTypedData.fromList([pixels]),
      width,
      height,
      bytesPerRow ?? 0,
      format.code,
      orientation.exif,
      allFaces,
    ]);
    return _toFaces(result);
  }

  /// Detects faces in an encoded image (JPEG, PNG, ...). EXIF orientation is applied.
  Future<List<LivenessFace>> detectInImageBytes(Uint8List encoded, {bool allFaces = false}) async {
    final codec = await ui.instantiateImageCodec(encoded);
    final frame = await codec.getNextFrame();
    final image = frame.image;
    try {
      final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
      if (data == null) throw const FaceLivenessException(-101, 'Could not decode the image.');
      return detectInPixels(
        data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
        width: image.width,
        height: image.height,
        allFaces: allFaces,
      );
    } finally {
      image.dispose();
      codec.dispose();
    }
  }

  /// Detects faces in an image file (JPEG, PNG, ...).
  Future<List<LivenessFace>> detectInFile(String path, {bool allFaces = false}) async =>
      detectInImageBytes(await File(path).readAsBytes(), allFaces: allFaces);

  /// Detects faces in a frame from `CameraController.startImageStream`.
  ///
  /// [rotationDegrees] is the clockwise rotation that makes the frame upright
  /// (see `FaceLivenessCamera`, which computes it for you). Supports YUV420 and
  /// NV21 frames on Android and BGRA frames on iOS.
  Future<List<LivenessFace>> detectInCameraImage(
    CameraImage image, {
    required int rotationDegrees,
    bool allFaces = false,
  }) async {
    _checkNotDisposed();
    final orientation = LivenessImageOrientation.fromRotation(rotationDegrees);
    switch (image.format.group) {
      case ImageFormatGroup.yuv420:
        if (image.planes.length < 3) break;
        final y = image.planes[0], u = image.planes[1], v = image.planes[2];
        final result = await _worker.request([
          'yuv420',
          TransferableTypedData.fromList([y.bytes, u.bytes, v.bytes]),
          y.bytes.length,
          u.bytes.length,
          image.width,
          image.height,
          y.bytesPerRow,
          u.bytesPerRow,
          u.bytesPerPixel ?? 1,
          orientation.exif,
          allFaces,
        ]);
        return _toFaces(result);
      case ImageFormatGroup.nv21:
        final plane = image.planes.first;
        final bytes = plane.bytesPerRow == image.width
            ? plane.bytes
            : _packNv21(image);
        return detectInPixels(bytes,
            width: image.width,
            height: image.height,
            format: LivenessPixelFormat.nv21,
            orientation: orientation,
            allFaces: allFaces);
      case ImageFormatGroup.bgra8888:
        final plane = image.planes.first;
        return detectInPixels(plane.bytes,
            width: image.width,
            height: image.height,
            bytesPerRow: plane.bytesPerRow,
            format: LivenessPixelFormat.bgra,
            orientation: orientation,
            allFaces: allFaces);
      default:
        break;
    }
    throw FaceLivenessException(-101, 'Unsupported camera image format: ${image.format.group}.');
  }

  /// Stops the engine and frees native memory.
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await _worker.close();
  }

  void _checkNotDisposed() {
    if (_disposed) throw StateError('FaceLiveness has been disposed.');
  }

  List<LivenessFace> _toFaces(Object? result) {
    final values = result as Float32List;
    final faces = <LivenessFace>[];
    for (var i = 0; i + 5 < values.length; i += 6) {
      final liveness = values[i + 5];
      faces.add(LivenessFace(
        bounds: ui.Rect.fromLTRB(values[i], values[i + 1], values[i + 2] + 1, values[i + 3] + 1),
        detectionConfidence: values[i + 4],
        livenessScore: liveness,
        isLive: liveness >= livenessThreshold,
      ));
    }
    return faces;
  }

  // NV21 frames with padded rows: drop the padding.
  static Uint8List _packNv21(CameraImage image) {
    final plane = image.planes.first;
    final w = image.width, h = image.height, stride = plane.bytesPerRow;
    final out = Uint8List(w * h * 3 ~/ 2);
    for (var row = 0; row < h + h ~/ 2; row++) {
      out.setRange(row * w, row * w + w, plane.bytes, row * stride);
    }
    return out;
  }

  /// Copies the bundled models from the package assets to a cache directory (once).
  static Future<String> _prepareModels() async {
    final dir = Directory('${Directory.systemTemp.path}/face_liveness_models_$_modelsVersion');
    for (final name in _modelFiles) {
      final file = File('${dir.path}/$name');
      final data = await rootBundle.load('packages/face_liveness/assets/models/$name');
      if (file.existsSync() && file.lengthSync() == data.lengthInBytes) continue;
      await file.parent.create(recursive: true);
      final tmp = File('${file.path}.tmp');
      await tmp.writeAsBytes(data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes), flush: true);
      await tmp.rename(file.path);
    }
    return dir.path;
  }
}

// --- Background isolate ---------------------------------------------------------

class _Worker {
  _Worker._(this._commands, this._responses) {
    _responses.listen(_onResponse);
  }

  final SendPort _commands;
  final ReceivePort _responses;
  final Map<int, Completer<Object?>> _pending = {};
  int _nextId = 0;
  bool _closed = false;

  static Future<_Worker> spawn(String modelDir) async {
    final initPort = RawReceivePort();
    final connection = Completer<(ReceivePort, SendPort)>.sync();
    initPort.handler = (Object? message) {
      final commands = message as SendPort;
      connection.complete((ReceivePort.fromRawReceivePort(initPort), commands));
    };
    try {
      await Isolate.spawn(_workerMain, initPort.sendPort, debugName: 'face_liveness');
    } catch (_) {
      initPort.close();
      rethrow;
    }
    final (responses, commands) = await connection.future;
    final worker = _Worker._(commands, responses);
    await worker.request(['load', modelDir]);
    return worker;
  }

  Future<Object?> request(List<Object?> message) {
    if (_closed) return Future.error(StateError('FaceLiveness has been disposed.'));
    final id = _nextId++;
    final completer = Completer<Object?>.sync();
    _pending[id] = completer;
    _commands.send([id, ...message]);
    return completer.future;
  }

  void _onResponse(Object? message) {
    final list = message as List<Object?>;
    final completer = _pending.remove(list[0] as int);
    if (completer == null) return;
    final payload = list[1];
    if (payload is int && payload < 0) {
      completer.completeError(FaceLivenessException.fromCode(payload));
    } else if (payload is String) {
      completer.completeError(FaceLivenessException(-1, payload));
    } else {
      completer.complete(payload);
    }
    if (_closed && _pending.isEmpty) _responses.close();
  }

  Future<void> close() async {
    if (_closed) return;
    final done = request(['dispose']);
    _closed = true;
    await done;
  }
}

void _workerMain(SendPort mainPort) {
  final commands = ReceivePort();
  mainPort.send(commands.sendPort);

  late final FaceLivenessBindings bindings;
  Pointer<Void> engine = nullptr;
  Pointer<Uint8> buffer = nullptr;
  var capacity = 0;
  final out = calloc<FlFace>(_maxFaces);

  Pointer<Uint8> ensureBuffer(int size) {
    if (size > capacity) {
      if (buffer != nullptr) calloc.free(buffer);
      buffer = calloc<Uint8>(size);
      capacity = size;
    }
    return buffer;
  }

  Object? facesOrError(int count) {
    if (count < 0) return count;
    final values = Float32List(count * 6);
    for (var i = 0; i < count; i++) {
      final f = out[i];
      values
        ..[i * 6] = f.x1
        ..[i * 6 + 1] = f.y1
        ..[i * 6 + 2] = f.x2
        ..[i * 6 + 3] = f.y2
        ..[i * 6 + 4] = f.detectionConfidence
        ..[i * 6 + 5] = f.liveness;
    }
    return values;
  }

  commands.listen((Object? message) {
    final m = message as List<Object?>;
    final id = m[0] as int;
    Object? reply;
    try {
      switch (m[1] as String) {
        case 'load':
          bindings = FaceLivenessBindings(FaceLivenessBindings.openLibrary());
          engine = bindings.create();
          final path = (m[2] as String).toNativeUtf8();
          try {
            final ret = bindings.load(engine, path.cast());
            reply = ret == 0 ? null : ret;
          } finally {
            calloc.free(path);
          }
        case 'options':
          bindings.setOptions(engine, m[2] as int, m[3] as double, m[4] as int);
        case 'detect':
          final bytes = (m[2] as TransferableTypedData).materialize().asUint8List();
          final ptr = ensureBuffer(bytes.length);
          ptr.asTypedList(bytes.length).setAll(0, bytes);
          final count = bindings.detect(engine, ptr, m[3] as int, m[4] as int, m[5] as int,
              m[6] as int, m[7] as int, (m[8] as bool) ? 1 : 0, out, _maxFaces);
          reply = facesOrError(count);
        case 'yuv420':
          final bytes = (m[2] as TransferableTypedData).materialize().asUint8List();
          final yLength = m[3] as int, uLength = m[4] as int;
          final ptr = ensureBuffer(bytes.length);
          ptr.asTypedList(bytes.length).setAll(0, bytes);
          final count = bindings.detectYuv420(
              engine,
              ptr,
              ptr + yLength,
              ptr + yLength + uLength,
              m[5] as int,
              m[6] as int,
              m[7] as int,
              m[8] as int,
              m[9] as int,
              m[10] as int,
              (m[11] as bool) ? 1 : 0,
              out,
              _maxFaces);
          reply = facesOrError(count);
        case 'dispose':
          if (engine != nullptr) bindings.destroy(engine);
          engine = nullptr;
          if (buffer != nullptr) calloc.free(buffer);
          calloc.free(out);
          mainPort.send([id, null]);
          commands.close();
          return;
      }
    } catch (e) {
      reply = e.toString();
    }
    mainPort.send([id, reply]);
  });
}
