#!/usr/bin/env ruby
# frozen_string_literal: true
#
# fmrb_audio_probe - check whether the Linux simulation is actually producing
# sound, without a speaker.
#
# The graphics-audio process publishes mixed APU output into the same POSIX
# shared memory as the framebuffer (fmruby-graphics-audio/main/common/
# shm_display.h). Headless runs use the SDL dummy audio driver, so nothing is
# audible, but the samples are still written there - which makes it possible
# to verify audio from an agent or from CI, the way fmrb_screenshot.py
# verifies the screen.
#
# Usage:
#   ruby tools/fmrb_audio_probe.rb [--duration 2.0] [--interval 0.05]
#
# Prints one line per polling window (samples, peak, RMS) and a summary.
# Exit status: 0 sound was heard, 2 the path ran but stayed silent,
# 1 could not read the shared memory at all.
#
# On Docker Desktop / WSL2 the host cannot see the container's /dev/shm, so
# the sampling loop is executed inside the graphics-audio container with
# python3 (that image has no ruby - see the tooling note in CLAUDE.md).

require "optparse"

module FmrbAudioProbe
  SHM_PATH = "/dev/shm/fmrb_display"
  CONTAINER = "fmruby_graphics_audio"
  SAMPLE_RATE = 15720

  # The sampling loop, shared by the host and container paths.
  READER = <<~PYTHON
    import mmap, os, struct, sys, time

    duration = float(sys.argv[1])
    interval = float(sys.argv[2])
    path = sys.argv[3]

    MAX_W, MAX_H = 480, 320
    FRAMEBUF = MAX_W * MAX_H
    RING = 2048 * 2                      # stereo int16 slots
    # struct fmrb_shm_t: magic, display_initialized, shutdown_requested,
    # width, height, color_depth, scaling_x, scaling_y, then framebuf.
    HEADER = 4 + 1 + 1 + 2 + 2 + 1 + 1 + 1 + 1
    RING_OFF = HEADER + 2 * FRAMEBUF + 4 + 4
    WPOS_OFF = RING_OFF + RING * 2

    size = os.path.getsize(path)
    if size < WPOS_OFF + 8:
        print("ERR shared memory is %d bytes, too small" % size)
        sys.exit(1)

    f = open(path, "rb")
    mm = mmap.mmap(f.fileno(), 0, access=mmap.ACCESS_READ)

    def wpos():
        return struct.unpack_from("<I", mm, WPOS_OFF)[0]

    def grab(prev, cur):
        # audio_write_pos free-runs (it is only reduced modulo the ring size
        # when indexing), so the delta has to be taken in uint32 space and
        # the start position wrapped into the ring.
        n = (cur - prev) & 0xFFFFFFFF
        if n == 0:
            return b""
        if n > RING:
            n = RING            # fell behind: keep the most recent ring-full
        start = (cur - n) % RING
        if start + n <= RING:
            return mm[RING_OFF + start * 2 : RING_OFF + (start + n) * 2]
        first = RING - start
        return mm[RING_OFF + start * 2 : RING_OFF + RING * 2] + \\
               mm[RING_OFF : RING_OFF + (n - first) * 2]

    prev = wpos()
    end = time.monotonic() + duration
    while time.monotonic() < end:
        time.sleep(interval)
        cur = wpos()
        raw = grab(prev, cur)
        prev = cur
        if not raw:
            continue
        samples = struct.unpack("<%dh" % (len(raw) // 2), raw)
        peak = max(abs(s) for s in samples)
        rms = (sum(float(s) * s for s in samples) / len(samples)) ** 0.5
        print("W %d %d %.1f" % (len(samples), peak, rms))
    mm.close()
  PYTHON

  module_function

  def sample(duration, interval)
    if File.exist?(SHM_PATH)
      out = IO.popen(["python3", "-", duration.to_s, interval.to_s, SHM_PATH], "r+") do |io|
        io.write(READER)
        io.close_write
        io.read
      end
      return [out, "host"]
    end

    cmd = ["docker", "exec", "-i", CONTAINER, "python3", "-",
           duration.to_s, interval.to_s, SHM_PATH]
    out = IO.popen(cmd, "r+") do |io|
      io.write(READER)
      io.close_write
      io.read
    end
    [out, "container"]
  end

  def run(argv)
    options = { duration: 2.0, interval: 0.05, quiet: false }
    OptionParser.new do |o|
      o.banner = "Usage: fmrb_audio_probe.rb [options]"
      o.on("--duration SEC", Float, "how long to watch (default 2.0)") { |v| options[:duration] = v }
      o.on("--interval SEC", Float, "polling interval (default 0.05)") { |v| options[:interval] = v }
      o.on("-q", "--quiet", "summary only") { options[:quiet] = true }
      o.on("-h", "--help") do
        puts o
        return 0
      end
    end.parse!(argv)

    out, source = sample(options[:duration], options[:interval])
    if out.nil? || out.strip.empty?
      warn "fmrb_audio_probe: no data (is the simulation running?)"
      return 1
    end
    if out.include?("ERR")
      warn "fmrb_audio_probe: #{out.strip}"
      return 1
    end

    windows = 0
    total = 0
    peak = 0
    sounding = 0
    rms_sum = 0.0
    out.each_line do |line|
      next unless line.start_with?("W ")

      _, count, window_peak, rms = line.split
      windows += 1
      total += count.to_i
      peak = window_peak.to_i if window_peak.to_i > peak
      sounding += 1 if window_peak.to_i > 256
      rms_sum += rms.to_f * count.to_i
      unless options[:quiet]
        printf("  %6d samples  peak=%6d  rms=%8.1f\n", count.to_i, window_peak.to_i, rms.to_f)
      end
    end

    if windows.zero?
      puts "no audio written (the audio side may be idle or stopped)"
      return 1
    end

    printf("[%s] windows=%d samples=%d (%.2f s) peak=%d avg_rms=%.1f sounding_windows=%d\n",
           source, windows, total, total / 2.0 / SAMPLE_RATE, peak,
           rms_sum / [total, 1].max, sounding)
    peak > 256 ? 0 : 2
  end
end

exit(FmrbAudioProbe.run(ARGV)) if $PROGRAM_NAME == __FILE__
