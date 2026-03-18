Pod::Spec.new do |s|
  s.name             = 'flutter_webrtc_noise_suppressor'
  s.version          = '0.1.0'
  s.summary          = 'Real-time noise suppression for flutter_webrtc.'
  s.description      = <<-DESC
    Phase 1: RMS energy-threshold gate with IIR gain smoothing, integrated
    into flutter_webrtc's capturePostProcessingAdapter pipeline on iOS.
    Future phases will add Silero VAD and DeepFilterNet3 via ONNX Runtime.
  DESC

  s.homepage         = 'https://github.com/polyv0x/flutter_webrtc_noise_suppressor'
  s.license          = { :type => 'MIT', :file => '../LICENSE' }
  s.author           = { 'polyv0x' => 'polyv0x@users.noreply.github.com' }
  s.source           = { :path => '.' }

  s.source_files     = 'Classes/**/*.{h,m,mm}'
  s.public_header_files = 'Classes/**/*.h'

  s.ios.deployment_target = '12.0'

  s.dependency 'Flutter'

  # flutter_webrtc is NOT listed as a podspec dependency because it is linked
  # at runtime via the host app's Podfile. Declaring it here would create a
  # circular dependency when flutter_webrtc_noise_suppressor is included
  # alongside flutter_webrtc in the same project.
  #
  # At runtime this plugin calls [AudioManager sharedInstance] and
  # [RTCAudioBuffer rawBufferForChannel:] — both provided by flutter_webrtc.

  s.pod_target_xcconfig = {
    'DEFINES_MODULE'              => 'YES',
    'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'i386'
  }
end
