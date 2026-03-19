#pragma once

#include <atomic>
#include <cmath>
#include <cstring>
#include <mutex>

#include "rtc_audio_processing.h"

namespace noise_suppressor {

/// Mirrors the Dart-side NoiseProcessingMode enum.
/// Keep values in sync with lib/src/noise_processing_mode.dart.
enum class NoiseProcessingMode : int {
  kDisabled = 0,  ///< Pass audio through unchanged.
  kRmsGate  = 1,  ///< Simple RMS energy threshold gate.
  kVadGate  = 2,  ///< Silero VAD gate (not yet implemented — falls back to kRmsGate).
  kDenoise  = 3,  ///< DeepFilterNet3 denoising (not yet implemented — falls back to kDisabled).
  kHybrid   = 4,  ///< VAD + DFN3 hybrid (not yet implemented — falls back to kDisabled).
};

/// Audio processor that is registered with flutter_webrtc's
/// AudioProcessingAdapter. All public setter methods are thread-safe and may
/// be called from the Flutter/Dart thread while Process() runs on the audio
/// thread.
///
/// Real-time constraints for Process():
///   - No heap allocation.
///   - No locks (atomics only).
///   - No Flutter task-runner calls.
class NoiseSuppressorProcessor
    : public libwebrtc::RTCAudioProcessing::CustomProcessing {
 public:
  NoiseSuppressorProcessor();
  ~NoiseSuppressorProcessor() override;

  // -------------------------------------------------------------------------
  // libwebrtc::RTCAudioProcessing::CustomProcessing overrides
  // -------------------------------------------------------------------------

  /// Called once when the audio pipeline is initialised or reconfigured.
  /// @param sample_rate_hz  Sample rate (e.g. 16000, 48000).
  /// @param num_channels    Number of audio channels (typically 1).
  void Initialize(int sample_rate_hz, int num_channels) override;

  /// Called for every audio frame. Must be real-time safe (no allocation,
  /// no locks, no blocking calls).
  /// @param audio  Non-owning pointer to the current audio frame data.
  void Process(int num_bands, int num_frames, int buffer_size,
               float* buffer) override;

  /// Called when the pipeline is reset (e.g. sample rate change).
  /// @param new_rate  New sample rate in Hz.
  void Reset(int new_rate) override;

  /// Called when the processor is being torn down. Release any state here.
  void Release() override;

  // -------------------------------------------------------------------------
  // Thread-safe configuration setters (may be called from any thread)
  // -------------------------------------------------------------------------

  /// Sets the active processing mode (see NoiseProcessingMode).
  void SetMode(int mode);

  /// Returns the audio level used for metering and gate decisions.
  ///
  /// If an external pre-APM level has been supplied via SetExternalLevel()
  /// (e.g. from a PulseAudio monitor thread), that value is returned so the
  /// meter and gate reflect the raw signal before WebRTC's AGC normalises it.
  /// Otherwise falls back to the post-APM RMS computed in Process().
  float GetAudioLevel() const;

  /// Injects a pre-APM RMS level from an external source (e.g. a PulseAudio
  /// capture thread that reads raw audio before WebRTC's gain controller runs).
  /// When set (value >= 0), this level is used for both GetAudioLevel() and
  /// the gate threshold comparison inside Process(), replacing the post-APM RMS.
  ///
  /// Pass -1.0f to clear and revert to post-APM measurement.
  /// Safe to call from any thread.
  void SetExternalLevel(float rms);

  /// RMS energy threshold in normalised float range [0, 1].
  /// Frames with RMS below this value are treated as silence.
  /// Default: 0.02f.
  void SetThreshold(float threshold);

  /// After signal drops below threshold, keep gate open for this many ms.
  /// Default: 200.
  void SetHoldMs(int hold_ms);

  /// Gain applied to output when gate is closed (0 = silence, 1 = passthrough).
  /// Default: 0.05f.
  void SetResidualGain(float gain);

  /// IIR smoothing time constant for gate opening (gain rising), in ms.
  /// Default: 5.0f.
  void SetAttackMs(float ms);

  /// IIR smoothing time constant for gate closing (gain falling), in ms.
  /// Default: 80.0f.
  void SetReleaseMs(float ms);

 private:
  // ---------------------------------------------------------------------------
  // Configuration atomics — written from the Dart/UI thread, read in Process().
  // ---------------------------------------------------------------------------

  /// Last computed post-APM RMS level — written in Process(), readable from any thread.
  std::atomic<float> rms_level_{0.0f};

  /// Pre-APM level injected by an external source (e.g. PulseAudio thread).
  /// Negative = not set; gate and meter use rms_level_ instead.
  std::atomic<float> external_level_{-1.0f};

  /// Current processing mode.
  std::atomic<int> mode_{static_cast<int>(NoiseProcessingMode::kDisabled)};

  /// RMS gate open threshold (normalised float).
  std::atomic<float> threshold_{0.02f};

  /// Number of audio frames the gate stays open after RMS drops below
  /// threshold. Computed from hold_ms_ and sample_rate_hz_ in
  /// Initialize()/Reset().
  std::atomic<int> hold_ms_{200};

  /// Gain applied when gate is closed.
  std::atomic<float> residual_gain_{0.05f};

  /// Attack time constant in ms (gate opening).
  std::atomic<float> attack_ms_{5.0f};

  /// Release time constant in ms (gate closing).
  std::atomic<float> release_ms_{80.0f};

  // ---------------------------------------------------------------------------
  // State updated only on the audio thread — no atomics needed.
  // ---------------------------------------------------------------------------

  /// Sample rate stored during Initialize()/Reset().
  int sample_rate_hz_{0};

  /// Number of channels stored during Initialize().
  int num_channels_{0};

  /// Number of samples per processing frame (set in Initialize()/Reset()).
  int samples_per_frame_{0};

  /// Remaining frames the gate must stay open (hold countdown).
  int hold_frames_remaining_{0};

  /// Current smoothed gain value (0.0 = fully closed, 1.0 = fully open).
  float smoothed_gain_{0.0f};

  /// Pre-computed IIR attack coefficient.
  /// Updated whenever sample_rate_hz_ or attack_ms_ changes in
  /// Initialize()/Reset().
  float attack_coeff_{0.0f};

  /// Pre-computed IIR release coefficient.
  float release_coeff_{0.0f};

  // ---------------------------------------------------------------------------
  // Private helpers
  // ---------------------------------------------------------------------------

  /// Recompute attack_coeff_ and release_coeff_ from current ms values and
  /// sample_rate_hz_ / samples_per_frame_.
  void RecomputeCoefficients();
};

}  // namespace noise_suppressor
