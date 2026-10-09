# MuJoCo rover over ROS 2 (Asterism S1)

A small two-wheeled robot in MuJoCo, driven through ROS 2 (Jazzy, rmw_zenoh)
by [mujoco_ros2_control](https://github.com/ros-controls/mujoco_ros2_control)
and the standard ros2_control controllers. Asterism nodes (CRuby, the
Family mruby sim, a board) drive it with `/cmd_vel` and read `/odom`,
`/imu`, `/joint_states` and the camera, through the same zenohd router as
the rest of this repository. Background and measurements:
`fmruby-core/doc/ruby_asterism/report/s1.md`.

Everything here is our own (MIT, as Family mruby). MuJoCo and
mujoco_ros2_control are Apache-2.0 and are installed into the image from
the ROS 2 apt repository, not copied here.

## What is in it

| File | |
|---|---|
| `Dockerfile` | `ros:jazzy-ros-base` + rmw_zenoh, mujoco_ros2_control (0.1.x, MuJoCo 3.12), diff_drive_controller, joint_state_broadcaster, imu_sensor_broadcaster, robot_state_publisher, image_transport's JPEG plugin, twist_stamper, ros2controlcli, Mesa's EGL |
| `model/rover.xml` | the robot (MJCF): box body, two wheels with velocity servos, a frictionless rear caster, an IMU site, a 160x120 camera looking forward |
| `model/scene.xml` | the world: floor, light, four coloured pillars 2 m from the start (red ahead, green left, blue behind, yellow right) and two boxes |
| `model/rover.urdf.xacro` | the same robot for robot_state_publisher and ros2_control (hardware plugin, joints, IMU) |
| `config/controllers.yaml` | controller_manager (100 Hz), diff_drive_controller, the broadcasters |
| `config/mujoco_plugins.yaml` | the camera plugin (5 Hz) |
| `launch/rover.launch.py` | starts all of it; `launch/camera_watch.py` keeps the JPEG stream on |

The wheel radius (0.05 m) and separation (0.24 m) are written in three
places: `rover.xml`, `rover.urdf.xacro` and `controllers.yaml`. Change them
together.

## Topics

| Topic | Type | |
|---|---|---|
| `/cmd_vel` | geometry_msgs/Twist | in. Send it at 2 Hz or more: the controller stops the robot 0.5 s after the last one. One sender at a time (two senders, even one sending zeros, make the robot jerk and slip) |
| `/odom` | nav_msgs/Odometry | wheel odometry, 20 Hz, frame `odom` -> `base_link` (also on `/tf`) |
| `/ground_truth/odom` | nav_msgs/Odometry | the simulator's true pose of the body (to check `/odom`), at the control rate |
| `/imu` | sensor_msgs/Imu | 50 Hz, frame `imu_link` |
| `/joint_states` | sensor_msgs/JointState | the two wheels, 50 Hz |
| `/camera/image/compressed` | sensor_msgs/CompressedImage | 160x120 JPEG (quality 80), 5 Hz, about 2.8 KB a frame |
| `/camera/image_raw`, `/camera/camera_info`, `/camera/depth` | | the camera plugin's own |

Jazzy's diff_drive_controller takes `TwistStamped` only; twist_stamper turns
`/cmd_vel` into `/cmd_vel_stamped` for it. The JPEG is made by
image_transport's `republish`, which only works while a ROS subscriber is
there; `camera_watch.py` is that subscriber, so plain Zenoh subscribers
(asterism-console) see the stream too. It logs the rate every 30 s.

## Start and stop

From the root of this repository. The first `up` builds the image
(`fmruby-mujoco-jazzy:local`, a few minutes).

```
# headless (the camera renders with Mesa on the CPU through EGL)
docker compose -f docker-compose.yml -f docker-compose.mujoco.yml up -d zenohd mujoco

# a board on WiFi too: open zenohd to the LAN
docker compose -f docker-compose.yml -f docker-compose.zenoh-lan.yml \
  -f docker-compose.mujoco.yml up -d zenohd mujoco

# is it up? (three controllers, all active)
docker exec fmruby_mujoco ros2 control list_controllers

# stop (everything of this compose project, the network too)
docker compose -f docker-compose.yml -f docker-compose.mujoco.yml down
```

The Family mruby sim (`sim_up`, or the main `docker-compose.yml`) recreates
zenohd; start the mujoco service after it (or restart it with
`docker restart fmruby_mujoco`), so the ROS 2 nodes join the new router.
The model and configuration are mounted, not copied: after an edit,
`docker restart fmruby_mujoco` is enough.

## Drive it

From the ROS 2 side (the container has the ros2 command line):

```
docker exec -it fmruby_mujoco ros2 topic pub -r 10 /cmd_vel \
  geometry_msgs/msg/Twist "{linear: {x: 0.2}, angular: {z: 0.0}}"
docker exec -it fmruby_mujoco ros2 topic echo /odom --field pose.pose.position
```

From CRuby (the asterism checkout next to this repository):

```
ruby ../asterism/examples/ros2_rover.rb --router tcp/127.0.0.1:7447          # 1 m forward, 90 deg left, odom vs truth
ruby ../asterism/examples/ros2_rover.rb --router tcp/127.0.0.1:7447 --keys   # w/x/a/d/s, q
```

From Family mruby: `/app/test/ros2_drive.app.rb` (arrow keys, space stops;
it shows the odometry). The board reads the router's address from
`/home/zenoh_echo.txt` as the other Asterism test apps do.

To start again from the origin, restart the container
(`docker restart fmruby_mujoco`).

## The demo: drive from a board, watch on the console (S3)

A Modern board (P4) drives the rover with its arrow keys and shows the
rover's camera and odometry on its own screen; asterism-console shows the
same drive (graph, camera, odometry plot), records it to MCAP and rewinds
it. Measurements: `fmruby-core/doc/ruby_asterism/report/s3.md`.

Commands run from the root of this repository; asterism-console is the
checkout next to `fmruby-core` (`asterism-console/`). Addresses below are
examples: `192.0.2.10` is this PC on the LAN, `192.0.2.20` the board (its
mDNS name `fmruby-aaaaaa.local` works too).

**One driver at a time.** The board app sends `/cmd_vel` only while it is
moving the rover and sends one stop when it stops; do not drive from CRuby
or `ros2 topic pub` at the same time.

### 1. The rover, with the router open to the LAN

```
docker compose -f docker-compose.yml -f docker-compose.zenoh-lan.yml \
  -f docker-compose.mujoco.yml up -d zenohd mujoco
docker exec fmruby_mujoco /ros_entrypoint.sh ros2 control list_controllers   # three, all active
```

To watch the simulation as well, start it with the viewer instead (see
"The MuJoCo viewer on WSLg" below: add `-f docker-compose.mujoco-wslg.yml`
to the same `up`).

### 2. asterism-console

In two terminals:

```
cd asterism-console
bin/rails console:user EMAIL=me@example.org ADMIN=1   # once; asks for a password
bin/rails server
```

```
cd asterism-console
bin/bridge
```

Open http://127.0.0.1:3000 and sign in. The graph shows the rover's ROS 2
nodes (`/mujoco_ros2_control_node`, `/diff_drive_controller`,
`/camera_jpeg`, `/camera_watch` and the rest).

### 3. The board app

The board needs a firmware whose `/usr/share/asterism/msgs` has
`geometry_msgs` (asterism 0.4.1 or later; otherwise push
`fmruby-core/flash/usr/share/asterism/msgs` there). Tell it where the
router is, send the app and start it:

```
BOARD=192.0.2.20
echo "tcp/192.0.2.10:7447" > /tmp/zenoh_echo.txt
ruby tools/fmrb_rd_fs.rb $BOARD put /tmp/zenoh_echo.txt /home/zenoh_echo.txt
ruby tools/fmrb_rd_fs.rb $BOARD put fmruby-core/flash/app/test/rover_cam.app.rb /app/test/rover_cam.app.rb
ruby tools/fmrb_rd_fs.rb $BOARD put fmruby-core/flash/app/test/rover_cam.app.toml /app/test/rover_cam.app.toml
ruby tools/fmrb_rd_launch.rb $BOARD /app/test/rover_cam.app.rb
```

(Or launch "Rover Camera" from the board's launcher after a right-click
rescan.) The window shows the camera (160x120, about 5 Hz) on the left; on
the right the odometry (x, y, heading, speeds), the camera's rate, its
delay, how long one picture takes to draw, and the update loop's time.

On WSL2 with mirrored networking, Windows needs an inbound rule for TCP
7447 (see `docker-compose.zenoh-lan.yml`).

### 4. Watch it on the console

- **Graph**: click the board's node (`/fmruby_cam_fmruby_aaaaaa`): it
  publishes `/cmd_vel` and subscribes `/odom` and
  `/camera/image/compressed`.
- **Camera**: under "Watch a key", watch `0/camera/image/compressed/**`.
- **Odometry**: open "Plots" in a second tab, pick the source
  `/odom`, add `pose.pose.position.x, pose.pose.position.y`.

### 5. Record, drive, rewind

1. "Recordings": tick `/cmd_vel`, `/odom`, `/ground_truth/odom` and
   `/camera/image/compressed`, tick "The network structure", set
   "At most (seconds)" (60 is plenty), "Start recording".
2. Drive on the board: Up four times (0.2 m/s), wait about 5 s, Space;
   Left twice (0.6 rad/s), wait about 2.6 s, Space. That is about 1 m
   forward and 90 degrees left. The board, the graph, the camera and the
   plot all move together.
3. "Stop" (or let the time limit end it), then open the recording:
   - click the `/odom` row, tick `pose.pose.position.x` and
     `pose.pose.orientation.z`, "Plot";
   - click the `/camera/image/compressed` row anywhere on the time axis:
     the cursor moves, the picture at the cursor and "At the cursor" (the
     odometry, the true pose, the command at that time) follow; "Prev" /
     "Next" step one frame; "Play" plays it in the page;
   - "Network at the cursor" rewinds the graph to that time (the board's
     node is there while the recording runs).
4. To compare the odometry with the truth after the drive:
   `docker exec fmruby_mujoco /ros_entrypoint.sh ros2 topic echo --once /odom --field pose.pose`
   and the same for `/ground_truth/odom`. (`docker exec` does not source
   the ROS 2 setup by itself; `/ros_entrypoint.sh` does.)

### 6. Tidy up

```
ruby tools/fmrb_rd_ps.rb $BOARD                 # find the app's pid, then
ruby tools/fmrb_rd_kill.rb $BOARD <pid>         # (or Ctrl+Q on the board)
# Ctrl-C the bridge and the server
docker compose -f docker-compose.yml -f docker-compose.zenoh-lan.yml \
  -f docker-compose.mujoco.yml down
```

## The MuJoCo viewer on WSLg

The viewer is MuJoCo's simulate window, opened by the same process. On
WSL2 with WSLg:

```
docker compose -f docker-compose.yml -f docker-compose.mujoco.yml down   # if it runs headless
docker compose -f docker-compose.yml -f docker-compose.mujoco.yml \
  -f docker-compose.mujoco-wslg.yml up -d zenohd mujoco
```

- The window appears on the Windows desktop after a few seconds. Space
  pauses, the right arrow steps while paused; drag to turn the view, right
  drag to move, the wheel to zoom.
- `docker-compose.mujoco-wslg.yml` passes WSLg's X socket and the WSL GPU
  (`/dev/dxg`, `/usr/lib/wsl`, Mesa's d3d12 driver). Measured: the
  simulator's process at about 90 % of one core with the GPU, about 13
  cores without it. On a machine without a GPU for WSL, remove the
  `devices`, `LD_LIBRARY_PATH` and `GALLIUM_DRIVER` lines.
- Back to headless: `down`, then `up` without the wslg file.

## Offscreen pictures

MuJoCo's Python package can draw the scene without a window (for documents),
in a throwaway container from the same image:

```
docker run --rm -e MUJOCO_GL=egl -v $PWD/docker/mujoco:/asterism_rover:ro -v $PWD/out:/out \
  fmruby-mujoco-jazzy:local bash -c "pip install -q --break-system-packages mujoco pillow && python3 -c '
import mujoco; from PIL import Image
m = mujoco.MjModel.from_xml_path(\"/asterism_rover/model/scene.xml\"); d = mujoco.MjData(m); mujoco.mj_forward(m, d)
r = mujoco.Renderer(m, 480, 640); r.update_scene(d); Image.fromarray(r.render()).save(\"/out/scene.png\")'"
```

An `EGLError` traceback printed when Python exits (MuJoCo freeing its EGL
context after Mesa has gone) is harmless; the picture is already written.
Files written this way belong to root.

## Without ROS 2: the same robot as Asterism objects (S2)

The asterism repository's `examples/mujoco/` runs this robot's MJCF
(`rover.xml`, `scene.xml`, copied there) with MuJoCo's C library called
from CRuby through Fiddle, and exposes it as Asterism objects
(`mujoco/rover/drive`, `state`, `world`). It needs no image and no
container besides zenohd: MuJoCo's official release is fetched on the host
into `asterism/examples/mujoco/vendor/` (pinned version and sha256).

```
docker compose -f docker-compose.yml -f docker-compose.zenoh-lan.yml up -d zenohd
ruby asterism/examples/mujoco/fetch.rb           # once
ruby asterism/examples/mujoco/rover.rb --router tcp/127.0.0.1:7447
ruby asterism/examples/mujoco/drive.rb --router tcp/127.0.0.1:7447 [--keys]
```

From Family mruby: `/app/test/asterism_rover.app.rb` (arrow keys). The
zenoh-lan file is for a board on WiFi. This and the ROS 2 rover above are
two separate simulations of the same robot; they do not share a world.
Details: `fmruby-core/doc/ruby_asterism/report/s2.md`.
