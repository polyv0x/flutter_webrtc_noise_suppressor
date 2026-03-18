#import <Flutter/Flutter.h>

NS_ASSUME_NONNULL_BEGIN

/// Flutter plugin that registers a real-time noise suppressor with
/// flutter_webrtc's capturePostProcessingAdapter on iOS.
///
/// Phase 1 implements a simple RMS energy-threshold gate with IIR gain
/// smoothing. Future phases will add Silero VAD and DeepFilterNet3 denoising
/// via ONNX Runtime.
@interface FlutterWebrtcNoiseSuppressorPlugin : NSObject <FlutterPlugin>
@end

NS_ASSUME_NONNULL_END
