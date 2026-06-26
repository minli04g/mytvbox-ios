# Prepares the Xcode project for a CI build (idempotent — safe to run after
# every `cap sync`). Uses the xcodeproj gem (in the Gemfile) so we never
# hand-edit project.pbxproj.
#
#  1. Register our hand-added native plugin sources into the App target.
#     This project uses classic (non-synchronized) file references, so a .swift
#     file dropped into ios/App/App/ is NOT compiled until it's listed in the
#     pbxproj. cap add/sync never touch it, hence this step.
#  2. CURRENT_PROJECT_VERSION = $BUILD_NUMBER (unique TestFlight build #).
#
# mytvbox needs no entitlements file (AirPlay + Local Network are Info.plist
# only), so unlike the safebrowser template we do NOT set CODE_SIGN_ENTITLEMENTS.
require 'xcodeproj'

PLUGIN_SOURCES = ['NativePlayer.swift'].freeze

project_path = File.expand_path('../ios/App/App.xcodeproj', __dir__)
project = Xcodeproj::Project.open(project_path)
target = project.targets.find { |t| t.name == 'App' }
raise 'App target not found' unless target

# Find the group that holds AppDelegate.swift (the App/App source group).
group = project.main_group.recursive_children.find do |c|
  c.is_a?(Xcodeproj::Project::Object::PBXGroup) &&
    c.files.any? { |f| f.display_name == 'AppDelegate.swift' }
end
raise 'App source group (with AppDelegate.swift) not found' unless group

PLUGIN_SOURCES.each do |fname|
  already_built = target.source_build_phase.files_references.any? { |r| r&.display_name == fname }
  next if already_built

  fref = group.files.find { |f| f.display_name == fname } || group.new_file(fname)
  target.add_file_references([fref])
  puts "registered #{fname} into App target"
end

build_number = ENV['BUILD_NUMBER']
target.build_configurations.each do |config|
  config.build_settings['CURRENT_PROJECT_VERSION'] = build_number if build_number && !build_number.empty?
end

project.save
puts "prepared#{build_number && !build_number.empty? ? " (build #{build_number})" : ''}"
