enum NoiseProcessingMode {
  /// Pass audio through unchanged.
  disabled,

  /// Simple RMS energy threshold gate. Zero dependency, lowest CPU.
  /// Best for: quiet environments, low-end hardware.
  rmsGate,

  /// Silero VAD-based gate. No denoising, but accurate voice detection.
  /// Best for: moderate noise, battery-sensitive devices.
  /// Requires ONNX Runtime. [Not yet implemented — falls back to rmsGate]
  vadGate,

  /// DeepFilterNet3 always-on denoising. No VAD gating.
  /// Best for: consistent background noise (fans, HVAC).
  /// Requires ONNX Runtime. [Not yet implemented — falls back to disabled]
  denoise,

  /// Silero VAD + DeepFilterNet3 hybrid. Recommended for gaming/office.
  /// VAD controls output gain; DFN3 runs concurrently for denoising.
  /// Requires ONNX Runtime. [Not yet implemented — falls back to disabled]
  hybrid,
}
