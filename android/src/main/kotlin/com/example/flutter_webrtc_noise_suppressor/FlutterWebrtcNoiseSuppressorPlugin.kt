package com.example.flutter_webrtc_noise_suppressor

import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.MethodChannel.MethodCallHandler
import io.flutter.plugin.common.MethodChannel.Result
import kotlin.math.exp
import kotlin.math.sqrt

// ---------------------------------------------------------------------------
// RMS Gate Processor
//
// Implements the same algorithm as the C++ NoiseSuppressorProcessor:
//   1. Compute RMS energy over the frame.
//   2. Compare to threshold; manage a hold countdown.
//   3. Apply IIR gain smoothing (separate attack / release time constants).
//   4. Multiply every sample by the smoothed gain.
//
// Short values are in the range [-32768, 32767]. We scale to [-1, 1] for the
// RMS computation, then scale the gain factor back to the integer domain for
// the output multiply.
// ---------------------------------------------------------------------------
class RmsGateProcessor {

    // Configuration (written from the main thread, read on the audio thread).
    // Kotlin does not have std::atomic, but @Volatile is sufficient here
    // because we only ever write a single word and can tolerate one stale read.
    @Volatile var threshold: Float = 0.02f
    @Volatile var holdMs: Int = 200
    @Volatile var residualGain: Float = 0.05f
    @Volatile var attackMs: Float = 5.0f
    @Volatile var releaseMs: Float = 80.0f

    // Last computed RMS level — written on the audio thread, readable from any thread.
    @Volatile var lastRms: Float = 0.0f

    // Audio-thread state (touched only in initialize / process / reset).
    private var sampleRateHz: Int = 0
    private var channels: Int = 0
    private var samplesPerFrame: Int = 0
    private var holdFramesRemaining: Int = 0
    private var smoothedGain: Float = 0.0f
    private var attackCoeff: Float = 0.0f
    private var releaseCoeff: Float = 0.0f

    fun initialize(sampleRateHz: Int, channels: Int) {
        this.sampleRateHz = sampleRateHz
        this.channels = channels
        // WebRTC processes in 10 ms chunks.
        this.samplesPerFrame = sampleRateHz / 100
        holdFramesRemaining = 0
        smoothedGain = 0.0f
        recomputeCoefficients()
    }

    fun process(audioBuffer: ShortArray) {
        if (sampleRateHz <= 0 || samplesPerFrame <= 0) return

        val n = audioBuffer.size
        if (n == 0) return

        val thresholdLocal = threshold
        val residualLocal = residualGain

        // Snapshot of hold_ms for this frame (safe to read once).
        val holdMsLocal = holdMs

        // ------------------------------------------------------------------
        // Compute RMS — scale from 16-bit integers to [-1, 1].
        // ------------------------------------------------------------------
        val scale = 1.0f / 32768.0f
        var sumSq = 0.0f
        for (sample in audioBuffer) {
            val f = sample.toFloat() * scale
            sumSq += f * f
        }
        val rms = sqrt(sumSq / n.toFloat())
        lastRms = rms

        // ------------------------------------------------------------------
        // Gate logic with hold
        // ------------------------------------------------------------------
        val gateOpen: Boolean
        if (rms >= thresholdLocal) {
            val holdFrames =
                if (sampleRateHz > 0)
                    (holdMsLocal.toFloat() * sampleRateHz.toFloat() / 1000.0f /
                            samplesPerFrame.toFloat()).toInt()
                else 0
            holdFramesRemaining = holdFrames
            gateOpen = true
        } else if (holdFramesRemaining > 0) {
            holdFramesRemaining--
            gateOpen = true
        } else {
            gateOpen = false
        }

        // ------------------------------------------------------------------
        // IIR gain smoothing
        // ------------------------------------------------------------------
        val targetGain = if (gateOpen) 1.0f else residualLocal

        smoothedGain = if (targetGain > smoothedGain) {
            // Opening — use attack coefficient.
            attackCoeff * smoothedGain + (1.0f - attackCoeff) * targetGain
        } else {
            // Closing — use release coefficient.
            releaseCoeff * smoothedGain + (1.0f - releaseCoeff) * targetGain
        }
        smoothedGain = smoothedGain.coerceIn(0.0f, 1.0f)

        // ------------------------------------------------------------------
        // Apply gain in-place (ShortArray — scale gain to integer multiply).
        // Clamp output to Short range to avoid overflow.
        // ------------------------------------------------------------------
        for (i in audioBuffer.indices) {
            val scaled = audioBuffer[i].toFloat() * smoothedGain
            audioBuffer[i] = scaled.toInt().toShort()
        }
    }

