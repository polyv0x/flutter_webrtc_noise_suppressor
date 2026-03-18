#ifndef FLUTTER_WEBRTC_NOISE_SUPPRESSOR_PLUGIN_HXX
#define FLUTTER_WEBRTC_NOISE_SUPPRESSOR_PLUGIN_HXX

#include <flutter_linux/flutter_linux.h>

G_BEGIN_DECLS

#ifdef FLUTTER_PLUGIN_IMPL
#define FLUTTER_PLUGIN_EXPORT __attribute__((visibility("default")))
#else
#define FLUTTER_PLUGIN_EXPORT
#endif

typedef struct _FlutterWebrtcNoiseSuppressorPlugin
    FlutterWebrtcNoiseSuppressorPlugin;
typedef struct {
  GObjectClass parent_class;
} FlutterWebrtcNoiseSuppressorPluginClass;

FLUTTER_PLUGIN_EXPORT GType
flutter_webrtc_noise_suppressor_plugin_get_type();

FLUTTER_PLUGIN_EXPORT void
flutter_webrtc_noise_suppressor_plugin_register_with_registrar(
    FlPluginRegistrar* registrar);

G_END_DECLS

#endif  // FLUTTER_WEBRTC_NOISE_SUPPRESSOR_PLUGIN_HXX
