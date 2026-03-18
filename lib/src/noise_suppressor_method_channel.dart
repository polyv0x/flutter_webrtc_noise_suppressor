import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'noise_processing_mode.dart';
import 'noise_suppressor_platform_interface.dart';

/// The method channel implementation of [NoiseSuppressorPlatform].
class MethodChannelNoiseSuppressor extends NoiseSuppressorPlatform {
  /// The method channel used to communicate with the native plugin.
  @visibleForTesting
  final methodChannel =
      const MethodChannel('flutter_webrtc_noise_suppressor');

  @override
  Future<void> initialize() async {
    await methodChannel.invokeMethod<void>('initialize');
  }

  @override
  Future<void> dispose() async {
    await methodChannel.invokeMethod<void>('dispose');
  }

  @override
  Future<void> setMode(NoiseProcessingMode mode) async {
    await methodChannel.invokeMethod<void>('setMode', {
      'mode': mode.index,
    });
  }

  @override
  Future<void> configure({
    double? threshold,
    int? holdMs,
    double? residualGain,
    double? vadThreshold,
    double? attackMs,
    double? releaseMs,
  }) async {
    final args = <String, dynamic>{};
    if (threshold != null) args['threshold'] = threshold;
    if (holdMs != null) args['holdMs'] = holdMs;
    if (residualGain != null) args['residualGain'] = residualGain;
    if (vadThreshold != null) args['vadThreshold'] = vadThreshold;
    if (attackMs != null) args['attackMs'] = attackMs;
    if (releaseMs != null) args['releaseMs'] = releaseMs;

    if (args.isNotEmpty) {
      await methodChannel.invokeMethod<void>('configure', args);
    }
  }

  @override
  Future<double> getAudioLevel() async {
    final result = await methodChannel.invokeMethod<double>('getAudioLevel');
    return result ?? 0.0;
  }
}
