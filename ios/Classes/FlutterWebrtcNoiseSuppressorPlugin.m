#import "FlutterWebrtcNoiseSuppressorPlugin.h"

#import <math.h>

// ---------------------------------------------------------------------------
// Processing mode constants — must match Dart-side NoiseProcessingMode.index.
// ---------------------------------------------------------------------------
typedef NS_ENUM(NSInteger, NoiseProcessingMode) {
    NoiseProcessingModeDisabled = 0,
    NoiseProcessingModeRmsGate  = 1,
    NoiseProcessingModeVadGate  = 2,  // falls back to rmsGate
    NoiseProcessingModeDenoise  = 3,  // falls back to disabled (future)
    NoiseProcessingModeHybrid   = 4,  // falls back to disabled (future)
};

// ---------------------------------------------------------------------------
// Default configuration values
// ---------------------------------------------------------------------------
static const float kDefaultThreshold    = 0.02f;
static const int   kDefaultHoldMs       = 200;
static const float kDefaultResidualGain = 0.05f;
static const float kDefaultAttackMs     = 5.0f;
static const float kDefaultReleaseMs    = 80.0f;

// ---------------------------------------------------------------------------
// FlutterWebrtcNoiseSuppressorPlugin
//
// This class implements both FlutterPlugin (for the method channel) and the
// ExternalAudioProcessingDelegate protocol from flutter_webrtc (for the audio
// callbacks). We use NSProtocolFromString / respondsToSelector so that the
// plugin compiles and loads even when flutter_webrtc is not linked — the
// audio hooks simply won't fire in that case.
// ---------------------------------------------------------------------------
@implementation FlutterWebrtcNoiseSuppressorPlugin {
    // -----------------------------------------------------------------------
    // Configuration — written from the main thread, read on the audio thread.
    // We use @synchronized(self) for the scalar ivars because iOS does not
    // expose C11 _Atomic in ObjC conveniently. Alternatively NSLock could
    // be used, but @synchronized has negligible overhead for infrequent
    // UI-thread writes.
    // -----------------------------------------------------------------------
    float   _threshold;
    int     _holdMs;
    float   _residualGain;
    float   _attackMs;
    float   _releaseMs;
    NoiseProcessingMode _mode;

    // -----------------------------------------------------------------------
    // Audio-thread state — only touched in the delegate callbacks (serialised
    // by the WebRTC audio thread).
    // -----------------------------------------------------------------------
    double  _sampleRateHz;
    int     _numChannels;
    int     _samplesPerFrame;
    int     _holdFramesRemaining;
    float   _smoothedGain;
    float   _attackCoeff;
    float   _releaseCoeff;

    // Retain the proxy object we registered so we can remove it later.
    id      _processingProxy;

    // Last computed RMS level — written on audio thread, read on main thread.
    // Protected by @synchronized(self) for consistency with other ivars.
    float   _rmsLevel;
}

// ---------------------------------------------------------------------------
// FlutterPlugin registration
// ---------------------------------------------------------------------------

+ (void)registerWithRegistrar:(NSObject<FlutterPluginRegistrar>*)registrar {
    FlutterMethodChannel* channel =
        [FlutterMethodChannel methodChannelWithName:@"flutter_webrtc_noise_suppressor"
                                   binaryMessenger:[registrar messenger]];
    FlutterWebrtcNoiseSuppressorPlugin* instance =
        [[FlutterWebrtcNoiseSuppressorPlugin alloc] init];
    [registrar addMethodCallDelegate:instance channel:channel];
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _threshold    = kDefaultThreshold;
        _holdMs       = kDefaultHoldMs;
        _residualGain = kDefaultResidualGain;
        _attackMs     = kDefaultAttackMs;
        _releaseMs    = kDefaultReleaseMs;
        _mode         = NoiseProcessingModeDisabled;

        _sampleRateHz         = 0;
        _numChannels          = 0;
        _samplesPerFrame      = 0;
        _holdFramesRemaining  = 0;
        _smoothedGain         = 0.0f;
        _attackCoeff          = 0.0f;
        _releaseCoeff         = 0.0f;
    }
    return self;
}

