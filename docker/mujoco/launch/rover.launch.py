# Asterism rover (S1): MuJoCo + ros2_control, the controllers, the camera's
# JPEG stream and the /cmd_vel stamper. MIT License (same as Family mruby).
#
#   ros2 launch /asterism_rover/launch/rover.launch.py [headless:=true|false]
#
# Topics for the Asterism side:
#   /cmd_vel                  geometry_msgs/Twist (in; send at 2 Hz or more,
#                             the controller stops after 0.5 s without one)
#   /odom                     nav_msgs/Odometry, wheel odometry (20 Hz)
#   /ground_truth/odom        nav_msgs/Odometry, the simulator's true pose
#   /joint_states             sensor_msgs/JointState
#   /imu                      sensor_msgs/Imu
#   /camera/image/compressed  sensor_msgs/CompressedImage, 160x120 JPEG, 5 Hz
#                             (always on: camera_watch.py subscribes to it)
#   /camera/image_raw, /camera/camera_info, /camera/depth (from the plugin)

from launch import LaunchDescription
from launch.actions import DeclareLaunchArgument, ExecuteProcess, OpaqueFunction, Shutdown
from launch.substitutions import Command, LaunchConfiguration
from launch_ros.actions import Node
from launch_ros.parameter_descriptions import ParameterFile, ParameterValue

ROOT = "/asterism_rover"


def launch_setup(context, *args, **kwargs):
    headless = LaunchConfiguration("headless").perform(context)
    jpeg_quality = LaunchConfiguration("jpeg_quality").perform(context)

    description = Command(
        ["xacro ", f"{ROOT}/model/rover.urdf.xacro", f" headless:={headless}", f" model_dir:={ROOT}/model"]
    ).perform(context)
    robot_description = {"robot_description": ParameterValue(value=description, value_type=str)}
    controllers = ParameterFile(f"{ROOT}/config/controllers.yaml")
    plugins = ParameterFile(f"{ROOT}/config/mujoco_plugins.yaml")

    nodes = [
        Node(
            package="robot_state_publisher",
            executable="robot_state_publisher",
            output="both",
            parameters=[robot_description, {"use_sim_time": True}],
        ),
        # The simulator and the controller manager in one process.
        Node(
            package="mujoco_ros2_control",
            executable="ros2_control_node",
            output="both",
            emulate_tty=True,
            parameters=[{"use_sim_time": True}, controllers, plugins],
            on_exit=Shutdown(),
        ),
        # Twist (/cmd_vel) -> TwistStamped (Jazzy's diff_drive_controller).
        # Sim time, so the stamp is on the controller's clock.
        Node(
            package="twist_stamper",
            executable="twist_stamper",
            output="both",
            parameters=[{"use_sim_time": True, "frame_id": "base_link"}],
            remappings=[("cmd_vel_in", "/cmd_vel"), ("cmd_vel_out", "/cmd_vel_stamped")],
        ),
        # Raw 160x120 RGB -> JPEG on /camera/image/compressed.
        Node(
            package="image_transport",
            executable="republish",
            name="camera_jpeg",
            output="both",
            parameters=[
                {
                    "in_transport": "raw",
                    "out_transport": "compressed",
                    "out.compressed.format": "jpeg",
                    "out.compressed.jpeg_quality": int(jpeg_quality),
                }
            ],
            remappings=[("in", "/camera/image_raw"), ("out/compressed", "/camera/image/compressed")],
        ),
        # republish only compresses while a ROS subscriber is there; this one
        # keeps the stream on for plain Zenoh subscribers (asterism-console)
        # and logs the rate every 30 s.
        ExecuteProcess(cmd=["python3", f"{ROOT}/launch/camera_watch.py"], output="both"),
    ]

    # The controllers, their topics remapped to the plain names.
    remaps = {
        "joint_state_broadcaster": [],
        "diff_drive_controller": ["-r", "~/odom:=/odom", "-r", "~/cmd_vel:=/cmd_vel_stamped"],
        "imu_sensor_broadcaster": ["-r", "~/imu:=/imu"],
    }
    for name, remap in remaps.items():
        args = [name, "--controller-manager", "/controller_manager", "--param-file", f"{ROOT}/config/controllers.yaml"]
        if remap:
            args += ["--controller-ros-args", " ".join(remap)]
        nodes.append(
            Node(
                package="controller_manager",
                executable="spawner",
                arguments=args,
                output="both",
            )
        )
    return nodes


def generate_launch_description():
    return LaunchDescription(
        [
            DeclareLaunchArgument("headless", default_value="true", description="no MuJoCo viewer window"),
            DeclareLaunchArgument("jpeg_quality", default_value="80", description="JPEG quality (1-100)"),
            OpaqueFunction(function=launch_setup),
        ]
    )
