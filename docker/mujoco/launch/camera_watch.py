# Asterism rover (S1): keeps the camera's JPEG stream on and logs its rate.
# MIT License (same as Family mruby).
#
# image_transport's republish is lazy: it only compresses while a ROS
# subscriber is matched (rmw_zenoh: a subscriber's liveliness token). A
# plain Zenoh subscriber (asterism-console's watch, rates and recordings)
# has no such token, so without a subscriber of this kind the stream stays
# silent. This node is that subscriber; it also logs the rate and the
# frame size every 30 s.
import time

import rclpy
from rclpy.node import Node
from sensor_msgs.msg import CompressedImage


class CameraWatch(Node):
    def __init__(self):
        super().__init__("camera_watch")
        self.count = 0
        self.bytes = 0
        self.since = time.monotonic()
        self.create_subscription(CompressedImage, "/camera/image/compressed", self.got, 10)
        self.create_timer(30.0, self.report)

    def got(self, msg):
        self.count += 1
        self.bytes += len(msg.data)

    def report(self):
        span = time.monotonic() - self.since
        if self.count:
            self.get_logger().info(
                "/camera/image/compressed: %.2f Hz, %.0f bytes a frame" % (self.count / span, self.bytes / self.count))
        else:
            self.get_logger().warn("/camera/image/compressed: nothing in %.0f s" % span)
        self.count = 0
        self.bytes = 0
        self.since = time.monotonic()


def main():
    rclpy.init()
    node = CameraWatch()
    try:
        rclpy.spin(node)
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