// ---------------------------------------------------------------------------
// FlutterPlugin method channel handler
// ---------------------------------------------------------------------------

- (void)handleMethodCall:(FlutterMethodCall*)call
                  result:(FlutterResult)result {
    if ([call.method isEqualToString:@"initialize"]) {
        [self handleInitialize:result];
    } else if ([call.method isEqualToString:@"dispose"]) {
        [self handleDispose:result];
    } else if ([call.method isEqualToString:@"setMode"]) {
        [self handleSetMode:call result:result];
    } else if ([call.method isEqualToString:@"configure"]) {
        [self handleConfigure:call result:result];
    } else if ([call.method isEqualToString:@"getAudioLevel"]) {
        float level;
        @synchronized(self) { level = _rmsLevel; }
        result(@(level));
    } else {
        result(FlutterMethodNotImplemented);
    }
}

// ---------------------------------------------------------------------------
// initialize
// ---------------------------------------------------------------------------

- (void)handleInitialize:(FlutterResult)result {
    // Locate AudioManager.sharedInstance via the Objective-C runtime so that
    // we do not have a hard compile-time dependency on flutter_webrtc.
    Class audioManagerClass = NSClassFromString(@"AudioManager");
    if (!audioManagerClass) {
        NSLog(@"[NoiseSuppressor] AudioManager class not found — "
              "is flutter_webrtc linked?");
        result(nil);
        return;
    }

    id audioManager = [audioManagerClass performSelector:@selector(sharedInstance)];
    if (!audioManager) {
        NSLog(@"[NoiseSuppressor] AudioManager.sharedInstance returned nil");
        result(nil);
        return;
    }

    // Get capturePostProcessingAdapter.
    SEL captureAdapterSel = NSSelectorFromString(@"capturePostProcessingAdapter");
    if (![audioManager respondsToSelector:captureAdapterSel]) {
        NSLog(@"[NoiseSuppressor] capturePostProcessingAdapter not available");
        result(nil);
        return;
    }

    id adapter =
        [audioManager performSelector:captureAdapterSel];
    if (!adapter) {
        NSLog(@"[NoiseSuppressor] capturePostProcessingAdapter is nil");
        result(nil);
        return;
    }

    // Add self as a processing delegate.
    SEL addProcessingSel = NSSelectorFromString(@"addProcessing:");
    if (![adapter respondsToSelector:addProcessingSel]) {
        NSLog(@"[NoiseSuppressor] addProcessing: not available on adapter");
        result(nil);
        return;
    }

    [adapter performSelector:addProcessingSel withObject:self];
    _processingProxy = adapter;  // retain for later removal

    result(nil);
}

// ---------------------------------------------------------------------------
// dispose
// ---------------------------------------------------------------------------

- (void)handleDispose:(FlutterResult)result {
    if (_processingProxy) {
        SEL removeProcessingSel = NSSelectorFromString(@"removeProcessing:");
        if ([_processingProxy respondsToSelector:removeProcessingSel]) {
            [_processingProxy performSelector:removeProcessingSel
                                   withObject:self];
        }
        _processingProxy = nil;
    }

    // Reset audio-thread state.
    _sampleRateHz        = 0;
    _numChannels         = 0;
    _samplesPerFrame     = 0;
    _holdFramesRemaining = 0;
    _smoothedGain        = 0.0f;
    _attackCoeff         = 0.0f;
    _releaseCoeff        = 0.0f;

    result(nil);
}

// ---------------------------------------------------------------------------
// setMode
// ---------------------------------------------------------------------------

- (void)handleSetMode:(FlutterMethodCall*)call result:(FlutterResult)result {
    NSDictionary* args = call.arguments;
    NSNumber* modeNum = args[@"mode"];
    if (!modeNum) {
        result([FlutterError errorWithCode:@"INVALID_ARGUMENT"
                                   message:@"missing required argument: mode"
                                   details:nil]);
        return;
    }
    @synchronized(self) {
        _mode = (NoiseProcessingMode)[modeNum integerValue];
    }
    result(nil);
}

