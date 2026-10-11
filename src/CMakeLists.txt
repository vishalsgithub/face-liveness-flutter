# Builds libface_liveness.so for Android (invoked by android/build.gradle).
# iOS builds the same sources through ios/face_liveness.podspec.

cmake_minimum_required(VERSION 3.10)

project(face_liveness_library VERSION 1.0.0 LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 14)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

# --- ncnn (prebuilt Android release, downloaded once and shared by all ABIs) ---
set(NCNN_VERSION 20260526)
set(NCNN_SHA256 85b18b875488585c2d21360430e0e54abb6c04aa88094b471c20208ab55ff796)
set(NCNN_NAME ncnn-${NCNN_VERSION}-android)

if(DEFINED ENV{FACE_LIVENESS_NCNN_DIR})
  set(NCNN_CACHE_DIR "$ENV{FACE_LIVENESS_NCNN_DIR}")
elseif(DEFINED ENV{HOME})
  set(NCNN_CACHE_DIR "$ENV{HOME}/.face_liveness")
else()
  set(NCNN_CACHE_DIR "$ENV{USERPROFILE}/.face_liveness")
endif()
set(NCNN_ROOT "${NCNN_CACHE_DIR}/${NCNN_NAME}")

if(NOT EXISTS "${NCNN_ROOT}/${ANDROID_ABI}/lib/cmake/ncnn/ncnnConfig.cmake")
  file(MAKE_DIRECTORY "${NCNN_CACHE_DIR}")
  # Gradle configures every ABI in parallel: only one of them downloads.
  file(LOCK "${NCNN_CACHE_DIR}/${NCNN_NAME}.lock" GUARD FILE TIMEOUT 900)
  if(NOT EXISTS "${NCNN_ROOT}/${ANDROID_ABI}/lib/cmake/ncnn/ncnnConfig.cmake")
    set(NCNN_ZIP "${NCNN_CACHE_DIR}/${NCNN_NAME}.zip")
    message(STATUS "face_liveness: downloading ${NCNN_NAME}")
    file(DOWNLOAD
      "https://github.com/Tencent/ncnn/releases/download/${NCNN_VERSION}/${NCNN_NAME}.zip"
      "${NCNN_ZIP}"
      EXPECTED_HASH SHA256=${NCNN_SHA256}
      TLS_VERIFY ON
      SHOW_PROGRESS)
    execute_process(
      COMMAND ${CMAKE_COMMAND} -E tar xf "${NCNN_ZIP}"
      WORKING_DIRECTORY "${NCNN_CACHE_DIR}"
      RESULT_VARIABLE NCNN_EXTRACT_RESULT)
    file(REMOVE "${NCNN_ZIP}")
    if(NOT NCNN_EXTRACT_RESULT EQUAL 0)
      message(FATAL_ERROR "face_liveness: failed to extract ${NCNN_NAME}")
    endif()
  endif()
  file(LOCK "${NCNN_CACHE_DIR}/${NCNN_NAME}.lock" RELEASE)
endif()

set(ncnn_DIR "${NCNN_ROOT}/${ANDROID_ABI}/lib/cmake/ncnn")
find_package(ncnn REQUIRED)

# --- face_liveness ---
add_library(face_liveness SHARED
  face_liveness.cpp
  core/src/face_anti_spoofing.cpp
)

target_include_directories(face_liveness PRIVATE
  ${CMAKE_CURRENT_SOURCE_DIR}
  ${CMAKE_CURRENT_SOURCE_DIR}/core/include
  "${NCNN_ROOT}/${ANDROID_ABI}/include"   # for <ncnn/net.h>
)

target_compile_definitions(face_liveness PUBLIC DART_SHARED_LIB)
target_link_libraries(face_liveness PRIVATE ncnn)

if(ANDROID)
  # 16 KB page size support (required for Android 15+ devices on Google Play).
  target_link_options(face_liveness PRIVATE "-Wl,-z,max-page-size=16384")
endif()
