# Adds the notification service extension (tools/ios/notification-service) to the Xcode project that
# `cap add ios` regenerates on every build, and embeds it in the app. Run from the repository root.
# Env: BUNDLE_ID, MARKETING_VERSION, BUILD_NUMBER (the extension must carry the app's own version).
require "xcodeproj"
require "fileutils"

NAME = "NotificationService"
bundle = ENV.fetch("BUNDLE_ID")
version = ENV.fetch("MARKETING_VERSION")
build = ENV.fetch("BUILD_NUMBER")

project = Xcodeproj::Project.open("ios/App/App.xcodeproj")
app = project.targets.find { |t| t.name == "App" } or abort("::error::No App target")
abort("::error::#{NAME} target already exists") if project.targets.any? { |t| t.name == NAME }

FileUtils.mkdir_p("ios/App/#{NAME}")
%w[NotificationService.swift Info.plist].each do |f|
  FileUtils.cp(File.join(__dir__, "notification-service", f), "ios/App/#{NAME}/#{f}")
end

release = ->(list) { list.find { |c| c.name == "Release" }.build_settings }
deployment = release.call(app.build_configurations)["IPHONEOS_DEPLOYMENT_TARGET"] ||
             release.call(project.build_configurations)["IPHONEOS_DEPLOYMENT_TARGET"] || "15.0"
family = release.call(app.build_configurations)["TARGETED_DEVICE_FAMILY"] || "1,2"

ext = project.new_target(:app_extension, NAME, :ios, deployment)
group = project.main_group.new_group(NAME, NAME)
ext.add_file_references([group.new_reference("NotificationService.swift")])
group.new_reference("Info.plist")

ext.build_configurations.each do |config|
  config.build_settings.merge!(
    "PRODUCT_BUNDLE_IDENTIFIER" => "#{bundle}.notificationservice",
    "PRODUCT_NAME" => "$(TARGET_NAME)",
    "INFOPLIST_FILE" => "#{NAME}/Info.plist",
    "GENERATE_INFOPLIST_FILE" => "NO",
    "SWIFT_VERSION" => "5.0",
    "IPHONEOS_DEPLOYMENT_TARGET" => deployment,
    "TARGETED_DEVICE_FAMILY" => family,
    "MARKETING_VERSION" => version,
    "CURRENT_PROJECT_VERSION" => build,
    "SKIP_INSTALL" => "YES"
  )
end

app.add_dependency(ext)
embed = app.new_copy_files_build_phase("Embed Foundation Extensions")
embed.symbol_dst_subfolder_spec = :plug_ins
embed.add_file_reference(ext.product_reference).settings = { "ATTRIBUTES" => ["RemoveHeadersOnCopy"] }
project.save
puts "#{NAME} (#{bundle}.notificationservice #{version}/#{build}, iOS #{deployment}) added and embedded."