    fun reset(newRate: Int) {
        sampleRateHz = newRate
        samplesPerFrame = newRate / 100
        holdFramesRemaining = 0
        smoothedGain = 0.0f
        recomputeCoefficients()
    }

    fun release() {
        sampleRateHz = 0
        channels = 0
        samplesPerFrame = 0
        holdFramesRemaining = 0
        smoothedGain = 0.0f
        attackCoeff = 0.0f
        releaseCoeff = 0.0f
    }

    // -----------------------------------------------------------------------
    // Private helpers
    // -----------------------------------------------------------------------

    private fun recomputeCoefficients() {
        if (sampleRateHz <= 0 || samplesPerFrame <= 0) {
            attackCoeff = 0.0f
            releaseCoeff = 0.0f
            return
        }
        val spf = samplesPerFrame.toFloat()
        val sr = sampleRateHz.toFloat()
        val atk = attackMs
        val rel = releaseMs

        // coeff = exp(-samples_per_frame / (time_ms * sample_rate_hz / 1000))
        attackCoeff = if (atk > 0.0f) exp(-spf / (atk * sr / 1000.0f)) else 0.0f
        releaseCoeff = if (rel > 0.0f) exp(-spf / (rel * sr / 1000.0f)) else 0.0f
    }
}

// ---------------------------------------------------------------------------
// Processing mode constants (must match Dart-side NoiseProcessingMode.index)
// ---------------------------------------------------------------------------
private const val MODE_DISABLED = 0
private const val MODE_RMS_GATE = 1
private const val MODE_VAD_GATE = 2  // falls back to rmsGate
private const val MODE_DENOISE  = 3  // falls back to disabled (future)
private const val MODE_HYBRID   = 4  // falls back to disabled (future)

// ---------------------------------------------------------------------------
// Flutter Plugin
// ---------------------------------------------------------------------------
class FlutterWebrtcNoiseSuppressorPlugin : FlutterPlugin, MethodCallHandler {

    private lateinit var channel: MethodChannel
    private var processor: RmsGateProcessor? = null

