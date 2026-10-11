Pod::Spec.new do |s|
  s.name             = 'face_liveness'
  s.version          = '1.0.1'
  s.summary          = 'On-device face liveness (anti-spoofing) detection for Flutter.'
  s.description      = <<-DESC
Detects faces and checks that they are real (not a photo, screen or mask), fully
on-device, using ncnn. Called from Dart through dart:ffi.
                       DESC
  s.homepage         = 'https://github.com/vishalsgithub/face-liveness-flutter'
  s.license          = { :file => '../LICENSE' }
  s.author           = { 'vish solanki' => 'solankivishal234@gmail.com' }

  s.source           = { :path => '.' }
  s.source_files     = 'Classes/**/*'
  s.dependency 'Flutter'
  s.platform = :ios, '13.0'

  # Prebuilt ncnn + OpenMP as static-library xcframeworks.
  s.vendored_frameworks = 'Frameworks/ncnn.xcframework', 'Frameworks/openmp.xcframework'
  s.library = 'c++'

  s.pod_target_xcconfig = {
    'DEFINES_MODULE' => 'YES',
    'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'i386',
    'CLANG_CXX_LANGUAGE_STANDARD' => 'c++17',
    'CLANG_CXX_LIBRARY' => 'libc++',
    # Only CPU feature flags differ between the ncnn slices, so the device headers serve both.
    'HEADER_SEARCH_PATHS' => '"${PODS_TARGET_SRCROOT}/../src" ' \
                             '"${PODS_TARGET_SRCROOT}/../src/core/include" ' \
                             '"${PODS_TARGET_SRCROOT}/Frameworks/ncnn.xcframework/ios-arm64/Headers"'
  }
  s.swift_version = '5.0'
end
