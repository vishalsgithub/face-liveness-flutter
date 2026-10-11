#include "face_liveness.h"

#include <algorithm>
#include <vector>

#include "fas/face_anti_spoofing.h"

namespace {

struct EngineHandle {
    fas::Engine engine;
    std::vector<fas::Face> faces;
    std::vector<uint8_t> nv21;
};

int32_t WriteFaces(const std::vector<fas::Face>& faces, FlFace* out, int32_t max_faces) {
    const int32_t count = std::min<int32_t>(static_cast<int32_t>(faces.size()), max_faces);
    for (int32_t i = 0; i < count; ++i) {
        out[i].x1 = faces[i].box.x1;
        out[i].y1 = faces[i].box.y1;
        out[i].x2 = faces[i].box.x2;
        out[i].y2 = faces[i].box.y2;
        out[i].detection_confidence = faces[i].box.confidence;
        out[i].liveness = faces[i].liveness;
    }
    return count;
}

}  // namespace

void* fl_create(void) { return new EngineHandle(); }

void fl_destroy(void* engine) { delete static_cast<EngineHandle*>(engine); }

int32_t fl_load(void* engine, const char* model_dir) {
    if (!engine || !model_dir) return fas::kErrorNotLoaded;
    return static_cast<EngineHandle*>(engine)->engine.LoadFromDirectory(model_dir);
}

void fl_set_options(void* engine, int32_t min_face_size, float detection_threshold,
                    int32_t num_threads) {
    if (!engine) return;
    fas::Engine& e = static_cast<EngineHandle*>(engine)->engine;
    e.face_detector().SetMinFaceSize(min_face_size);
    e.face_detector().SetThreshold(detection_threshold);
    e.SetNumThreads(std::max(1, num_threads));
}

int32_t fl_detect(void* engine, const uint8_t* data, int32_t width, int32_t height,
                  int32_t bytes_per_row, int32_t format, int32_t orientation, int32_t all_faces,
                  FlFace* out, int32_t max_faces) {
    if (!engine || !out || max_faces < 0) return fas::kErrorInvalidImage;
    if (format < FL_FORMAT_RGB || format > FL_FORMAT_NV12) return fas::kErrorInvalidImage;
    EngineHandle* handle = static_cast<EngineHandle*>(engine);

    static const fas::PixelFormat kFormats[] = {
        fas::PixelFormat::kRGB,  fas::PixelFormat::kBGR,  fas::PixelFormat::kRGBA,
        fas::PixelFormat::kBGRA, fas::PixelFormat::kNV21, fas::PixelFormat::kNV12,
    };
    fas::Image image;
    image.data = data;
    image.width = width;
    image.height = height;
    image.stride = bytes_per_row;
    image.format = kFormats[format];
    image.orientation = orientation;

    int ret = handle->engine.Detect(image, handle->faces, all_faces != 0);
    if (ret != fas::kOk) return ret;
    return WriteFaces(handle->faces, out, max_faces);
}

int32_t fl_detect_yuv420(void* engine, const uint8_t* y, const uint8_t* u, const uint8_t* v,
                         int32_t width, int32_t height, int32_t y_row_stride,
                         int32_t uv_row_stride, int32_t uv_pixel_stride, int32_t orientation,
                         int32_t all_faces, FlFace* out, int32_t max_faces) {
    if (!engine || !y || !u || !v || width <= 0 || height <= 0 || width % 2 || height % 2) {
        return fas::kErrorInvalidImage;
    }
    EngineHandle* handle = static_cast<EngineHandle*>(engine);

    // Pack the planes into contiguous NV21 (Y, then interleaved V/U).
    handle->nv21.resize(static_cast<size_t>(width) * height * 3 / 2);
    uint8_t* dst = handle->nv21.data();
    for (int32_t row = 0; row < height; ++row) {
        std::copy(y + static_cast<size_t>(row) * y_row_stride,
                  y + static_cast<size_t>(row) * y_row_stride + width, dst + static_cast<size_t>(row) * width);
    }
    uint8_t* vu = dst + static_cast<size_t>(width) * height;
    for (int32_t row = 0; row < height / 2; ++row) {
        const uint8_t* u_row = u + static_cast<size_t>(row) * uv_row_stride;
        const uint8_t* v_row = v + static_cast<size_t>(row) * uv_row_stride;
        for (int32_t col = 0; col < width / 2; ++col) {
            *vu++ = v_row[col * uv_pixel_stride];
            *vu++ = u_row[col * uv_pixel_stride];
        }
    }
    return fl_detect(engine, handle->nv21.data(), width, height, width, FL_FORMAT_NV21,
                     orientation, all_faces, out, max_faces);
}
