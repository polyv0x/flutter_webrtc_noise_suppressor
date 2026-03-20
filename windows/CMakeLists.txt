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

target_compile_definitions(${PLUGIN_NAME} PRIVATE
  FLUTTER_PLUGIN_IMPL
  # Required by libwebrtc on Windows to use the correct DLL import attributes.
  LIB_WEBRTC_API_DLL
  # Prevent windows.h from defining min/max macros that clash with std::min/std::max.
  NOMINMAX
)

target_include_directories(${PLUGIN_NAME} PRIVATE
  "${CMAKE_CURRENT_SOURCE_DIR}"
  "${CMAKE_CURRENT_SOURCE_DIR}/../src"
)

# flutter_webrtc_plugin provides:
#   - flutter_webrtc/flutter_webrtc_audio_processing.h
#   - libwebrtc headers transitively
# flutter_wrapper_plugin is the C++ wrapper for the Flutter desktop plugin API.
target_link_libraries(${PLUGIN_NAME} PRIVATE
  flutter
  flutter_wrapper_plugin
  flutter_webrtc_plugin
)

# Generate the .def file so the DLL exports the public registration symbol.
set_target_properties(${PLUGIN_NAME} PROPERTIES
  WINDOWS_EXPORT_ALL_SYMBOLS OFF
)

# Explicit export definition so only the public entry point is exported.
file(WRITE "${CMAKE_CURRENT_BINARY_DIR}/${PLUGIN_NAME}.def"
  "EXPORTS\n"
  "  FlutterWebrtcNoiseSuppressorPluginRegisterWithRegistrar\n"
)
set_target_properties(${PLUGIN_NAME} PROPERTIES
  LINK_FLAGS "/DEF:\"${CMAKE_CURRENT_BINARY_DIR}/${PLUGIN_NAME}.def\""
)
