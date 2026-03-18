import 'noise_processing_mode.dart';
import 'noise_suppressor_platform_interface.dart';

export 'noise_processing_mode.dart';

/// Controls a real-time audio noise suppressor integrated into flutter_webrtc's
/// capture pipeline.
///
/// Usage:
/// ```dart
/// await NoiseSuppressor.initialize();
/// await NoiseSuppressor.setMode(NoiseProcessingMode.rmsGate);
/// await NoiseSuppressor.configure(threshold: 0.015, holdMs: 150);
///
/// // ... when done:
/// await NoiseSuppressor.dispose();
/// ```
///
/// Phase 1 supports [NoiseProcessingMode.disabled] and
/// [NoiseProcessingMode.rmsGate]. All other modes fall back gracefully until
/// ONNX Runtime integration lands in a future release.
class NoiseSuppressor {
  NoiseSuppressor._();

  /// Initialises the native audio processor and registers it with
  /// flutter_webrtc's audio processing pipeline.
  ///
  /// Must be called once, after the flutter_webrtc plugin has been loaded and
  /// before creating any [RTCPeerConnection]. Calling this more than once is a
  /// no-op on most platforms.
  static Future<void> initialize() {
    return NoiseSuppressorPlatform.instance.initialize();
  }

  /// Unregisters the audio processor from flutter_webrtc and releases all
  /// native resources.
  ///
  /// After calling this, [initialize] must be called again before the
  /// suppressor will be active.
  static Future<void> dispose() {
    return NoiseSuppressorPlatform.instance.dispose();
  }

  /// Sets the active noise processing mode.
  ///
  /// Safe to call at any time, including during an active call. The change
  /// takes effect on the next audio frame processed by the native pipeline.
  ///
  /// Modes that are not yet implemented fall back gracefully:
  /// - [NoiseProcessingMode.vadGate] → [NoiseProcessingMode.rmsGate]
  /// - [NoiseProcessingMode.denoise] → [NoiseProcessingMode.disabled]
  /// - [NoiseProcessingMode.hybrid]  → [NoiseProcessingMode.disabled]
  static Future<void> setMode(NoiseProcessingMode mode) {
    return NoiseSuppressorPlatform.instance.setMode(mode);
  }

  /// Configures RMS gate and smoothing parameters.
  ///
  /// All parameters are optional; omitted values retain their current setting.
  /// Safe to call at any time, including during an active call.
  ///
  /// Parameters:
  /// - [threshold]: RMS energy threshold in normalised float range [0, 1].
  ///   Frames with RMS below this value are treated as silence.
  ///   Default: `0.02`.
  /// - [holdMs]: After the signal falls below [threshold], keep the gate open
  ///   for this many milliseconds before beginning to close.
  ///   Default: `200`.
  /// - [residualGain]: Gain multiplier applied to the output when the gate is
  ///   closed. `0.0` produces full silence; `1.0` disables attenuation.
  ///   Default: `0.05`.
  /// - [vadThreshold]: Voice activity score threshold used by
  ///   [NoiseProcessingMode.vadGate]. Reserved for future use.
  ///   Default: `0.5`.
  /// - [attackMs]: IIR smoothing time constant for the gate-opening transition
  ///   (gain rising). Smaller values = faster open.
  ///   Default: `5.0`.
  /// - [releaseMs]: IIR smoothing time constant for the gate-closing
  ///   transition (gain falling). Smaller values = faster close.
  ///   Default: `80.0`.
  static Future<void> configure({
    double? threshold,
    int? holdMs,
    double? residualGain,
    double? vadThreshold,
    double? attackMs,
    double? releaseMs,
  }) {
    return NoiseSuppressorPlatform.instance.configure(
      threshold: threshold,
      holdMs: holdMs,
      residualGain: residualGain,
      vadThreshold: vadThreshold,
      attackMs: attackMs,
      releaseMs: releaseMs,
    );
  }

  /// Returns the RMS level of the most recently processed audio frame in
  /// normalised float range [0, 1]. Returns 0.0 if no audio has been
  /// processed yet or if the suppressor is not initialized.
  static Future<double> getAudioLevel() {
    return NoiseSuppressorPlatform.instance.getAudioLevel();
  }
}