// ---------------------------------------------------------------------------
// configure
// ---------------------------------------------------------------------------

- (void)handleConfigure:(FlutterMethodCall*)call result:(FlutterResult)result {
    NSDictionary* args = call.arguments;

    @synchronized(self) {
        NSNumber* v;
        if ((v = args[@"threshold"]))    _threshold    = [v floatValue];
        if ((v = args[@"holdMs"]))       _holdMs       = [v intValue];
        if ((v = args[@"residualGain"])) _residualGain = [v floatValue];
        if ((v = args[@"attackMs"]))     _attackMs     = [v floatValue];
        if ((v = args[@"releaseMs"]))    _releaseMs    = [v floatValue];
        // vadThreshold is accepted but reserved for future VAD mode (no-op in Phase 1).
    }

    result(nil);
}

// ---------------------------------------------------------------------------
// ExternalAudioProcessingDelegate — called by flutter_webrtc on the audio
// thread.
//
// We conform to the protocol dynamically; the selectors must match exactly
// what flutter_webrtc's RTCAudioProcessingAdapter calls.
// ---------------------------------------------------------------------------

/// Called once when the audio pipeline is initialised.
- (void)audioProcessingInitializeWithSampleRate:(double)sampleRateHz
                                       channels:(int)channels {
    _sampleRateHz    = sampleRateHz;
    _numChannels     = channels;
    _samplesPerFrame = (int)(sampleRateHz / 100.0);  // 10 ms frame
    _holdFramesRemaining = 0;
    _smoothedGain        = 0.0f;
    [self recomputeCoefficients];
}

