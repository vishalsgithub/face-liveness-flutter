//
// Platform-agnostic port of engine/src/main/cpp (detection/face_detector.cpp,
// live/live.cpp, img_process.cpp). OpenCV has been replaced by ncnn's own
// pixel utilities so that only ncnn is required on every platform.
//

#include "fas/face_anti_spoofing.h"

#include <algorithm>
#include <cctype>
#include <cmath>
#include <cstdio>
#include <cstdlib>

#include <ncnn/net.h>

namespace fas {

namespace {

const char* kNetInputName = "data";
const char* kDetectionOutputName = "detection_out";
const char* kLivenessOutputName = "softmax";
const float kDetectionMeanValues[3] = {104.f, 117.f, 123.f};

bool FileExists(const std::string& path) {
    FILE* fp = fopen(path.c_str(), "rb");
    if (!fp) return false;
    fclose(fp);
    return true;
}

bool ReadFile(const std::string& path, std::string& out) {
    FILE* fp = fopen(path.c_str(), "rb");
    if (!fp) return false;
    out.clear();
    char buf[4096];
    size_t n;
    while ((n = fread(buf, 1, sizeof(buf), fp)) > 0) out.append(buf, n);
    fclose(fp);
    return true;
}

// Returns the first existing path among `candidates`, or an empty string.
std::string FirstExisting(const std::vector<std::string>& candidates) {
    for (const auto& c : candidates) {
        if (FileExists(c)) return c;
    }
    return std::string();
}

ncnn::Option MakeOption(int num_threads) {
    ncnn::Option option;
    option.lightmode = true;
    option.num_threads = num_threads;
    return option;
}

// Port of Live::CalculateBox, with a final clamp so the ROI is always valid.
void CalculateBox(const FaceBox& box, int w, int h, const ModelConfig& config,
                  int& roi_x, int& roi_y, int& roi_w, int& roi_h) {
    int x = static_cast<int>(box.x1);
    int y = static_cast<int>(box.y1);
    int box_width = static_cast<int>(box.x2 - box.x1 + 1);
    int box_height = static_cast<int>(box.y2 - box.y1 + 1);
    box_width = std::max(box_width, 1);
    box_height = std::max(box_height, 1);

    int shift_x = static_cast<int>(box_width * config.shift_x);
    int shift_y = static_cast<int>(box_height * config.shift_y);

    float scale = std::min(config.scale,
                           std::min((w - 1) / (float)box_width, (h - 1) / (float)box_height));

    int box_center_x = box_width / 2 + x;
    int box_center_y = box_height / 2 + y;

    int new_width = static_cast<int>(box_width * scale);
    int new_height = static_cast<int>(box_height * scale);

    int left_top_x = box_center_x - new_width / 2 + shift_x;
    int left_top_y = box_center_y - new_height / 2 + shift_y;
    int right_bottom_x = box_center_x + new_width / 2 + shift_x;
    int right_bottom_y = box_center_y + new_height / 2 + shift_y;

    if (left_top_x < 0) {
        right_bottom_x -= left_top_x;
        left_top_x = 0;
    }
    if (left_top_y < 0) {
        right_bottom_y -= left_top_y;
        left_top_y = 0;
    }
    if (right_bottom_x >= w) {
        int s = right_bottom_x - w + 1;
        left_top_x -= s;
        right_bottom_x -= s;
    }
    if (right_bottom_y >= h) {
        int s = right_bottom_y - h + 1;
        left_top_y -= s;
        right_bottom_y -= s;
    }

    roi_x = std::max(0, left_top_x);
    roi_y = std::max(0, left_top_y);
    roi_w = std::max(1, std::min(new_width, w - roi_x));
    roi_h = std::max(1, std::min(new_height, h - roi_y));
}

// --- Minimal JSON reader for the flat config.json format ---------------------

void SkipSpaces(const std::string& s, size_t& i) {
    while (i < s.size() && std::isspace(static_cast<unsigned char>(s[i]))) ++i;
}

bool ReadString(const std::string& s, size_t& i, std::string& out) {
    if (i >= s.size() || s[i] != '"') return false;
    ++i;
    out.clear();
    while (i < s.size() && s[i] != '"') {
        if (s[i] == '\\' && i + 1 < s.size()) ++i;
        out.push_back(s[i++]);
    }
    if (i >= s.size()) return false;
    ++i;
    return true;
}

// Reads a scalar (number / true / false / string) as raw text.
bool ReadScalar(const std::string& s, size_t& i, std::string& out) {
    SkipSpaces(s, i);
    if (i < s.size() && s[i] == '"') return ReadString(s, i, out);
    size_t start = i;
    while (i < s.size() && s[i] != ',' && s[i] != '}' &&
           !std::isspace(static_cast<unsigned char>(s[i]))) {
        ++i;
    }
    out = s.substr(start, i - start);
    return !out.empty();
}

}  // namespace

std::vector<ModelConfig> ParseModelConfigs(const std::string& json) {
    std::vector<ModelConfig> configs;
    size_t i = 0;
    SkipSpaces(json, i);
    if (i >= json.size() || json[i] != '[') return configs;
    ++i;

    while (true) {
        SkipSpaces(json, i);
        if (i >= json.size()) return {};
        if (json[i] == ']') break;
        if (json[i] == ',') {
            ++i;
            continue;
        }
        if (json[i] != '{') return {};
        ++i;

        ModelConfig config;
        while (true) {
            SkipSpaces(json, i);
            if (i >= json.size()) return {};
            if (json[i] == '}') {
                ++i;
                break;
            }
            if (json[i] == ',') {
                ++i;
                continue;
            }
            std::string key, value;
            if (!ReadString(json, i, key)) return {};
            SkipSpaces(json, i);
            if (i >= json.size() || json[i] != ':') return {};
            ++i;
            if (!ReadScalar(json, i, value)) return {};

            if (key == "name") config.name = value;
            else if (key == "width") config.width = std::atoi(value.c_str());
            else if (key == "height") config.height = std::atoi(value.c_str());
            else if (key == "scale") config.scale = static_cast<float>(std::atof(value.c_str()));
            else if (key == "shift_x") config.shift_x = static_cast<float>(std::atof(value.c_str()));
            else if (key == "shift_y") config.shift_y = static_cast<float>(std::atof(value.c_str()));
            else if (key == "org_resize") config.org_resize = value == "true";
        }
        if (config.name.empty() || config.width <= 0 || config.height <= 0) return {};
        configs.push_back(config);
    }
    return configs;
}

// --- UprightImage -------------------------------------------------------------

int UprightImage::Create(const Image& image) {
    if (!image.data || image.width <= 0 || image.height <= 0 ||
        image.orientation < 1 || image.orientation > 8) {
        return kErrorInvalidImage;
    }

    const uint8_t* src = image.data;
    int w = image.width;
    int h = image.height;
    int channels;
    int stride;

    switch (image.format) {
        case PixelFormat::kRGB:
            channels = 3;
            bgr_type_ = ncnn::Mat::PIXEL_RGB2BGR;
            break;
        case PixelFormat::kBGR:
            channels = 3;
            bgr_type_ = ncnn::Mat::PIXEL_BGR;
            break;
        case PixelFormat::kRGBA:
            channels = 4;
            bgr_type_ = ncnn::Mat::PIXEL_RGBA2BGR;
            break;
        case PixelFormat::kBGRA:
            channels = 4;
            bgr_type_ = ncnn::Mat::PIXEL_BGRA2BGR;
            break;
        case PixelFormat::kNV21:
        case PixelFormat::kNV12:
            if (w % 2 != 0 || h % 2 != 0) return kErrorInvalidImage;
            channels = 3;
            bgr_type_ = ncnn::Mat::PIXEL_RGB2BGR;
            break;
        default:
            return kErrorInvalidImage;
    }

    if (image.format == PixelFormat::kNV21 || image.format == PixelFormat::kNV12) {
        converted_.resize(static_cast<size_t>(w) * h * 3);
        if (image.format == PixelFormat::kNV21) {
            ncnn::yuv420sp2rgb(src, w, h, converted_.data());
        } else {
            ncnn::yuv420sp2rgb_nv12(src, w, h, converted_.data());
        }
        src = converted_.data();
        stride = w * 3;
    } else {
        stride = image.stride > 0 ? image.stride : w * channels;
        if (stride < w * channels) return kErrorInvalidImage;
    }

    if (image.orientation == 1) {
        data_ = src;
        width_ = w;
        height_ = h;
        stride_ = stride;
        return kOk;
    }

    const bool swap = image.orientation >= 5;
    const int dst_w = swap ? h : w;
    const int dst_h = swap ? w : h;
    const int dst_stride = dst_w * channels;
    rotated_.resize(static_cast<size_t>(dst_stride) * dst_h);
    if (channels == 3) {
        ncnn::kanna_rotate_c3(src, w, h, stride, rotated_.data(), dst_w, dst_h, dst_stride,
                              image.orientation);
    } else {
        ncnn::kanna_rotate_c4(src, w, h, stride, rotated_.data(), dst_w, dst_h, dst_stride,
                              image.orientation);
    }
    data_ = rotated_.data();
    width_ = dst_w;
    height_ = dst_h;
    stride_ = dst_stride;
    return kOk;
}

// --- FaceDetector -------------------------------------------------------------

FaceDetector::FaceDetector() = default;
FaceDetector::~FaceDetector() = default;

int FaceDetector::LoadModel(const std::string& param_path, const std::string& bin_path) {
    net_.reset(new ncnn::Net());
    net_->opt = MakeOption(num_threads_);
    if (net_->load_param(param_path.c_str()) != 0 || net_->load_model(bin_path.c_str()) != 0) {
        net_.reset();
        return kErrorLoadDetector;
    }
    return kOk;
}

int FaceDetector::Detect(const UprightImage& image, std::vector<FaceBox>& boxes) {
    boxes.clear();
    if (!net_) return kErrorNotLoaded;

    const int w = image.width();
    const int h = image.height();
    const float aspect_ratio = w / (float)h;
    const int input_width = static_cast<int>(input_size_ * std::sqrt(aspect_ratio));
    const int input_height = static_cast<int>(input_size_ / std::sqrt(aspect_ratio));

    ncnn::Mat in = ncnn::Mat::from_pixels_resize(image.data(), image.bgr_type(), w, h,
                                                 image.stride(), input_width, input_height);
    in.substract_mean_normalize(kDetectionMeanValues, nullptr);

    net_->opt.num_threads = num_threads_;
    ncnn::Extractor extractor = net_->create_extractor();
    extractor.set_light_mode(true);
    extractor.input(kNetInputName, in);

    ncnn::Mat out;
    extractor.extract(kDetectionOutputName, out);

    for (int i = 0; i < out.h; ++i) {
        const float* values = out.row(i);
        const float confidence = values[1];
        if (confidence < threshold_) continue;

        FaceBox box;
        box.confidence = confidence;
        box.x1 = values[2] * w;
        box.y1 = values[3] * h;
        box.x2 = values[4] * w;
        box.y2 = values[5] * h;

        // square
        const float box_width = box.x2 - box.x1 + 1;
        const float box_height = box.y2 - box.y1 + 1;
        const float size = (box_width + box_height) * 0.5f;
        if (size < min_face_size_) continue;

        const float cx = box.x1 + box_width * 0.5f;
        const float cy = box.y1 + box_height * 0.5f;
        box.x1 = cx - size * 0.5f;
        box.y1 = cy - size * 0.5f;
        box.x2 = cx + size * 0.5f - 1;
        box.y2 = cy + size * 0.5f - 1;

        boxes.push_back(box);
    }

    std::sort(boxes.begin(), boxes.end(), [](const FaceBox& l, const FaceBox& r) {
        return (l.x2 - l.x1 + 1) * (l.y2 - l.y1 + 1) > (r.x2 - r.x1 + 1) * (r.y2 - r.y1 + 1);
    });
    return kOk;
}

// --- LivenessDetector ---------------------------------------------------------

LivenessDetector::LivenessDetector() = default;
LivenessDetector::~LivenessDetector() = default;

int LivenessDetector::LoadModel(const std::vector<ModelConfig>& configs) {
    nets_.clear();
    configs_.clear();
    if (configs.empty()) return kErrorInvalidConfig;

    for (const auto& config : configs) {
        std::unique_ptr<ncnn::Net> net(new ncnn::Net());
        net->opt = MakeOption(num_threads_);
        if (net->load_param(config.param_path.c_str()) != 0 ||
            net->load_model(config.bin_path.c_str()) != 0) {
            nets_.clear();
            return kErrorLoadLiveness;
        }
        nets_.push_back(std::move(net));
    }
    configs_ = configs;
    return kOk;
}

float LivenessDetector::Detect(const UprightImage& image, const FaceBox& box) {
    if (nets_.empty()) return static_cast<float>(kErrorNotLoaded);

    float confidence = 0.f;
    for (size_t i = 0; i < nets_.size(); ++i) {
        const ModelConfig& config = configs_[i];
        ncnn::Mat in;
        if (config.org_resize) {
            in = ncnn::Mat::from_pixels_resize(image.data(), image.bgr_type(), image.width(),
                                               image.height(), image.stride(), config.width,
                                               config.height);
        } else {
            int x, y, rw, rh;
            CalculateBox(box, image.width(), image.height(), config, x, y, rw, rh);
            in = ncnn::Mat::from_pixels_roi_resize(image.data(), image.bgr_type(), image.width(),
                                                   image.height(), image.stride(), x, y, rw, rh,
                                                   config.width, config.height);
        }

        nets_[i]->opt.num_threads = num_threads_;
        ncnn::Extractor extractor = nets_[i]->create_extractor();
        extractor.set_light_mode(true);
        extractor.input(kNetInputName, in);

        ncnn::Mat out;
        extractor.extract(kLivenessOutputName, out);
        confidence += out.row(0)[1];
    }
    return confidence / nets_.size();
}

// --- Engine -------------------------------------------------------------------

int Engine::LoadFromDirectory(const std::string& dir_in) {
    std::string dir = dir_in;
    if (!dir.empty() && dir.back() != '/') dir.push_back('/');

    const std::string det_param = FirstExisting({dir + "detection/detection.param", dir + "detection.param"});
    const std::string det_bin = FirstExisting({dir + "detection/detection.bin", dir + "detection.bin"});
    if (det_param.empty() || det_bin.empty()) return kErrorLoadDetector;

    std::string live_dir = dir + "live/";
    std::string config_path = live_dir + "config.json";
    if (!FileExists(config_path)) {
        live_dir = dir;
        config_path = dir + "config.json";
    }
    std::string json;
    if (!ReadFile(config_path, json)) return kErrorInvalidConfig;

    std::vector<ModelConfig> configs = ParseModelConfigs(json);
    if (configs.empty()) return kErrorInvalidConfig;
    for (auto& config : configs) {
        config.param_path = live_dir + config.name + ".param";
        config.bin_path = live_dir + config.name + ".bin";
    }
    return Load(det_param, det_bin, configs);
}

int Engine::Load(const std::string& detection_param,
                 const std::string& detection_bin,
                 const std::vector<ModelConfig>& liveness_configs) {
    loaded_ = false;
    int ret = face_detector_.LoadModel(detection_param, detection_bin);
    if (ret != kOk) return ret;
    ret = liveness_detector_.LoadModel(liveness_configs);
    if (ret != kOk) return ret;
    loaded_ = true;
    return kOk;
}

void Engine::SetNumThreads(int num_threads) {
    face_detector_.SetNumThreads(num_threads);
    liveness_detector_.SetNumThreads(num_threads);
}

int Engine::Detect(const Image& image, std::vector<Face>& faces, bool all_faces) {
    faces.clear();
    if (!loaded_) return kErrorNotLoaded;

    int ret = upright_.Create(image);
    if (ret != kOk) return ret;

    ret = face_detector_.Detect(upright_, boxes_);
    if (ret != kOk) return ret;

    const size_t count = all_faces ? boxes_.size() : std::min<size_t>(1, boxes_.size());
    for (size_t i = 0; i < count; ++i) {
        Face face;
        face.box = boxes_[i];
        face.liveness = liveness_detector_.Detect(upright_, boxes_[i]);
        faces.push_back(face);
    }
    return kOk;
}

}  // namespace fas
