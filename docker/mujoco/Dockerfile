# ROS 2 Jazzy + mujoco_ros2_control for the Asterism S1 rover
# (fmruby-core/doc/ruby_asterism/instruction_s1.md). Built by
# docker-compose.mujoco.yml; the model, configuration and launch file are
# mounted from this directory at run time, not copied in.
#
# MIT License (same as Family mruby). The packages installed below keep
# their own licenses (MuJoCo and mujoco_ros2_control: Apache-2.0).
FROM ros:jazzy-ros-base

# rmw_zenoh (the router is the compose zenohd, as in docker-compose.ros2.yml).
RUN apt-get update \
 && apt-get install -y --no-install-recommends ros-jazzy-rmw-zenoh-cpp \
 && rm -rf /var/lib/apt/lists/*

# The simulator and the controllers:
# - mujoco_ros2_control (0.1.x, MuJoCo 3.12 through mujoco_vendor) and its
#   plugins (CameraPlugin renders the MJCF cameras)
# - diff_drive_controller, joint_state_broadcaster, imu_sensor_broadcaster
# - robot_state_publisher, xacro, ros2controlcli (ros2 control ...)
# - image_transport + compressed_image_transport (raw image -> JPEG)
# - twist_stamper (geometry_msgs/Twist on /cmd_vel -> TwistStamped, which
#   Jazzy's diff_drive_controller takes)
# - Mesa's EGL and llvmpipe: CameraPlugin falls back to a surfaceless EGL
#   context when there is no display, which Mesa renders on the CPU
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      ros-jazzy-mujoco-ros2-control \
      ros-jazzy-mujoco-ros2-control-plugins \
      ros-jazzy-diff-drive-controller \
      ros-jazzy-joint-state-broadcaster \
      ros-jazzy-imu-sensor-broadcaster \
      ros-jazzy-robot-state-publisher \
      ros-jazzy-xacro \
      ros-jazzy-image-transport \
      ros-jazzy-compressed-image-transport \
      ros-jazzy-twist-stamper \
      ros-jazzy-ros2controlcli \
      libegl1 libegl-mesa0 libgl1-mesa-dri libglx-mesa0 \
 && rm -rf /var/lib/apt/lists/*
