import 'package:plugin_platform_interface/plugin_platform_interface.dart';

import 'noise_processing_mode.dart';
import 'noise_suppressor_method_channel.dart';

/// The interface that implementations of flutter_webrtc_noise_suppressor must
/// implement.
///
/// Platform implementations should extend this class rather than implement it,
/// as extending preserves default method implementations through inheritance.
abstract class NoiseSuppressorPlatform extends PlatformInterface {
  /// Constructs a NoiseSuppressorPlatform.
  NoiseSuppressorPlatform() : super(token: _token);

  static final Object _token = Object();

  static NoiseSuppressorPlatform _instance = MethodChannelNoiseSuppressor();

  /// The default instance of [NoiseSuppressorPlatform] to use.
  ///
  /// Defaults to [MethodChannelNoiseSuppressor].
  static NoiseSuppressorPlatform get instance => _instance;

  /// Platform-specific implementations should set this with their own
  /// platform-specific class that extends [NoiseSuppressorPlatform] when
  /// they register themselves.
  static set instance(NoiseSuppressorPlatform instance) {
    PlatformInterface.verifyToken(instance, _token);
    _instance = instance;
  }

  /// Initializes the noise suppressor and registers the audio processor with
  /// flutter_webrtc. Must be called once before any other method.
  Future<void> initialize() {
    throw UnimplementedError('initialize() has not been implemented.');
  }

  /// Unregisters the audio processor from flutter_webrtc and releases all
  /// native resources.
  Future<void> dispose() {
    throw UnimplementedError('dispose() has not been implemented.');
  }

  /// Sets the active noise processing mode.
  ///
  /// Modes that are not yet implemented fall back gracefully:
  /// - [NoiseProcessingMode.vadGate] falls back to [NoiseProcessingMode.rmsGate]
  /// - [NoiseProcessingMode.denoise] and [NoiseProcessingMode.hybrid] fall
  ///   back to [NoiseProcessingMode.disabled]
  Future<void> setMode(NoiseProcessingMode mode) {
    throw UnimplementedError('setMode() has not been implemented.');
  }

  /// Configures RMS gate and smoothing parameters.
  ///
  /// All parameters are optional; only supplied values are updated.
  ///
  /// Parameters:
  /// - [threshold]: RMS energy threshold in normalised float range [0, 1].
  ///   Default: 0.02.
  /// - [holdMs]: After the signal falls below [threshold], keep the gate open
  ///   for this many milliseconds before closing. Default: 200.
  /// - [residualGain]: Gain applied to output when the gate is closed.
  ///   0.0 = full silence, 0.05 = light attenuation. Default: 0.05.
  /// - [vadThreshold]: Voice activity score threshold for [NoiseProcessingMode.vadGate].
  ///   Reserved for future use. Default: 0.5.
  /// - [attackMs]: Gain smoothing time constant (opening). Default: 5.0.
  /// - [releaseMs]: Gain smoothing time constant (closing). Default: 80.0.
  Future<void> configure({
    double? threshold,
    int? holdMs,
    double? residualGain,
    double? vadThreshold,
    double? attackMs,
    double? releaseMs,
  }) {
    throw UnimplementedError('configure() has not been implemented.');
  }
}
