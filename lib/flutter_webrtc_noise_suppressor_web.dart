/// Web implementation of flutter_webrtc_noise_suppressor.
///
/// Uses an AudioWorklet for sample-accurate gate processing and patches
/// navigator.mediaDevices.getUserMedia so that every captured audio track
/// is routed through the gate transparently, regardless of which package
/// (dart_webrtc / flutter_webrtc) calls getUserMedia.
library flutter_webrtc_noise_suppressor_web;

import 'dart:async';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'package:flutter_web_plugins/flutter_web_plugins.dart';
import 'package:web/web.dart' as web;

import 'src/noise_processing_mode.dart';
import 'src/noise_suppressor_platform_interface.dart';

// ---------------------------------------------------------------------------
// AudioWorklet processor source — inlined so no separate web asset is needed.
// Loaded at runtime via a Blob URL.
// ---------------------------------------------------------------------------
const String _kWorkletSource = r'''
class NoiseGateProcessor extends AudioWorkletProcessor {
  constructor() {
    super();
    this._threshold = 0.05;
    this._holdMs = 200;
    this._residualGain = 0.05;
    this._attackMs = 5.0;
    this._releaseMs = 80.0;
    this._smoothedGain = 1.0;
    this._holdSamplesRemaining = 0;
    this._levelFrameCount = 0;
    this._enabled = true;
    this.port.onmessage = (e) => {
      const d = e.data;
      if (d.threshold    !== undefined) this._threshold    = d.threshold;
      if (d.holdMs       !== undefined) this._holdMs       = d.holdMs;
      if (d.residualGain !== undefined) this._residualGain = d.residualGain;
      if (d.attackMs     !== undefined) this._attackMs     = d.attackMs;
      if (d.releaseMs    !== undefined) this._releaseMs    = d.releaseMs;
      if (d.enabled      !== undefined) this._enabled      = d.enabled;
    };
  }

  process(inputs, outputs) {
    const input  = inputs[0];
    const output = outputs[0];
    if (!input || !input.length || !input[0].length) return true;

    const numChannels = input.length;
    const numSamples  = input[0].length; // 128 at AudioContext sample rate

    // Short-term peak across all channels.
    let peak = 0;
    for (let c = 0; c < numChannels; c++) {
      const ch = input[c];
      for (let i = 0; i < numSamples; i++) {
        const a = Math.abs(ch[i]);
        if (a > peak) peak = a;
      }
    }

    if (this._enabled) {
      const holdSamples = (this._holdMs / 1000) * sampleRate;
      if (peak >= this._threshold) {
        this._holdSamplesRemaining = holdSamples;
      } else if (this._holdSamplesRemaining > 0) {
        this._holdSamplesRemaining = Math.max(0, this._holdSamplesRemaining - numSamples);
      }
      const gateOpen = peak >= this._threshold || this._holdSamplesRemaining > 0;
      const target   = gateOpen ? 1.0 : this._residualGain;

      const atkCoeff = Math.exp(-numSamples / (this._attackMs  * sampleRate / 1000));
      const relCoeff = Math.exp(-numSamples / (this._releaseMs * sampleRate / 1000));
      const coeff    = target > this._smoothedGain ? atkCoeff : relCoeff;
      this._smoothedGain += (1 - coeff) * (target - this._smoothedGain);
      this._smoothedGain  = Math.max(0, Math.min(1, this._smoothedGain));

      for (let c = 0; c < numChannels; c++) {
        const ich = input[c], och = output[c];
        for (let i = 0; i < numSamples; i++) och[i] = ich[i] * this._smoothedGain;
      }
    } else {
      for (let c = 0; c < numChannels; c++) output[c].set(input[c]);
    }

    // Post peak level ~every 50 ms for the settings meter.
    this._levelFrameCount += numSamples;
    if (this._levelFrameCount >= sampleRate * 0.05) {
      this._levelFrameCount = 0;
      this.port.postMessage(peak);
    }
    return true;
  }
}
registerProcessor('noise-gate-processor', NoiseGateProcessor);
''';

// ---------------------------------------------------------------------------
// getUserMedia patch — injected once as a <script> element.
// Dart calls window.__noiseGatePatch.activate(hook) / deactivate().
// ---------------------------------------------------------------------------
const String _kPatchScript = '''
(function () {
  if (window.__noiseGatePatch) return;
  var orig = navigator.mediaDevices.getUserMedia.bind(navigator.mediaDevices);
  var hook = null;
  window.__noiseGatePatch = {
    activate: function (fn) {
      hook = fn;
      navigator.mediaDevices.getUserMedia = function (constraints) {
        var p = orig(constraints);
        if (hook && constraints && constraints.audio) {
          return p.then(function (stream) { return hook(stream); });
        }
        return p;
      };
    },
    deactivate: function () {
      navigator.mediaDevices.getUserMedia = orig;
      hook = null;
    }
  };
})();
''';

// ---------------------------------------------------------------------------
// Extension types for APIs not fully surfaced in package:web
// ---------------------------------------------------------------------------
extension type _NoiseGatePatch(JSObject _) implements JSObject {
  external void activate(JSFunction hook);
  external void deactivate();
}

