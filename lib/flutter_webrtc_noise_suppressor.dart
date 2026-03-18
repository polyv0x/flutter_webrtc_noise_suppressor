/// flutter_webrtc_noise_suppressor
///
/// Real-time noise suppression for flutter_webrtc. Registers a custom audio
/// processor in flutter_webrtc's capture pipeline on Linux, Windows, Android,
/// and iOS.
///
/// Phase 1 supports [NoiseProcessingMode.disabled] and
/// [NoiseProcessingMode.rmsGate]. Future phases will add Silero VAD gating
/// and DeepFilterNet3 AI denoising via ONNX Runtime.
///
/// Quick start:
/// ```dart
/// import 'package:flutter_webrtc_noise_suppressor/flutter_webrtc_noise_suppressor.dart';
///
/// // Call once, before creating any RTCPeerConnection.
/// await NoiseSuppressor.initialize();
/// await NoiseSuppressor.setMode(NoiseProcessingMode.rmsGate);
///
/// // Optionally tune the gate:
/// await NoiseSuppressor.configure(threshold: 0.015, holdMs: 150, releaseMs: 60);
/// ```
library flutter_webrtc_noise_suppressor;

export 'src/noise_processing_mode.dart';
export 'src/noise_suppressor.dart';
export 'src/noise_suppressor_platform_interface.dart';
