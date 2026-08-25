Pod::Spec.new do |s|
    s.name = 'DataroidCore'
    s.version = '4.6.2-alpha.1'
    s.summary = 'Analytics and Customer Engagement Tool'
    s.homepage = 'https://github.com/dataroid/dataroid-sdk-ios'

    s.author = { 'Dataroid SDK Team' => 'sdk@dataroid.com' }
    s.license = { :type => 'Dataroid', :file => 'LICENSE' }

    s.platform = :ios
    s.source = { :git => 'https://github.com/dataroid/dataroid-sdk-ios.git', :tag => s.version.to_s }
    s.preserve_paths = [
        'Dataroid/upload_dsym.sh',
        'Dataroid/build_helper.sh'
    ]

    s.ios.deployment_target = '12.0'
    s.ios.vendored_frameworks = 'Dataroid/DataroidSDK.xcframework'
end
