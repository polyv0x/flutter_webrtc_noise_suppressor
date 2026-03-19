cmake_minimum_required(VERSION 3.10)
set(PROJECT_NAME "flutter_webrtc_noise_suppressor")
project(${PROJECT_NAME} LANGUAGES CXX)
set(CMAKE_CXX_STANDARD 17)

set(PLUGIN_NAME "${PROJECT_NAME}_plugin")

add_library(${PLUGIN_NAME} SHARED
  "flutter_webrtc_noise_suppressor_plugin.cc"
  "../src/noise_suppressor_processor.cc"
)

apply_standard_settings(${PLUGIN_NAME})
target_compile_definitions(${PLUGIN_NAME} PRIVATE FLUTTER_PLUGIN_IMPL)
set_target_properties(${PLUGIN_NAME} PROPERTIES CXX_VISIBILITY_PRESET hidden)

target_include_directories(${PLUGIN_NAME} PRIVATE
  "${CMAKE_CURRENT_SOURCE_DIR}"
  "${CMAKE_CURRENT_SOURCE_DIR}/../src"
)

target_include_directories(${PLUGIN_NAME} INTERFACE
  "${CMAKE_CURRENT_SOURCE_DIR}"
)

# flutter_webrtc_plugin provides:
#   - flutter_webrtc/flutter_webrtc_audio_processing.h (the registration API)
#   - libwebrtc headers transitively (rtc_audio_processing.h etc.)
# GTK is required by flutter_linux.
# libpulse-simple is used for pre-APM audio level monitoring, bypassing
# WebRTC's GainController2 so the noise gate sees the raw mic level.
find_package(PkgConfig REQUIRED)
pkg_check_modules(LIBPULSE REQUIRED libpulse-simple)

target_include_directories(${PLUGIN_NAME} PRIVATE ${LIBPULSE_INCLUDE_DIRS})

target_link_libraries(${PLUGIN_NAME} PRIVATE
  flutter
  PkgConfig::GTK
  flutter_webrtc_plugin
  ${LIBPULSE_LIBRARIES}
)
