Pod::Spec.new do |s|
  s.name             = 'new_deeplinks'
  s.version          = '0.1.2'
  s.summary          = 'Deep linking and install attribution client for a self-hosted spbse server.'
  s.homepage         = 'https://github.com/Ellweb3/deeplinks-flutter'
  s.license          = { :file => '../LICENSE' }
  s.author           = 'spbse'
  s.source           = { :path => '.' }
  s.source_files     = 'new_deeplinks/Sources/new_deeplinks/**/*.swift'
  s.dependency 'Flutter'
  s.platform         = :ios, '15.0'
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES', 'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'i386' }
  s.swift_version    = '5.0'
  s.resource_bundles = { 'new_deeplinks_privacy' => ['new_deeplinks/Sources/new_deeplinks/PrivacyInfo.xcprivacy'] }
end
