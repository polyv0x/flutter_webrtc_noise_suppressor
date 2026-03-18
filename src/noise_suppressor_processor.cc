#include "noise_suppressor_processor.h"

#include <algorithm>
#include <cmath>
#include <cstring>

namespace noise_suppressor {

// ---------------------------------------------------------------------------
// Constructor / Destructor
// ---------------------------------------------------------------------------

NoiseSuppressorProcessor::NoiseSuppressorProcessor() = default;
NoiseSuppressorProcessor::~NoiseSuppressorProcessor() = default;

// ---------------------------------------------------------------------------
// CustomProcessing overrides
// ---------------------------------------------------------------------------

void NoiseSuppressorProcessor::Initialize(int sample_rate_hz,
                                           int num_channels) {
  sample_rate_hz_ = sample_rate_hz;
  num_channels_   = num_channels;

  // WebRTC processes audio in 10 ms chunks.
  samples_per_frame_ = sample_rate_hz / 100;

  hold_frames_remaining_ = 0;
  smoothed_gain_         = 0.0f;

  RecomputeCoefficients();
}

void NoiseSuppressorProcessor::Process(int num_bands, int num_frames,
                                       int buffer_size, float* buffer) {
  // Always compute and store RMS so GetAudioLevel() works for the settings meter.
  if (buffer_size > 0) {
    float sum_sq = 0.0f;
    for (int i = 0; i < buffer_size; ++i) sum_sq += buffer[i] * buffer[i];
    const float rms = std::sqrt(sum_sq / static_cast<float>(buffer_size));
    rms_level_.store(rms, std::memory_order_relaxed);
  }

  const int current_mode = mode_.load(std::memory_order_relaxed);

  // disabled: pass through unchanged.
  if (current_mode == static_cast<int>(NoiseProcessingMode::kDisabled)) {
    return;
  }

  // denoise / hybrid: not yet implemented — pass through unchanged.
  // TODO(phase-2): run DeepFilterNet3 ONNX inference here.
  if (current_mode == static_cast<int>(NoiseProcessingMode::kDenoise) ||
      current_mode == static_cast<int>(NoiseProcessingMode::kHybrid)) {
    return;
  }

  // kRmsGate and kVadGate (kVadGate falls back to rmsGate in Phase 1):

  if (buffer_size <= 0) return;

  // Load config atomics (relaxed — a one-frame stale read is acceptable).
  const float threshold    = threshold_.load(std::memory_order_relaxed);
  const float residual     = residual_gain_.load(std::memory_order_relaxed);
  const int   hold_ms      = hold_ms_.load(std::memory_order_relaxed);
  const float attack_ms_v  = attack_ms_.load(std::memory_order_relaxed);
  const float release_ms_v = release_ms_.load(std::memory_order_relaxed);

  // Recompute IIR coefficients inline from current ms values.
  // coeff = exp(-samples_per_frame / (time_ms * sample_rate_hz / 1000))
  const float spf_f = static_cast<float>(samples_per_frame_);
  const float sr_f  = static_cast<float>(sample_rate_hz_);

  const float attack_coeff =
      (attack_ms_v > 0.0f && sr_f > 0.0f)
          ? std::exp(-spf_f / (attack_ms_v * sr_f / 1000.0f))
          : 0.0f;
  const float release_coeff =
      (release_ms_v > 0.0f && sr_f > 0.0f)
          ? std::exp(-spf_f / (release_ms_v * sr_f / 1000.0f))
          : 0.0f;

  // RMS was already computed above; reload it for the gate logic.
  const float rms = rms_level_.load(std::memory_order_relaxed);

  // Gate logic with hold timer.
  bool gate_open = false;
  if (rms >= threshold) {
    const int hold_frames =
        (sample_rate_hz_ > 0 && samples_per_frame_ > 0)
            ? static_cast<int>(static_cast<float>(hold_ms) * sr_f /
                                1000.0f / spf_f)
            : 0;
    hold_frames_remaining_ = hold_frames;
    gate_open = true;
  } else if (hold_frames_remaining_ > 0) {
    --hold_frames_remaining_;
    gate_open = true;
  }

  // IIR gain smoothing with separate attack/release paths.
  const float target_gain = gate_open ? 1.0f : residual;
  const float coeff = (target_gain > smoothed_gain_) ? attack_coeff
                                                      : release_coeff;
  smoothed_gain_ += (1.0f - coeff) * (target_gain - smoothed_gain_);
  smoothed_gain_  = std::max(0.0f, std::min(1.0f, smoothed_gain_));

  // Apply gain in-place over the entire buffer.
  for (int i = 0; i < buffer_size; ++i) {
    buffer[i] *= smoothed_gain_;
  }
}

void NoiseSuppressorProcessor::Reset(int new_rate) {
  sample_rate_hz_        = new_rate;
  samples_per_frame_     = new_rate / 100;
  hold_frames_remaining_ = 0;
  smoothed_gain_         = 0.0f;
  RecomputeCoefficients();
}

void NoiseSuppressorProcessor::Release() {
  sample_rate_hz_        = 0;
  num_channels_          = 0;
  samples_per_frame_     = 0;
  hold_frames_remaining_ = 0;
  smoothed_gain_         = 0.0f;
  attack_coeff_          = 0.0f;
  release_coeff_         = 0.0f;
}

// ---------------------------------------------------------------------------
// Thread-safe setters
// ---------------------------------------------------------------------------

float NoiseSuppressorProcessor::GetAudioLevel() const {
  return rms_level_.load(std::memory_order_relaxed);
}

void NoiseSuppressorProcessor::SetMode(int mode) {
  mode_.store(mode, std::memory_order_relaxed);
}

void NoiseSuppressorProcessor::SetThreshold(float threshold) {
  threshold_.store(threshold, std::memory_order_relaxed);
}

void NoiseSuppressorProcessor::SetHoldMs(int hold_ms) {
  hold_ms_.store(hold_ms, std::memory_order_relaxed);
}

void NoiseSuppressorProcessor::SetResidualGain(float gain) {
  residual_gain_.store(gain, std::memory_order_relaxed);
}

void NoiseSuppressorProcessor::SetAttackMs(float ms) {
  attack_ms_.store(ms, std::memory_order_relaxed);
  // Coefficients are recomputed inline in Process() so no lock needed here.
}

void NoiseSuppressorProcessor::SetReleaseMs(float ms) {
  release_ms_.store(ms, std::memory_order_relaxed);
}

// ---------------------------------------------------------------------------
// Private helpers
// ---------------------------------------------------------------------------

void NoiseSuppressorProcessor::RecomputeCoefficients() {
  if (sample_rate_hz_ <= 0 || samples_per_frame_ <= 0) {
    attack_coeff_  = 0.0f;
    release_coeff_ = 0.0f;
    return;
  }

  const float spf = static_cast<float>(samples_per_frame_);
  const float sr  = static_cast<float>(sample_rate_hz_);

  const float atk = attack_ms_.load(std::memory_order_relaxed);
  const float rel = release_ms_.load(std::memory_order_relaxed);

  // coeff = exp(-samples_per_frame / (time_ms * sample_rate_hz / 1000))
  attack_coeff_  = (atk  > 0.0f) ? std::exp(-spf / (atk  * sr / 1000.0f)) : 0.0f;
  release_coeff_ = (rel  > 0.0f) ? std::exp(-spf / (rel  * sr / 1000.0f)) : 0.0f;
}

}  // namespace noise_suppressor
