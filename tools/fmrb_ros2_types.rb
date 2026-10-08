#!/usr/bin/env ruby
# frozen_string_literal: true
#
# fmrb_ros2_types.rb: refresh the ROS 2 message types bundled with Asterism,
# using this repository's ROS 2 image (fmruby-core/doc/ruby_asterism, R3, C2).
#
#   ruby tools/fmrb_ros2_types.rb             # refresh the bundled types
#   ruby tools/fmrb_ros2_types.rb --check     # only compare, change nothing
#   ruby tools/fmrb_ros2_types.rb --fixtures  # refresh the test fixtures
#
# The work is done by tools/ros2_types.rb of the asterism repository (the
# source of the types since C2; ruby-asterism/asterism). This wrapper builds
# the ROS 2 Jazzy image of docker-compose.ros2.yml when it is missing and
# passes it on. The asterism checkout is ../asterism next to fmruby-core
# (ASTERISM_DIR overrides); the refreshed files land there, to be committed
# in asterism and then pinned by fmruby-core (lib/add/ASTERISM_PIN).
ROOT = File.expand_path("..", __dir__)
IMAGE = "fmruby-ros2-jazzy-zenoh:local"
ASTERISM = File.expand_path(ENV["ASTERISM_DIR"] || File.join(ROOT, "asterism"))
SCRIPT = File.join(ASTERISM, "tools", "ros2_types.rb")

abort "asterism checkout not found at #{ASTERISM} (set ASTERISM_DIR)" unless File.file?(SCRIPT)

unless system("docker image inspect #{IMAGE} > /dev/null 2>&1")
  system("docker compose -f #{ROOT}/docker-compose.yml -f #{ROOT}/docker-compose.ros2.yml build ros2") ||
    abort("failed to build #{IMAGE}")
end

exec(RbConfig.ruby, SCRIPT, "--image", IMAGE, *ARGV)
