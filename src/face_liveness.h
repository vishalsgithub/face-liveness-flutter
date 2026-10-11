// C API of the face liveness engine, called from Dart through dart:ffi.
//
// The engine is not thread-safe: use one engine per thread (the Dart side owns
// it from a single background isolate).

#ifndef FACE_LIVENESS_H
#define FACE_LIVENESS_H

#include <stdint.h>

#if defined(_WIN32)
#define FL_EXPORT __declspec(dllexport)
#else
#define FL_EXPORT __attribute__((visibility("default"))) __attribute__((used))
#endif

#ifdef __cplusplus
extern "C" {
#endif

// Pixel formats accepted by fl_detect.
enum {
    FL_FORMAT_RGB = 0,
    FL_FORMAT_BGR = 1,
    FL_FORMAT_RGBA = 2,
    FL_FORMAT_BGRA = 3,
    FL_FORMAT_NV21 = 4,  // contiguous Y plane + interleaved VU
    FL_FORMAT_NV12 = 5,  // contiguous Y plane + interleaved UV
};

typedef struct {
    float x1;
    float y1;
    float x2;
    float y2;
    float detection_confidence;
    float liveness;  // real-face probability in [0, 1]
} FlFace;

FL_EXPORT void* fl_create(void);
FL_EXPORT void fl_destroy(void* engine);

// Loads the models from a directory containing detection/ and live/.
// Returns 0 on success, a negative error code otherwise.
FL_EXPORT int32_t fl_load(void* engine, const char* model_dir);

FL_EXPORT void fl_set_options(void* engine, int32_t min_face_size, float detection_threshold,
                              int32_t num_threads);

// Detects faces (largest first) and evaluates liveness. `orientation` is an EXIF
// orientation (1..8) turning the buffer upright; boxes are in upright image space.
// Returns the number of faces written to `out` (at most `max_faces`) or a
// negative error code.
FL_EXPORT int32_t fl_detect(void* engine, const uint8_t* data, int32_t width, int32_t height,
                            int32_t bytes_per_row, int32_t format, int32_t orientation,
                            int32_t all_faces, FlFace* out, int32_t max_faces);

// Same as fl_detect for Android YUV_420_888 camera frames given as 3 planes.
FL_EXPORT int32_t fl_detect_yuv420(void* engine, const uint8_t* y, const uint8_t* u,
                                   const uint8_t* v, int32_t width, int32_t height,
                                   int32_t y_row_stride, int32_t uv_row_stride,
                                   int32_t uv_pixel_stride, int32_t orientation,
                                   int32_t all_faces, FlFace* out, int32_t max_faces);

#ifdef __cplusplus
}
#endif

#endif  // FACE_LIVENESS_H