// ---------------------------------------------------------------------------
// Web plugin implementation
// ---------------------------------------------------------------------------
class NoiseSuppressorWeb extends NoiseSuppressorPlatform {
  static void registerWith(Registrar registrar) {
    NoiseSuppressorPlatform.instance = NoiseSuppressorWeb();
  }

  web.AudioContext? _audioContext;
  web.AudioWorkletNode? _workletNode;
  double _lastLevel = 0.0;

  static const String _processorName = 'noise-gate-processor';

  // ---------------------------------------------------------------------------
  // initialize
  // ---------------------------------------------------------------------------
  @override
  Future<void> initialize() async {
    if (_audioContext != null) return;

    // Inject the getUserMedia patch script once.
    final script = web.HTMLScriptElement();
    script.text = _kPatchScript;
    web.document.head!.append(script);

    // Build AudioContext and load the worklet via a Blob URL.
    _audioContext = web.AudioContext();

    final blob = web.Blob(
      [_kWorkletSource.toJS].toJS,
      web.BlobPropertyBag(type: 'application/javascript'),
    );
    final blobUrl = web.URL.createObjectURL(blob);
    await _audioContext!.audioWorklet.addModule(blobUrl).toDart;
    web.URL.revokeObjectURL(blobUrl);

    // Activate the getUserMedia hook.
    final patch = (web.window as JSObject)
        .getProperty('__noiseGatePatch'.toJS) as _NoiseGatePatch;
    patch.activate(((JSObject s) => _processStreamAsync(s).toJS).toJS);
  }

  // Called from JS (via the getUserMedia patch) for every audio stream.
  // Returns a JSPromise so the .then() chain in the patch script resolves correctly.
  Future<JSObject> _processStreamAsync(JSObject rawStream) async {
    final ctx = _audioContext;
    if (ctx == null) return rawStream;

    final ms = rawStream as web.MediaStream;
    final audioTracks = ms.getAudioTracks().toDart;
    if (audioTracks.isEmpty) return rawStream;

    // Disconnect any previously wired worklet node.
    if (_workletNode != null) {
      try {
        (_workletNode! as JSObject).callMethod('disconnect'.toJS);
      } catch (_) {}
    }

    // source → workletNode → destination
    final source      = ctx.createMediaStreamSource(ms);
    final workletNode = web.AudioWorkletNode(ctx, _processorName);
    _workletNode = workletNode;

    final destNode = ctx.createMediaStreamDestination();

    source.connect(workletNode);
    workletNode.connect(destNode);

    // Receive peak-level updates from the worklet.
    workletNode.port.addEventListener(
      'message',
      ((web.MessageEvent e) {
        final data = e.data;
        if (data != null) {
          try {
            _lastLevel = (data as JSNumber).toDartDouble;
          } catch (_) {}
        }
      }).toJS,
    );
    workletNode.port.start();

    // Replace the original audio track with the processed one in-place so
    // dart_webrtc / RTCPeerConnection receive the gated track automatically.
    final processedTracks = destNode.stream.getAudioTracks().toDart;
    if (processedTracks.isNotEmpty) {
      ms.removeTrack(audioTracks.first);
      ms.addTrack(processedTracks.first);
    }

    return rawStream;
  }

  // ---------------------------------------------------------------------------
  // dispose
  // ---------------------------------------------------------------------------
  @override
  Future<void> dispose() async {
    final patch = (web.window as JSObject)
        .getProperty('__noiseGatePatch'.toJS);
    if (patch != null) {
      try {
        (patch as _NoiseGatePatch).deactivate();
      } catch (_) {}
    }

    if (_workletNode != null) {
      try {
        (_workletNode! as JSObject).callMethod('disconnect'.toJS);
      } catch (_) {}
      _workletNode = null;
    }

    if (_audioContext != null) {
      try {
        await _audioContext!.close().toDart;
      } catch (_) {}
      _audioContext = null;
    }
    _lastLevel = 0.0;
  }

  // ---------------------------------------------------------------------------
  // setMode / configure / getAudioLevel
  // ---------------------------------------------------------------------------
  @override
  Future<void> setMode(NoiseProcessingMode mode) async {
    final enabled = mode == NoiseProcessingMode.rmsGate ||
        mode == NoiseProcessingMode.vadGate;
    _postToWorklet({'enabled': enabled});
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
    final map = <String, dynamic>{};
    if (threshold    != null) map['threshold']    = threshold;
    if (holdMs       != null) map['holdMs']       = holdMs;
    if (residualGain != null) map['residualGain'] = residualGain;
    if (attackMs     != null) map['attackMs']     = attackMs;
    if (releaseMs    != null) map['releaseMs']    = releaseMs;
    _postToWorklet(map);
  }

  @override
  Future<double> getAudioLevel() async => _lastLevel;

  void _postToWorklet(Map<String, dynamic> data) {
    if (_workletNode == null || data.isEmpty) return;
    _workletNode!.port.postMessage(data.jsify());
  }
}
