Pod::Spec.new do |s|
  s.name         = "Lucida"
  s.version      = "0.1.0"
  s.summary      = "Lucida iOS SDK: analytics, feature flags and session replay."
  s.homepage     = "https://github.com/lucidaanalytics/lucida-ios"
  s.license      = { :type => "Apache-2.0" }
  s.author       = "Lucida"
  s.source       = { :git => "https://github.com/lucidaanalytics/lucida-ios.git", :tag => s.version.to_s }
  s.ios.deployment_target = "15.0"
  s.swift_version = "5.9"
  s.source_files = "Sources/Lucida/**/*.swift"
end
