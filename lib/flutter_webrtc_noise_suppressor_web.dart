/// Web implementation of flutter_webrtc_noise_suppressor.
///
/// This is intentionally a no-op. Modern browsers implement noise suppression
/// natively via the `noiseSuppression` MediaTrackConstraint in getUserMedia:
///
///   navigator.mediaDevices.getUserMedia({
///     audio: { noiseSuppression: true }
///   });
///
/// flutter_webrtc enables this constraint by default on Web, so no additional
/// processing is needed at the plugin level. All methods return immediately
/// without error so that cross-platform code compiles and runs unchanged.
library flutter_webrtc_noise_suppressor_web;

import 'package:flutter_web_plugins/flutter_web_plugins.dart';

import 'src/noise_processing_mode.dart';
import 'src/noise_suppressor_platform_interface.dart';

/// Web implementation of [NoiseSuppressorPlatform].
///
/// All methods are no-ops — the browser handles noise suppression natively.
class NoiseSuppressorWeb extends NoiseSuppressorPlatform {
  /// Registers this class as the default instance of [NoiseSuppressorPlatform]
  /// when running on the web.
  static void registerWith(Registrar registrar) {
    NoiseSuppressorPlatform.instance = NoiseSuppressorWeb();
  }

  /// No-op on web. Browsers apply noise suppression natively.
  @override
  Future<void> initialize() async {}

  /// No-op on web.
  @override
  Future<void> dispose() async {}

  /// No-op on web. Mode changes are silently accepted but have no effect.
  @override
  Future<void> setMode(NoiseProcessingMode mode) async {}

  /// No-op on web. Configuration values are silently accepted but have no
  /// effect; browser noise suppression is not tunable via this API.
  @override
  Future<void> configure({
    double? threshold,
    int? holdMs,
    double? residualGain,
    double? vadThreshold,
    double? attackMs,
    double? releaseMs,
  }) async {}
}
