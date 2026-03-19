#include "flutter_webrtc_noise_suppressor/flutter_webrtc_noise_suppressor_plugin.h"

#include <flutter_linux/flutter_linux.h>
#include <gtk/gtk.h>

// flutter_webrtc's public C API for registering a custom audio processor.
// This header is provided by the flutter_webrtc_plugin target.
#include "flutter_webrtc/flutter_webrtc_audio_processing.h"

#include "noise_suppressor_processor.h"

#include <atomic>
#include <cmath>
#include <memory>
#include <cstring>
#include <thread>

// PulseAudio simple API — used to capture raw pre-APM audio for level
// metering and gate decisions, bypassing WebRTC's GainController2.
#include <pulse/simple.h>
#include <pulse/error.h>

#define FLUTTER_WEBRTC_NOISE_SUPPRESSOR_PLUGIN(obj)                          \
  (G_TYPE_CHECK_INSTANCE_CAST((obj),                                         \
                               flutter_webrtc_noise_suppressor_plugin_get_type(), \
                               FlutterWebrtcNoiseSuppressorPlugin))

// ---------------------------------------------------------------------------
// Processor singleton — lives for the duration of the plugin registration.
// ---------------------------------------------------------------------------
static noise_suppressor::NoiseSuppressorProcessor* g_processor = nullptr;

// ---------------------------------------------------------------------------
// PulseAudio pre-APM level monitor thread
//
// WebRTC's APM runs GainController2 before our SetCapturePostProcessing hook,
// normalising the signal to near 1.0 regardless of actual loudness. To give
// the noise gate (and level meter) access to the raw signal, we open a
// separate low-latency PulseAudio stream from the default input source.
// The computed RMS is injected into the processor via SetExternalLevel() so
// both the meter display and the gate threshold comparison use pre-AGC values.
// ---------------------------------------------------------------------------

static std::thread             g_pa_thread;
static std::atomic<bool>       g_pa_running{false};

static void pa_monitor_thread_func() {
  const pa_sample_spec ss = {
      PA_SAMPLE_FLOAT32NE,
      16000,   // 16 kHz — more than enough for level metering
      1        // mono
  };

  // Request a small buffer (~20 ms) so the thread responds quickly to stop.
  const pa_buffer_attr ba = {
      static_cast<uint32_t>(-1),  // maxlength — let server choose
      static_cast<uint32_t>(-1),  // tlength    (playback only)
      static_cast<uint32_t>(-1),  // prebuf     (playback only)
      static_cast<uint32_t>(-1),  // minreq     (playback only)
      static_cast<uint32_t>(16000 / 50 * sizeof(float)),  // fragsize: 20 ms
  };

  int error = 0;
  pa_simple* pa = pa_simple_new(
      nullptr,                              // default PA server
      "flutter_webrtc_noise_suppressor",    // application name
      PA_STREAM_RECORD,
      nullptr,                              // default source (same as WebRTC)
      "noise gate level monitor",
      &ss,
      nullptr,                              // default channel map
      &ba,
      &error);

  if (!pa) {
    // PulseAudio unavailable — gate and meter fall back to post-APM level.
    return;
  }

  // 20 ms frames at 16 kHz = 320 samples.
  constexpr int kFrameSamples = 320;
  float buf[kFrameSamples];

  while (g_pa_running.load(std::memory_order_relaxed)) {
    if (pa_simple_read(pa, buf, sizeof(buf), &error) < 0) break;

    float sum_sq = 0.0f;
    for (int i = 0; i < kFrameSamples; ++i) sum_sq += buf[i] * buf[i];
    const float rms = std::sqrt(sum_sq / kFrameSamples);

    if (g_processor != nullptr) {
      g_processor->SetExternalLevel(rms);
    }
  }

  pa_simple_free(pa);
}

static void start_pa_monitor() {
  if (g_pa_running.exchange(true)) return;  // already running
  g_pa_thread = std::thread(pa_monitor_thread_func);
}