/// Called for every audio frame.
/// audioBuffer is an RTCAudioBuffer* — we access it via rawBufferForChannel:.
- (void)audioProcessingProcess:(id)audioBuffer {
    NoiseProcessingMode currentMode;
    float threshold, residualGain, attackMs, releaseMs;
    int   holdMs;

    @synchronized(self) {
        currentMode  = _mode;
        threshold    = _threshold;
        residualGain = _residualGain;
        attackMs     = _attackMs;
        releaseMs    = _releaseMs;
        holdMs       = _holdMs;
    }

    // disabled: passthrough.
    if (currentMode == NoiseProcessingModeDisabled) return;

    // denoise / hybrid not yet implemented — passthrough.
    if (currentMode == NoiseProcessingModeDenoise ||
        currentMode == NoiseProcessingModeHybrid) {
        // TODO(phase-2): run DeepFilterNet3 ONNX inference here.
        return;
    }

    // rmsGate (and vadGate falling back to rmsGate):

    // Recompute IIR coefficients from current ms values.
    // We do this inline (vs. caching) so that configure() changes take effect
    // on the very next frame without requiring a lock.
    float spf = (float)_samplesPerFrame;
    float sr  = (float)_sampleRateHz;

    float attackCoeff  = (attackMs  > 0.0f && sr > 0.0f)
        ? expf(-spf / (attackMs  * sr / 1000.0f)) : 0.0f;
    float releaseCoeff = (releaseMs > 0.0f && sr > 0.0f)
        ? expf(-spf / (releaseMs * sr / 1000.0f)) : 0.0f;

    // Get float PCM buffer for channel 0 via RTCAudioBuffer.
    // rawBufferForChannel: returns float* (non-owning).
    SEL rawBufSel = NSSelectorFromString(@"rawBufferForChannel:");
    if (![audioBuffer respondsToSelector:rawBufSel]) return;

    // RTCAudioBuffer.framesPerBand or num_frames — try both selector names.
    int n = 0;
    if ([audioBuffer respondsToSelector:NSSelectorFromString(@"framesPerBand")]) {
        n = (int)[(id)audioBuffer performSelector:
                  NSSelectorFromString(@"framesPerBand")];
    } else if ([audioBuffer respondsToSelector:NSSelectorFromString(@"numFrames")]) {
        n = (int)[(id)audioBuffer performSelector:
                  NSSelectorFromString(@"numFrames")];
    }
    if (n <= 0) return;

    // Retrieve the float buffer via IMP to avoid ARC bridging overhead and
    // to obtain the raw pointer safely.
    IMP imp = [audioBuffer methodForSelector:rawBufSel];
    typedef float* (*RawBufFunc)(id, SEL, int);
    float* ch0 = ((RawBufFunc)imp)(audioBuffer, rawBufSel, 0);
    if (!ch0) return;

    // ------------------------------------------------------------------
    // Compute RMS over channel 0.
    // ------------------------------------------------------------------
    float sumSq = 0.0f;
    for (int i = 0; i < n; ++i) {
        sumSq += ch0[i] * ch0[i];
    }
    float rms = sqrtf(sumSq / (float)n);
    @synchronized(self) { _rmsLevel = rms; }

    // ------------------------------------------------------------------
    // Gate logic with hold.
    // ------------------------------------------------------------------
    BOOL gateOpen;
    if (rms >= threshold) {
        int holdFrames = (sr > 0.0f)
            ? (int)((float)holdMs * sr / 1000.0f / spf)
            : 0;
        _holdFramesRemaining = holdFrames;
        gateOpen = YES;
    } else if (_holdFramesRemaining > 0) {
        _holdFramesRemaining--;
        gateOpen = YES;
    } else {
        gateOpen = NO;
    }

    // ------------------------------------------------------------------
    // IIR gain smoothing.
    // ------------------------------------------------------------------
    float targetGain = gateOpen ? 1.0f : residualGain;

    if (targetGain > _smoothedGain) {
        _smoothedGain =
            attackCoeff * _smoothedGain + (1.0f - attackCoeff) * targetGain;
    } else {
        _smoothedGain =
            releaseCoeff * _smoothedGain + (1.0f - releaseCoeff) * targetGain;
    }
    _smoothedGain = fmaxf(0.0f, fminf(1.0f, _smoothedGain));

    // ------------------------------------------------------------------
    // Apply gain to all channels in-place.
    // ------------------------------------------------------------------
    int numCh = 1;
    if ([audioBuffer respondsToSelector:NSSelectorFromString(@"numChannels")]) {
        numCh = (int)[(id)audioBuffer performSelector:
                      NSSelectorFromString(@"numChannels")];
    }

    for (int c = 0; c < numCh; ++c) {
        float* ch = ((RawBufFunc)imp)(audioBuffer, rawBufSel, c);
        if (!ch) continue;
        for (int i = 0; i < n; ++i) {
            ch[i] *= _smoothedGain;
        }
    }
}

/// Called when the audio pipeline is being torn down.
- (void)audioProcessingRelease {
    _sampleRateHz        = 0;
    _numChannels         = 0;
    _samplesPerFrame     = 0;
    _holdFramesRemaining = 0;
    _smoothedGain        = 0.0f;
    _attackCoeff         = 0.0f;
    _releaseCoeff        = 0.0f;
}

// ---------------------------------------------------------------------------
// Private helpers
// ---------------------------------------------------------------------------

- (void)recomputeCoefficients {
    if (_sampleRateHz <= 0 || _samplesPerFrame <= 0) {
        _attackCoeff  = 0.0f;
        _releaseCoeff = 0.0f;
        return;
    }
    float spf = (float)_samplesPerFrame;
    float sr  = (float)_sampleRateHz;
    float atk, rel;
    @synchronized(self) {
        atk = _attackMs;
        rel = _releaseMs;
    }
    _attackCoeff  = (atk > 0.0f) ? expf(-spf / (atk * sr / 1000.0f)) : 0.0f;
    _releaseCoeff = (rel > 0.0f) ? expf(-spf / (rel * sr / 1000.0f)) : 0.0f;
}

@end
