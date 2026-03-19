/// Web implementation of flutter_webrtc_noise_suppressor.
///
/// Uses an AudioWorklet for sample-accurate gate processing and patches
/// navigator.mediaDevices.getUserMedia via Dart JS interop so that every
/// captured audio track is routed through the gate transparently.
library flutter_webrtc_noise_suppressor_web;

import 'dart:async';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'package:flutter_web_plugins/flutter_web_plugins.dart';
import 'package:web/web.dart' as web;

import 'src/noise_processing_mode.dart';
import 'src/noise_suppressor_platform_interface.dart';

// ---------------------------------------------------------------------------
// AudioWorklet processor — inlined so no separate web asset is needed.
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
    const numSamples  = input[0].length;

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
      const atkC = Math.exp(-numSamples / (this._attackMs  * sampleRate / 1000));
      const relC = Math.exp(-numSamples / (this._releaseMs * sampleRate / 1000));
      const coeff = target > this._smoothedGain ? atkC : relC;
      this._smoothedGain += (1 - coeff) * (target - this._smoothedGain);
      this._smoothedGain  = Math.max(0, Math.min(1, this._smoothedGain));
      for (let c = 0; c < numChannels; c++) {
        const ich = input[c], och = output[c];
        for (let i = 0; i < numSamples; i++) och[i] = ich[i] * this._smoothedGain;
      }
    } else {
      for (let c = 0; c < numChannels; c++) output[c].set(input[c]);
    }

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

class NoiseSuppressorWeb extends NoiseSuppressorPlatform {
  static void registerWith(Registrar registrar) {
    NoiseSuppressorPlatform.instance = NoiseSuppressorWeb();
  }

  web.AudioContext? _audioContext;
  web.AudioWorkletNode? _workletNode;
  double _lastLevel = 0.0;

  // getUserMedia patch state
  JSObject? _mediaDevicesJS;
  JSAny? _originalGetUserMediaJS;

  static const String _processorName = 'noise-gate-processor';

  // ---------------------------------------------------------------------------
  // initialize
  // ---------------------------------------------------------------------------
  @override
  Future<void> initialize() async {
    if (_audioContext != null) return;

    _audioContext = web.AudioContext();

    // Load worklet via a Blob URL so no separate asset file is needed.
    final blob = web.Blob(
      [_kWorkletSource.toJS].toJS,
      web.BlobPropertyBag(type: 'application/javascript'),
    );
    final blobUrl = web.URL.createObjectURL(blob);
    try {
      await _audioContext!.audioWorklet.addModule(blobUrl).toDart;
    } finally {
      web.URL.revokeObjectURL(blobUrl);
    }

    _patchGetUserMedia();
  }

  // Patch navigator.mediaDevices.getUserMedia directly via JS interop —
  // no <script> injection needed so no CSP issues.
  void _patchGetUserMedia() {
    if (_mediaDevicesJS != null) return; // already patched

    final nav = (web.window as JSObject).getProperty('navigator'.toJS) as JSObject;
    _mediaDevicesJS = nav.getProperty('mediaDevices'.toJS) as JSObject;
    _originalGetUserMediaJS = _mediaDevicesJS!.getProperty('getUserMedia'.toJS);

    // Build the replacement function. It calls the original, then runs the
    // stream through our AudioWorklet graph if audio is requested.
    final self = this;
    final patched = ((JSAny? constraints) {
      // Call original getUserMedia with the correct `this`.
      // callMethod('call', thisArg, arg1) → fn.call(thisArg, arg1)
      final origPromise = (self._originalGetUserMediaJS as JSObject)
          .callMethod('call'.toJS, self._mediaDevicesJS, constraints)
              as JSPromise<JSObject>;

      // Only wrap streams that have audio.
      final audio = constraints is JSObject
          ? (constraints as JSObject).getProperty('audio'.toJS)
          : null;
      final hasAudio = audio != null && !audio.typeofEquals('undefined');
      if (!hasAudio) return origPromise;

      // Chain: origPromise → _processStreamAsync → new Promise
      return origPromise.toDart
          .then((stream) => self._processStreamAsync(stream))
          .toJS;
    }).toJS;

    _mediaDevicesJS!.setProperty('getUserMedia'.toJS, patched);
  }

  void _unpatchGetUserMedia() {
    if (_mediaDevicesJS == null || _originalGetUserMediaJS == null) return;
    _mediaDevicesJS!.setProperty('getUserMedia'.toJS, _originalGetUserMediaJS!);
    _mediaDevicesJS = null;
    _originalGetUserMediaJS = null;
  }

  // Process one getUserMedia stream: source → workletNode → destination.
  // Replaces the original audio track in the stream in-place so the caller
  // (dart_webrtc / RTCPeerConnection) gets the gated track automatically.
  Future<JSObject> _processStreamAsync(JSObject rawStream) async {
    try {
      final ctx = _audioContext;
      if (ctx == null) return rawStream;

      final ms = rawStream as web.MediaStream;
      final audioTracks = ms.getAudioTracks().toDart;
      if (audioTracks.isEmpty) return rawStream;

      // Disconnect any previous worklet.
      _disconnectWorklet();

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

      // Replace original audio track with the processed one in-place.
      final processedTracks = destNode.stream.getAudioTracks().toDart;
      if (processedTracks.isNotEmpty) {
        ms.removeTrack(audioTracks.first);
        ms.addTrack(processedTracks.first);
      }

      return rawStream;
    } catch (e) {
      // If worklet setup fails, return the original stream unprocessed.
      // Level meter won't work but the call / monitor will still function.
      print('flutter_webrtc_noise_suppressor: web processing error: $e');
      return rawStream;
    }
  }

  void _disconnectWorklet() {
    if (_workletNode == null) return;
    try {
      (_workletNode! as JSObject).callMethod('disconnect'.toJS);
    } catch (_) {}
    _workletNode = null;
  }

  // ---------------------------------------------------------------------------
  // dispose
  // ---------------------------------------------------------------------------
  @override
  Future<void> dispose() async {
    _unpatchGetUserMedia();
    _disconnectWorklet();
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