static void stop_pa_monitor() {
  g_pa_running.store(false, std::memory_order_relaxed);
  if (g_pa_thread.joinable()) g_pa_thread.join();
  if (g_processor != nullptr) g_processor->SetExternalLevel(-1.0f);
}

// ---------------------------------------------------------------------------
// GObject plugin type
// ---------------------------------------------------------------------------

struct _FlutterWebrtcNoiseSuppressorPlugin {
  GObject parent_instance;
};

G_DEFINE_TYPE(FlutterWebrtcNoiseSuppressorPlugin,
              flutter_webrtc_noise_suppressor_plugin,
              G_TYPE_OBJECT)


// Forward declarations
static void flutter_webrtc_noise_suppressor_plugin_handle_method_call(
    FlutterWebrtcNoiseSuppressorPlugin* self,
    FlMethodCall*                       method_call);

// ---------------------------------------------------------------------------
// Method call handler
// ---------------------------------------------------------------------------

static void method_call_cb(FlMethodChannel* channel,
                            FlMethodCall*    method_call,
                            gpointer         user_data) {
  FlutterWebrtcNoiseSuppressorPlugin* plugin =
      FLUTTER_WEBRTC_NOISE_SUPPRESSOR_PLUGIN(user_data);
  flutter_webrtc_noise_suppressor_plugin_handle_method_call(plugin,
                                                             method_call);
}

static void flutter_webrtc_noise_suppressor_plugin_handle_method_call(
    FlutterWebrtcNoiseSuppressorPlugin* self,
    FlMethodCall*                       method_call) {
  g_autoptr(FlMethodResponse) response = nullptr;
  const gchar* method = fl_method_call_get_name(method_call);

  if (strcmp(method, "initialize") == 0) {
    // Create processor if it does not already exist.
    if (g_processor == nullptr) {
      g_processor = new noise_suppressor::NoiseSuppressorProcessor();
    }

    // Register the processor with flutter_webrtc's audio processing pipeline.
    flutter_webrtc_add_audio_processor(g_processor);

    // Start the PulseAudio pre-APM level monitor thread.
    start_pa_monitor();

    response = FL_METHOD_RESPONSE(fl_method_success_response_new(nullptr));

  } else if (strcmp(method, "dispose") == 0) {
    if (g_processor == nullptr) {
      response = FL_METHOD_RESPONSE(fl_method_error_response_new(
          "NOT_INITIALIZED",
          "dispose() called before initialize()",
          nullptr));
    } else {
      stop_pa_monitor();
      flutter_webrtc_remove_audio_processor(g_processor);
      delete g_processor;
      g_processor = nullptr;
      response = FL_METHOD_RESPONSE(fl_method_success_response_new(nullptr));
    }

  } else if (strcmp(method, "setMode") == 0) {
    if (g_processor == nullptr) {
      response = FL_METHOD_RESPONSE(fl_method_error_response_new(
          "NOT_INITIALIZED",
          "setMode() called before initialize()",
          nullptr));
    } else {
      FlValue* args = fl_method_call_get_args(method_call);
      FlValue* mode_val = fl_value_lookup_string(args, "mode");
      if (mode_val == nullptr ||
          fl_value_get_type(mode_val) != FL_VALUE_TYPE_INT) {
        response = FL_METHOD_RESPONSE(fl_method_error_response_new(
            "INVALID_ARGUMENT", "mode must be an integer", nullptr));
      } else {
        int mode = static_cast<int>(fl_value_get_int(mode_val));
        g_processor->SetMode(mode);
        response =
            FL_METHOD_RESPONSE(fl_method_success_response_new(nullptr));
      }
    }

  } else if (strcmp(method, "configure") == 0) {
    if (g_processor == nullptr) {
      response = FL_METHOD_RESPONSE(fl_method_error_response_new(
          "NOT_INITIALIZED",
          "configure() called before initialize()",
          nullptr));
    } else {
      FlValue* args = fl_method_call_get_args(method_call);

      FlValue* v;

      if ((v = fl_value_lookup_string(args, "threshold")) != nullptr &&
          fl_value_get_type(v) == FL_VALUE_TYPE_FLOAT) {
        g_processor->SetThreshold(
            static_cast<float>(fl_value_get_float(v)));
      }

      if ((v = fl_value_lookup_string(args, "holdMs")) != nullptr &&
          fl_value_get_type(v) == FL_VALUE_TYPE_INT) {
        g_processor->SetHoldMs(
            static_cast<int>(fl_value_get_int(v)));
      }

      if ((v = fl_value_lookup_string(args, "residualGain")) != nullptr &&
          fl_value_get_type(v) == FL_VALUE_TYPE_FLOAT) {
        g_processor->SetResidualGain(
            static_cast<float>(fl_value_get_float(v)));
      }

      if ((v = fl_value_lookup_string(args, "attackMs")) != nullptr &&
          fl_value_get_type(v) == FL_VALUE_TYPE_FLOAT) {
        g_processor->SetAttackMs(
            static_cast<float>(fl_value_get_float(v)));
      }

      if ((v = fl_value_lookup_string(args, "releaseMs")) != nullptr &&
          fl_value_get_type(v) == FL_VALUE_TYPE_FLOAT) {
        g_processor->SetReleaseMs(
            static_cast<float>(fl_value_get_float(v)));
      }

      // vadThreshold is accepted but reserved for future VAD mode.
      // (no-op in Phase 1)

      response =
          FL_METHOD_RESPONSE(fl_method_success_response_new(nullptr));
    }

  } else if (strcmp(method, "getAudioLevel") == 0) {
    float level = g_processor != nullptr ? g_processor->GetAudioLevel() : 0.0f;
    response = FL_METHOD_RESPONSE(
        fl_method_success_response_new(fl_value_new_float(level)));

  } else {
    response = FL_METHOD_RESPONSE(fl_method_not_implemented_response_new());
  }

  g_autoptr(GError) error = nullptr;
  if (!fl_method_call_respond(method_call, response, &error)) {
    g_warning("Failed to send method response: %s", error->message);
  }
}

