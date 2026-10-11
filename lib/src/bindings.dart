// Hand-written dart:ffi bindings for src/face_liveness.h.

import 'dart:ffi';
import 'dart:io';

const int flFormatRgb = 0;
const int flFormatBgr = 1;
const int flFormatRgba = 2;
const int flFormatBgra = 3;
const int flFormatNv21 = 4;
const int flFormatNv12 = 5;

final class FlFace extends Struct {
  @Float()
  external double x1;
  @Float()
  external double y1;
  @Float()
  external double x2;
  @Float()
  external double y2;
  @Float()
  external double detectionConfidence;
  @Float()
  external double liveness;
}

typedef _CreateNative = Pointer<Void> Function();
typedef _DestroyNative = Void Function(Pointer<Void>);
typedef _LoadNative = Int32 Function(Pointer<Void>, Pointer<Char>);
typedef _SetOptionsNative = Void Function(Pointer<Void>, Int32, Float, Int32);
typedef _DetectNative = Int32 Function(Pointer<Void>, Pointer<Uint8>, Int32,
    Int32, Int32, Int32, Int32, Int32, Pointer<FlFace>, Int32);
typedef _DetectYuv420Native = Int32 Function(
    Pointer<Void>,
    Pointer<Uint8>,
    Pointer<Uint8>,
    Pointer<Uint8>,
    Int32,
    Int32,
    Int32,
    Int32,
    Int32,
    Int32,
    Int32,
    Pointer<FlFace>,
    Int32);

class FaceLivenessBindings {
  FaceLivenessBindings(DynamicLibrary lib)
      : create = lib.lookupFunction<_CreateNative, Pointer<Void> Function()>(
            'fl_create'),
        destroy =
            lib.lookupFunction<_DestroyNative, void Function(Pointer<Void>)>(
                'fl_destroy'),
        load = lib.lookupFunction<_LoadNative,
            int Function(Pointer<Void>, Pointer<Char>)>('fl_load'),
        setOptions = lib.lookupFunction<_SetOptionsNative,
            void Function(Pointer<Void>, int, double, int)>('fl_set_options'),
        detect = lib.lookupFunction<
            _DetectNative,
            int Function(Pointer<Void>, Pointer<Uint8>, int, int, int, int, int,
                int, Pointer<FlFace>, int)>('fl_detect'),
        detectYuv420 = lib.lookupFunction<
            _DetectYuv420Native,
            int Function(
                Pointer<Void>,
                Pointer<Uint8>,
                Pointer<Uint8>,
                Pointer<Uint8>,
                int,
                int,
                int,
                int,
                int,
                int,
                int,
                Pointer<FlFace>,
                int)>('fl_detect_yuv420');

  final Pointer<Void> Function() create;
  final void Function(Pointer<Void>) destroy;
  final int Function(Pointer<Void>, Pointer<Char>) load;
  final void Function(Pointer<Void>, int, double, int) setOptions;
  final int Function(Pointer<Void>, Pointer<Uint8>, int, int, int, int, int,
      int, Pointer<FlFace>, int) detect;
  final int Function(
      Pointer<Void>,
      Pointer<Uint8>,
      Pointer<Uint8>,
      Pointer<Uint8>,
      int,
      int,
      int,
      int,
      int,
      int,
      int,
      Pointer<FlFace>,
      int) detectYuv420;

  static DynamicLibrary openLibrary() {
    if (Platform.isAndroid) return DynamicLibrary.open('libface_liveness.so');
    if (Platform.isIOS) {
      // Built as a framework with `use_frameworks!` (Flutter's default), otherwise
      // linked statically into the app.
      try {
        return DynamicLibrary.open('face_liveness.framework/face_liveness');
      } on ArgumentError {
        return DynamicLibrary.process();
      }
    }
    throw UnsupportedError('face_liveness supports Android and iOS only.');
  }
}
