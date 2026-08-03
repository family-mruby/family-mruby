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
    dump = sys.argv[4] if len(sys.argv) > 4 else ""

    RING = 2048 * 2                      # stereo int16 slots

    # The audio section is the tail of struct fmrb_shm_t:
    #   ... audio_ring[RING] (int16), audio_write_pos, audio_read_pos (uint32)
    # Taking the offsets from the end of the mapping avoids having to guess
    # the padding the compiler inserted before the display fields.
    size = os.path.getsize(path)
    RPOS_OFF = size - 4
    WPOS_OFF = size - 8
    RING_OFF = WPOS_OFF - RING * 2

    if RING_OFF < 0:
        print("ERR shared memory is %d bytes, too small" % size)
        sys.exit(1)

    f = open(path, "rb")
    mm = mmap.mmap(f.fileno(), 0, access=mmap.ACCESS_READ)

    def wpos():
        return struct.unpack_from("<I", mm, WPOS_OFF)[0]

    def grab(prev, cur):
        # audio_write_pos is a position inside the ring (the writer keeps it
        # reduced modulo the ring size), so the delta wraps too.
        n = (cur - prev) % RING
        if n == 0:
            return b""
        start = prev % RING
        if start + n <= RING:
            return mm[RING_OFF + start * 2 : RING_OFF + (start + n) * 2]
        first = RING - start
        return mm[RING_OFF + start * 2 : RING_OFF + RING * 2] + \\
               mm[RING_OFF : RING_OFF + (n - first) * 2]

    out = open(dump, "wb") if dump else None
    prev = wpos()
    end = time.monotonic() + duration
    while time.monotonic() < end:
        time.sleep(interval)
        cur = wpos()
        raw = grab(prev, cur)
        prev = cur
        if not raw:
            continue
        if out:
            out.write(raw)
        samples = struct.unpack("<%dh" % (len(raw) // 2), raw)
        peak = max(abs(s) for s in samples)
        rms = (sum(float(s) * s for s in samples) / len(samples)) ** 0.5
        print("W %d %d %.1f" % (len(samples), peak, rms))
    if out:
        out.close()
    mm.close()
  PYTHON

  module_function

  # Where the container writes raw samples when --dump is used.
  REMOTE_DUMP = "/tmp/fmrb_audio_probe.raw"

  def sample(duration, interval, dump)
    args = [duration.to_s, interval.to_s, SHM_PATH]
    if File.exist?(SHM_PATH)
      args << (dump ? dump : "")
      out = IO.popen(["python3", "-", *args], "r+") do |io|
        io.write(READER)
        io.close_write
        io.read
      end
      return [out, "host"]
    end

    args << (dump ? REMOTE_DUMP : "")
    cmd = ["docker", "exec", "-i", CONTAINER, "python3", "-", *args]
    out = IO.popen(cmd, "r+") do |io|
      io.write(READER)
      io.close_write
      io.read
    end
    fetch_dump(dump) if dump
    [out, "container"]
  end

  # Pull the raw capture out of the container and wrap it in a WAV header so
  # tool/midi/wav_pitch.rb (or any player) can read it.
  def fetch_dump(path)
    raw = IO.popen(["docker", "exec", CONTAINER, "cat", REMOTE_DUMP], "rb", &:read)
    if raw.nil? || raw.empty?
      warn "fmrb_audio_probe: capture is empty"
      return
    end
    File.binwrite(path, wav_header(raw.bytesize) + raw)
    system("docker", "exec", CONTAINER, "rm", "-f", REMOTE_DUMP, out: File::NULL, err: File::NULL)
  end

  def wav_header(bytes)
    channels = 2
    bits = 16
    block_align = channels * bits / 8
    byte_rate = SAMPLE_RATE * block_align
    "RIFF" + [36 + bytes].pack("V") + "WAVEfmt " + [16, 1, channels, SAMPLE_RATE,
                                                    byte_rate, block_align, bits].pack("VvvVVvv") +
      "data" + [bytes].pack("V")
  end

  def run(argv)
    options = { duration: 2.0, interval: 0.05, quiet: false, dump: nil }
    OptionParser.new do |o|
      o.banner = "Usage: fmrb_audio_probe.rb [options]"
      o.on("--duration SEC", Float, "how long to watch (default 2.0)") { |v| options[:duration] = v }
      o.on("--interval SEC", Float, "polling interval (default 0.05)") { |v| options[:interval] = v }
      o.on("-q", "--quiet", "summary only") { options[:quiet] = true }
      o.on("--dump PATH", "also write the captured audio as a WAV file") { |v| options[:dump] = v }
      o.on("-h", "--help") do
        puts o
        return 0
      end
    end.parse!(argv)

    out, source = sample(options[:duration], options[:interval], options[:dump])
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
