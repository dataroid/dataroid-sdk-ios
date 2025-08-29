Pod::Spec.new do |s|
    s.name = 'DataroidSnapshot'
    s.version = '4.0.0-alpha.6'
    s.summary = 'Snapshot utility for Dataroid framework'
    s.homepage = 'https://github.com/dataroid/dataroid-sdk-ios'

    s.author = { 'Dataroid SDK Team' => 'sdk@dataroid.com' }
    s.license = { :type => 'Dataroid', :file => 'LICENSE' }

    s.platform = :ios
    s.source = { :git => 'https://github.com/dataroid/dataroid-sdk-ios.git', :tag => s.version.to_s }

    s.ios.deployment_target = '15.0'
    s.ios.vendored_frameworks = 'DataroidSnapshot/DataroidSnapshotSDK.xcframework'
end
