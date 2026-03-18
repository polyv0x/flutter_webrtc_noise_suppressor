#include "flutter_webrtc/flutter_webrtc_noise_suppressor_plugin.h"

// Must be included before any system headers that pull in windows.h,
// so that NOMINMAX etc. are defined first.
#include <windows.h>

#include <flutter/method_channel.h>
#include <flutter/plugin_registrar_windows.h>
#include <flutter/standard_method_codec.h>

// flutter_webrtc's public C++ API for registering a custom audio processor.
// Provided by flutter_webrtc_plugin.dll / flutter_webrtc_plugin.lib.
#include "flutter_webrtc/flutter_webrtc_audio_processing.h"

#include "noise_suppressor_processor.h"

#include <memory>
#include <optional>
#include <string>

namespace {

using flutter::EncodableMap;
using flutter::EncodableValue;
using flutter::MethodCall;
using flutter::MethodResult;

// ---------------------------------------------------------------------------
// Processor singleton
// ---------------------------------------------------------------------------
static noise_suppressor::NoiseSuppressorProcessor* g_processor = nullptr;

// ---------------------------------------------------------------------------
// Plugin class
// ---------------------------------------------------------------------------

class FlutterWebrtcNoiseSuppressorPlugin : public flutter::Plugin {
 public:
  static void RegisterWithRegistrar(flutter::PluginRegistrarWindows* registrar);

  FlutterWebrtcNoiseSuppressorPlugin();
  ~FlutterWebrtcNoiseSuppressorPlugin() override;

  // Disallow copy and assign.
  FlutterWebrtcNoiseSuppressorPlugin(
      const FlutterWebrtcNoiseSuppressorPlugin&) = delete;
  FlutterWebrtcNoiseSuppressorPlugin& operator=(
      const FlutterWebrtcNoiseSuppressorPlugin&) = delete;

 private:
  void HandleMethodCall(
      const MethodCall<EncodableValue>& method_call,
      std::unique_ptr<MethodResult<EncodableValue>> result);
};

// ---------------------------------------------------------------------------
// RegisterWithRegistrar
// ---------------------------------------------------------------------------

void FlutterWebrtcNoiseSuppressorPlugin::RegisterWithRegistrar(
    flutter::PluginRegistrarWindows* registrar) {
  auto channel = std::make_unique<flutter::MethodChannel<EncodableValue>>(
      registrar->messenger(),
      "flutter_webrtc_noise_suppressor",
      &flutter::StandardMethodCodec::GetInstance());

  auto plugin = std::make_unique<FlutterWebrtcNoiseSuppressorPlugin>();

  channel->SetMethodCallHandler(
      [plugin_ptr = plugin.get()](const auto& call, auto result) {
        plugin_ptr->HandleMethodCall(call, std::move(result));
      });

  registrar->AddPlugin(std::move(plugin));
}

// ---------------------------------------------------------------------------
// Constructor / Destructor
// ---------------------------------------------------------------------------

FlutterWebrtcNoiseSuppressorPlugin::FlutterWebrtcNoiseSuppressorPlugin() =
    default;
FlutterWebrtcNoiseSuppressorPlugin::~FlutterWebrtcNoiseSuppressorPlugin() =
    default;

// ---------------------------------------------------------------------------
// HandleMethodCall
// ---------------------------------------------------------------------------

void FlutterWebrtcNoiseSuppressorPlugin::HandleMethodCall(
    const MethodCall<EncodableValue>& method_call,
    std::unique_ptr<MethodResult<EncodableValue>> result) {
  const std::string& method = method_call.method_name();

  if (method == "initialize") {
    if (g_processor == nullptr) {
      g_processor = new noise_suppressor::NoiseSuppressorProcessor();
    }
    flutter_webrtc_add_audio_processor(g_processor);
    result->Success();

  } else if (method == "dispose") {
    if (g_processor == nullptr) {
      result->Error("NOT_INITIALIZED", "dispose() called before initialize()");
      return;
    }
    flutter_webrtc_remove_audio_processor(g_processor);
    delete g_processor;
    g_processor = nullptr;
    result->Success();

  } else if (method == "setMode") {
    if (g_processor == nullptr) {
      result->Error("NOT_INITIALIZED", "setMode() called before initialize()");
      return;
    }
    const auto* args = std::get_if<EncodableMap>(method_call.arguments());
    if (!args) {
      result->Error("INVALID_ARGUMENT", "arguments must be a map");
      return;
    }
    auto it = args->find(EncodableValue("mode"));
    if (it == args->end()) {
      result->Error("INVALID_ARGUMENT", "missing required argument: mode");
      return;
    }
    const int* mode_ptr = std::get_if<int>(&it->second);
    if (!mode_ptr) {
      result->Error("INVALID_ARGUMENT", "mode must be an integer");
      return;
    }
    g_processor->SetMode(*mode_ptr);
    result->Success();

  } else if (method == "configure") {
    if (g_processor == nullptr) {
      result->Error("NOT_INITIALIZED",
                    "configure() called before initialize()");
      return;
    }
    const auto* args = std::get_if<EncodableMap>(method_call.arguments());
    if (!args) {
      result->Error("INVALID_ARGUMENT", "arguments must be a map");
      return;
    }

    auto get_double = [&](const char* key) -> std::optional<double> {
      auto it = args->find(EncodableValue(key));
      if (it == args->end()) return std::nullopt;
      if (const double* v = std::get_if<double>(&it->second)) return *v;
      return std::nullopt;
    };

    auto get_int = [&](const char* key) -> std::optional<int> {
      auto it = args->find(EncodableValue(key));
      if (it == args->end()) return std::nullopt;
      if (const int* v = std::get_if<int>(&it->second)) return *v;
      return std::nullopt;
    };

    if (auto v = get_double("threshold"))
      g_processor->SetThreshold(static_cast<float>(*v));
    if (auto v = get_int("holdMs"))
      g_processor->SetHoldMs(*v);
    if (auto v = get_double("residualGain"))
      g_processor->SetResidualGain(static_cast<float>(*v));
    if (auto v = get_double("attackMs"))
      g_processor->SetAttackMs(static_cast<float>(*v));
    if (auto v = get_double("releaseMs"))
      g_processor->SetReleaseMs(static_cast<float>(*v));
    // vadThreshold is accepted but reserved for future VAD mode (no-op in Phase 1).

    result->Success();

  } else if (method == "getAudioLevel") {
    float level = g_processor != nullptr ? g_processor->GetAudioLevel() : 0.0f;
    result->Success(EncodableValue(static_cast<double>(level)));

  } else {
    result->NotImplemented();
  }
}

}  // namespace

// ---------------------------------------------------------------------------
// Public DLL entry point (called by Flutter engine)
// ---------------------------------------------------------------------------

void FlutterWebrtcNoiseSuppressorPluginRegisterWithRegistrar(
    FlutterDesktopPluginRegistrarRef registrar) {
  FlutterWebrtcNoiseSuppressorPlugin::RegisterWithRegistrar(
      flutter::PluginRegistrarManager::GetInstance()
          ->GetRegistrar<flutter::PluginRegistrarWindows>(registrar));
}