// ---------------------------------------------------------------------------
// GObject lifecycle
// ---------------------------------------------------------------------------

static void flutter_webrtc_noise_suppressor_plugin_dispose(GObject* object) {
  G_OBJECT_CLASS(
      flutter_webrtc_noise_suppressor_plugin_parent_class)->dispose(object);
}

static void flutter_webrtc_noise_suppressor_plugin_class_init(
    FlutterWebrtcNoiseSuppressorPluginClass* klass) {
  G_OBJECT_CLASS(klass)->dispose =
      flutter_webrtc_noise_suppressor_plugin_dispose;
}

static void flutter_webrtc_noise_suppressor_plugin_init(
    FlutterWebrtcNoiseSuppressorPlugin* self) {}

// ---------------------------------------------------------------------------
// Public registration entry point (called by Flutter engine)
// ---------------------------------------------------------------------------

void flutter_webrtc_noise_suppressor_plugin_register_with_registrar(
    FlPluginRegistrar* registrar) {
  FlutterWebrtcNoiseSuppressorPlugin* plugin =
      FLUTTER_WEBRTC_NOISE_SUPPRESSOR_PLUGIN(g_object_new(
          flutter_webrtc_noise_suppressor_plugin_get_type(), nullptr));

  g_autoptr(FlStandardMethodCodec) codec = fl_standard_method_codec_new();
  g_autoptr(FlMethodChannel) channel =
      fl_method_channel_new(fl_plugin_registrar_get_messenger(registrar),
                            "flutter_webrtc_noise_suppressor",
                            FL_METHOD_CODEC(codec));
  fl_method_channel_set_method_call_handler(
      channel, method_call_cb, g_object_ref(plugin), g_object_unref);

  g_object_unref(plugin);
}
