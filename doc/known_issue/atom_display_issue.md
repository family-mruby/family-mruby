---
name: ATOM Display HDMI rendering constraints
description: Panel_M5HDMI (FPGA) technical constraints for HDMI output - PSRAM pushSprite causes corruption, direct draw is stable
type: project
---

Panel_M5HDMI (Atom Display) has no VSYNC synchronization. FPGA busy polling via `_check_busy()` every 512 bytes.

**Why:** PSRAM-backed Sprite pushSprite sends ~153KB continuously via SPI, overwhelming FPGA's internal buffer. Direct draw commands (fillRect, drawLine etc.) use FPGA-native commands (CMD_FILLRECT, CMD_WRITE_RAW) that are small SPI packets and work stably.

**How to apply:**
- Use direct draw mode (get_target returns g_display, hold SPI bus with startWrite)
- Never use pushSprite from PSRAM Sprite to display
- Future Canvas compositing should use FPGA's CMD_COPYRECT (0x23) for in-FPGA framebuffer copy
- CMD_FILLRECT (0x68) also available for FPGA-side rectangle fill
- video_timing parameters (setVideoTiming) can adjust blanking periods

