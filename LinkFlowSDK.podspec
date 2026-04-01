Pod::Spec.new do |s|
  s.name             = 'LinkFlowSDK'
  s.version          = '1.0.0'
  s.summary          = 'Mobile attribution and deep linking SDK for iOS'
  s.description      = <<-DESC
    LinkFlow SDK provides deferred deep linking, attribution tracking, and event tracking for iOS apps.
    Features include universal links, custom URL schemes, IDFA tracking, device fingerprinting, and more.
  DESC

  s.homepage         = 'https://github.com/thelinkflow/linkflow-ios-sdk'
  s.license          = { :type => 'MIT', :file => 'LICENSE' }
  s.author           = { 'LinkFlow' => 'dev@thelinkflow.app' }
  s.source           = { :git => 'https://github.com/thelinkflow/linkflow-ios-sdk.git', :tag => s.version.to_s }

  s.ios.deployment_target = '13.0'
  s.swift_version = '5.9'

  s.source_files = 'Sources/LinkFlowSDK/**/*'

  s.frameworks = 'UIKit', 'Foundation', 'AdSupport', 'AppTrackingTransparency'
end
