//
// Platform-agnostic silent face anti-spoofing engine.
//
// Ported from the Android engine (engine/src/main/cpp). It only depends on ncnn,
// so the same code is shared by the iOS framework and the Flutter / React Native
// plugins. Instances are NOT thread-safe: use one engine per worker thread.
//

#ifndef FAS_FACE_ANTI_SPOOFING_H
#define FAS_FACE_ANTI_SPOOFING_H

#include <cstdint>
#include <memory>
#include <string>
#include <vector>

namespace ncnn {
class Net;
}

namespace fas {

enum class PixelFormat {
    kRGB,
    kBGR,
    kRGBA,
    kBGRA,
    kNV21,  // Y plane followed by interleaved VU (Android camera default)
    kNV12,  // Y plane followed by interleaved UV (iOS bi-planar)
};

/**
 * A view on caller-owned pixels.
 *
 * `orientation` is an EXIF orientation (1..8) that describes how to turn the
 * buffer into an upright image, using the same convention as ncnn::kanna_rotate:
 *
 *    1       2       3       4         5            6           7          8
 *
 *  888888  888888      88  88      8888888888  88                  88  8888888888
 *  88          88      88  88      88  88      88  88          88  88      88  88
 *  8888      8888    8888  8888    88          8888888888  8888888888          88
 *  88          88      88  88
 *  88          88  888888  888888
 *
 * All face coordinates returned by the engine are in the upright image space.
 */
struct Image {
    const uint8_t* data = nullptr;
    int width = 0;
    int height = 0;
    // Bytes per row for packed formats; 0 means tightly packed. YUV formats must
    // be contiguous (Y rows of `width` bytes followed by the chroma plane).
    int stride = 0;
    PixelFormat format = PixelFormat::kRGBA;
    int orientation = 1;
};

struct FaceBox {
    float x1 = 0.f;
    float y1 = 0.f;
    float x2 = 0.f;
    float y2 = 0.f;
    float confidence = 0.f;  // face detection confidence
};

struct ModelConfig {
    std::string name;
    std::string param_path;
    std::string bin_path;
    int width = 80;
    int height = 80;
    float scale = 1.f;
    float shift_x = 0.f;
    float shift_y = 0.f;
    bool org_resize = false;
};

struct Face {
    FaceBox box;
    // Probability that the face is real, in [0, 1]. Negative when liveness was not evaluated.
    float liveness = -1.f;
};

enum Status {
    kOk = 0,
    kErrorNotLoaded = -100,
    kErrorInvalidImage = -101,
    kErrorInvalidConfig = -102,
    kErrorLoadDetector = -103,
    kErrorLoadLiveness = -104,
};

/** Parses the `live/config.json` shipped with the models. Returns an empty list on error. */
std::vector<ModelConfig> ParseModelConfigs(const std::string& json);

/** A packed, upright 3 or 4 channel image ready to be fed to the networks. */
class UprightImage {
public:
    int Create(const Image& image);

    const uint8_t* data() const { return data_; }
    int width() const { return width_; }
    int height() const { return height_; }
    int stride() const { return stride_; }
    // ncnn pixel type converting this buffer to BGR (what all models expect).
    int bgr_type() const { return bgr_type_; }

private:
    std::vector<uint8_t> converted_;
    std::vector<uint8_t> rotated_;
    const uint8_t* data_ = nullptr;
    int width_ = 0;
    int height_ = 0;
    int stride_ = 0;
    int bgr_type_ = 0;
};

class FaceDetector {
public:
    FaceDetector();
    ~FaceDetector();

    int LoadModel(const std::string& param_path, const std::string& bin_path);

    void SetMinFaceSize(int size) { min_face_size_ = size; }
    void SetThreshold(float threshold) { threshold_ = threshold; }
    void SetNumThreads(int num_threads) { num_threads_ = num_threads; }

    /** Detects faces, sorted by area (largest first). Boxes are squared like the Android engine. */
    int Detect(const UprightImage& image, std::vector<FaceBox>& boxes);

private:
    std::unique_ptr<ncnn::Net> net_;
    int input_size_ = 192;
    float threshold_ = 0.6f;
    int min_face_size_ = 64;
    int num_threads_ = 2;
};

class LivenessDetector {
public:
    LivenessDetector();
    ~LivenessDetector();

    int LoadModel(const std::vector<ModelConfig>& configs);

    void SetNumThreads(int num_threads) { num_threads_ = num_threads; }

    /** Returns the averaged real-face probability of all models for `box`. */
    float Detect(const UprightImage& image, const FaceBox& box);

private:
    std::vector<std::unique_ptr<ncnn::Net>> nets_;
    std::vector<ModelConfig> configs_;
    int num_threads_ = 2;
};

/** Face detection + liveness in one call. */
class Engine {
public:
    /**
     * Loads all models from a directory laid out like the Android assets:
     *   <dir>/detection/detection.{param,bin}
     *   <dir>/live/config.json, <dir>/live/<name>.{param,bin}
     * or a flat directory containing all of those files.
     */
    int LoadFromDirectory(const std::string& dir);

    int Load(const std::string& detection_param,
             const std::string& detection_bin,
             const std::vector<ModelConfig>& liveness_configs);

    bool loaded() const { return loaded_; }

    FaceDetector& face_detector() { return face_detector_; }
    LivenessDetector& liveness_detector() { return liveness_detector_; }

    void SetNumThreads(int num_threads);

    /**
     * Detects faces and evaluates liveness. When `all_faces` is false only the
     * largest face is evaluated (and returned), matching the Android sample.
     */
    int Detect(const Image& image, std::vector<Face>& faces, bool all_faces = false);

private:
    FaceDetector face_detector_;
    LivenessDetector liveness_detector_;
    UprightImage upright_;
    std::vector<FaceBox> boxes_;
    bool loaded_ = false;
};

}  // namespace fas

#endif  // FAS_FACE_ANTI_SPOOFING_H