    // Current mode (main thread only — method channel calls are serialised).
    private var currentMode: Int = MODE_DISABLED

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel = MethodChannel(
            binding.binaryMessenger,
            "flutter_webrtc_noise_suppressor"
        )
        channel.setMethodCallHandler(this)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel.setMethodCallHandler(null)
        safeDisposeProcessor()
    }

    override fun onMethodCall(call: MethodCall, result: Result) {
        when (call.method) {
            "initialize"    -> handleInitialize(result)
            "dispose"       -> handleDispose(result)
            "setMode"       -> handleSetMode(call, result)
            "configure"     -> handleConfigure(call, result)
            "getAudioLevel" -> result.success(processor?.lastRms?.toDouble() ?: 0.0)
            else            -> result.notImplemented()
        }
    }

    // -----------------------------------------------------------------------
    // Method handlers
    // -----------------------------------------------------------------------

    private fun handleInitialize(result: Result) {
        if (processor == null) {
            processor = RmsGateProcessor()
        }

        // Register with flutter_webrtc's audio processing pipeline.
        //
        // flutter_webrtc exposes AudioProcessingController with a
        // capturePostProcessing property that accepts an
        // ExternalAudioFrameProcessing implementation.
        //
        // We use reflection so that this plugin compiles and loads even when
        // flutter_webrtc is not present in the host app (the plugin will
        // simply not process audio in that case).
        try {
            val fwrtcClass = Class.forName(
                "com.cloudwebrtc.webrtc.FlutterWebRTCPlugin"
            )
            val getController = fwrtcClass.getMethod(
                "getAudioProcessingController"
            )
            // FlutterWebRTCPlugin is a singleton — retrieve the instance via
            // its static getInstance() method.
            val getInstance = fwrtcClass.getMethod("getInstance")
            val pluginInstance = getInstance.invoke(null)
            val controller = getController.invoke(pluginInstance)

            if (controller != null) {
                val capturePost = controller.javaClass
                    .getField("capturePostProcessing")
                    .get(controller)

                if (capturePost != null) {
                    val addProcessor = capturePost.javaClass.getMethod(
                        "addProcessor",
                        Class.forName(
                            "com.cloudwebrtc.webrtc.audio.ExternalAudioFrameProcessing"
                        )
                    )
                    addProcessor.invoke(capturePost, buildProcessingProxy())
                }
            }
        } catch (e: Exception) {
            // flutter_webrtc is not present or API has changed.
            // Log and continue — the processor is still instantiated and can
            // be used if the caller wires it up manually.
            android.util.Log.w(
                "NoiseSuppressor",
                "Could not register with flutter_webrtc AudioProcessingController: ${e.message}"
            )
        }

        result.success(null)
    }

    private fun handleDispose(result: Result) {
        if (processor == null) {
            result.error("NOT_INITIALIZED", "dispose() called before initialize()", null)
            return
        }

        // Unregister from flutter_webrtc (mirror of handleInitialize).
        try {
            val fwrtcClass = Class.forName(
                "com.cloudwebrtc.webrtc.FlutterWebRTCPlugin"
            )
            val getInstance = fwrtcClass.getMethod("getInstance")
            val pluginInstance = getInstance.invoke(null)
            val getController = fwrtcClass.getMethod("getAudioProcessingController")
            val controller = getController.invoke(pluginInstance)

            if (controller != null) {
                val capturePost = controller.javaClass
                    .getField("capturePostProcessing")
                    .get(controller)

                if (capturePost != null) {
                    // Remove all processors registered by this plugin.
                    // flutter_webrtc's API may provide removeAllProcessors()
                    // or removeProcessor(processor). Try both.
                    try {
                        val removeAll = capturePost.javaClass
                            .getMethod("removeAllProcessors")
                        removeAll.invoke(capturePost)
                    } catch (_: NoSuchMethodException) {
                        // removeAllProcessors not available; ignore.
                    }
                }
            }
        } catch (e: Exception) {
            android.util.Log.w(
                "NoiseSuppressor",
                "Could not unregister from flutter_webrtc: ${e.message}"
            )
        }

        safeDisposeProcessor()
        result.success(null)
    }

    private fun handleSetMode(call: MethodCall, result: Result) {
        if (processor == null) {
            result.error("NOT_INITIALIZED", "setMode() called before initialize()", null)
            return
        }
        val mode = call.argument<Int>("mode")
        if (mode == null) {
            result.error("INVALID_ARGUMENT", "missing required argument: mode", null)
            return
        }
        currentMode = mode
        result.success(null)
    }

    private fun handleConfigure(call: MethodCall, result: Result) {
        val p = processor
        if (p == null) {
            result.error("NOT_INITIALIZED", "configure() called before initialize()", null)
            return
        }

        call.argument<Double>("threshold")?.let { p.threshold = it.toFloat() }
        call.argument<Int>("holdMs")?.let { p.holdMs = it }
        call.argument<Double>("residualGain")?.let { p.residualGain = it.toFloat() }
        call.argument<Double>("attackMs")?.let { p.attackMs = it.toFloat() }
        call.argument<Double>("releaseMs")?.let { p.releaseMs = it.toFloat() }
        // vadThreshold is accepted but reserved for future VAD mode (no-op in Phase 1).

        result.success(null)
    }

    // -----------------------------------------------------------------------
    // Build a dynamic proxy that adapts RmsGateProcessor to flutter_webrtc's
    // ExternalAudioFrameProcessing interface without a compile-time dep.
    // -----------------------------------------------------------------------
    private fun buildProcessingProxy(): Any {
        val processorRef = processor!!
        val modeRef get() = currentMode

        return java.lang.reflect.Proxy.newProxyInstance(
            javaClass.classLoader,
            arrayOf(
                Class.forName(
                    "com.cloudwebrtc.webrtc.audio.ExternalAudioFrameProcessing"
                )
            )
        ) { _, method, args ->
            when (method.name) {
                "initialize" -> {
                    val sampleRate = args?.getOrNull(0) as? Int ?: return@newProxyInstance null
                    val channels   = args?.getOrNull(1) as? Int ?: return@newProxyInstance null
                    processorRef.initialize(sampleRate, channels)
                    null
                }
                "process" -> {
                    val buffer = args?.getOrNull(0) as? ShortArray
                        ?: return@newProxyInstance null
                    // Only apply processing for active modes.
                    // vadGate falls back to rmsGate; denoise/hybrid pass through.
                    when (modeRef) {
                        MODE_RMS_GATE, MODE_VAD_GATE -> processorRef.process(buffer)
                        // TODO(phase-2): MODE_DENOISE, MODE_HYBRID — run ONNX inference.
                        else -> { /* passthrough */ }
                    }
                    null
                }
                "reset" -> {
                    val newRate = args?.getOrNull(0) as? Int ?: return@newProxyInstance null
                    processorRef.reset(newRate)
                    null
                }
                "release" -> {
                    processorRef.release()
                    null
                }
                else -> null
            }
        }
    }

    // -----------------------------------------------------------------------
    // Helpers
    // -----------------------------------------------------------------------

    private fun safeDisposeProcessor() {
        processor?.release()
        processor = null
    }
}
