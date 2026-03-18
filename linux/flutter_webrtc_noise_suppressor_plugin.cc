#include "flutter_webrtc_noise_suppressor/flutter_webrtc_noise_suppressor_plugin.h"

#include <flutter_linux/flutter_linux.h>
#include <gtk/gtk.h>

// flutter_webrtc's public C API for registering a custom audio processor.
// This header is provided by the flutter_webrtc_plugin target.
#include "flutter_webrtc/flutter_webrtc_audio_processing.h"

#include "noise_suppressor_processor.h"

#include <memory>
#include <cstring>

#define FLUTTER_WEBRTC_NOISE_SUPPRESSOR_PLUGIN(obj)                          \
  (G_TYPE_CHECK_INSTANCE_CAST((obj),                                         \
                               flutter_webrtc_noise_suppressor_plugin_get_type(), \
                               FlutterWebrtcNoiseSuppressorPlugin))

// ---------------------------------------------------------------------------
// Processor singleton — lives for the duration of the plugin registration.
// ---------------------------------------------------------------------------
static noise_suppressor::NoiseSuppressorProcessor* g_processor = nullptr;

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
    // flutter_webrtc_add_audio_processor is declared in
    // flutter_webrtc/flutter_webrtc_audio_processing.h and provided by
    // libflutter_webrtc_plugin.so.
    flutter_webrtc_add_audio_processor(g_processor);

    response = FL_METHOD_RESPONSE(fl_method_success_response_new(nullptr));

  } else if (strcmp(method, "dispose") == 0) {
    if (g_processor == nullptr) {
      response = FL_METHOD_RESPONSE(fl_method_error_response_new(
          "NOT_INITIALIZED",
          "dispose() called before initialize()",
          nullptr));
    } else {
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
