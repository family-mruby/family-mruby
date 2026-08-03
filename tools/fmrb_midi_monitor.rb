#!/usr/bin/env ruby
# frozen_string_literal: true
#
# fmrb_midi_monitor - watch the MIDI bytes the simulation sends out.
#
# In the simulation the serial MIDI transport writes to a FIFO under
# fmruby-core/, which is bind-mounted into the container, so the bytes are
# readable from the host with no special privileges. This tool creates the
# FIFO, reads it, timestamps every byte, decodes the messages, and can hand
# them to a General MIDI synthesizer so the result can be listened to.
#
# Usage:
#   ruby tools/fmrb_midi_monitor.rb                      # decode to stdout
#   ruby tools/fmrb_midi_monitor.rb --hex                # raw bytes as well
#   ruby tools/fmrb_midi_monitor.rb --log out.jsonl      # machine readable
#   ruby tools/fmrb_midi_monitor.rb --fluidsynth         # play it (see --help)
#   ruby tools/fmrb_midi_monitor.rb --duration 5         # stop after 5 s
#
# The FIFO must exist before the firmware opens it, so start this first (or
# just run it once to create the FIFO and leave it in place).
#
# Only run ONE reader at a time. A FIFO hands each byte to whichever reader
# gets there first, so a second monitor - or the midi-gm container from
# docker-compose.midi.yml - splits the stream and both ends hear a song with
# holes in it.

require "optparse"

module FmrbMidiMonitor
  DEFAULT_FIFO = File.expand_path("../fmruby-core/midi_out.fifo", __dir__)

  NOTE_NAMES = %w[C C# D D# E F F# G G# A A# B].freeze

  # Bytes that follow each status, indexed by the high nibble.
  DATA_BYTES = {
    0x80 => 2, 0x90 => 2, 0xA0 => 2, 0xB0 => 2,
    0xC0 => 1, 0xD0 => 1, 0xE0 => 2
  }.freeze

  Message = Struct.new(:at, :status, :data, keyword_init: true) do
    def channel
      (status & 0x0F) + 1
    end

    def kind
      case status & 0xF0
      when 0x80 then :note_off
      when 0x90 then (data[1]).zero? ? :note_off : :note_on
      when 0xA0 then :poly_pressure
      when 0xB0 then :control_change
      when 0xC0 then :program_change
      when 0xD0 then :channel_pressure
      when 0xE0 then :pitch_bend
      else :system
      end
    end

    def note_name
      n = data[0]
      return nil if n.nil?

      "#{NOTE_NAMES[n % 12]}#{(n / 12) - 1}"
    end

    def to_s
      hex = ([status] + data).map { |b| format("%02X", b) }.join(" ")
      case kind
      when :note_on
        format("%-9s ch%-2d %-4s vel=%-3d  [%s]", "note on", channel, note_name, data[1], hex)
      when :note_off
        format("%-9s ch%-2d %-4s          [%s]", "note off", channel, note_name, hex)
      when :control_change
        format("%-9s ch%-2d cc=%-3d val=%-3d  [%s]", "control", channel, data[0], data[1], hex)
      when :program_change
        format("%-9s ch%-2d prog=%-3d        [%s]", "program", channel, data[0], hex)
      else
        format("%-9s %s", kind.to_s, "[#{hex}]")
      end
    end
  end

  # Feed it bytes, get whole MIDI messages back. Running status is accepted
  # even though the firmware does not use it, because a monitor should not be
  # the reason a stream looks broken.
  class Parser
    def initialize
      @status = nil
      @data = []
      @wanted = 0
      @sysex = false
    end

    def feed(byte, at)
      out = nil
      if byte == 0xF0
        @sysex = true
        @data = [byte]
        return nil
      elsif @sysex
        @data << byte
        if byte == 0xF7
          @sysex = false
          out = Message.new(at: at, status: 0xF0, data: @data[1..-1])
          @data = []
        end
        return out
      end

      if byte >= 0xF8
        # Realtime bytes may appear anywhere and carry no data.
        return Message.new(at: at, status: byte, data: [])
      end

      if byte >= 0x80
        @status = byte
        @wanted = DATA_BYTES[byte & 0xF0] || 0
        @data = []
        return @wanted.zero? ? Message.new(at: at, status: byte, data: []) : nil
      end

      return nil if @status.nil?

      @data << byte
      if @data.size >= @wanted
        out = Message.new(at: at, status: @status, data: @data)
        @data = []
      end
      out
    end
  end

  # Optional: play what arrives on a General MIDI synthesizer. fluidsynth
  # takes commands on stdin, which avoids ALSA sequencer routing - that is
  # not available under WSL2, where /dev/snd has only a timer.
  class Fluidsynth
    # render_path writes the audio to a WAV instead of a sound card, which is
    # how the result can be checked without listening to it.
    def initialize(soundfont, audio_driver, render_path = nil)
      # No -i: in fluidsynth that is --no-shell, which switches off the very
      # command reader this bridge writes to. Without the shell the notes go
      # nowhere and the result is silence with no error anywhere.
      command = ["fluidsynth", "-a", render_path ? "file" : audio_driver, "-q"]
      command += ["-F", render_path] if render_path
      command << soundfont if soundfont
      @io = IO.popen(command, "w")
      @sounding = {}
    rescue Errno::ENOENT
      warn "fmrb_midi_monitor: fluidsynth not found; install it to hear the output"
      @io = nil
    end

    def running?
      !@io.nil?
    end

    def play(message)
      return unless @io

      channel = message.status & 0x0F
      case message.kind
      when :note_on
        @io.puts "noteon #{channel} #{message.data[0]} #{message.data[1]}"
      when :note_off
        @io.puts "noteoff #{channel} #{message.data[0]}"
      when :program_change
        @io.puts "prog #{channel} #{message.data[0]}"
      when :control_change
        @io.puts "cc #{channel} #{message.data[0]} #{message.data[1]}"
      end
      @io.flush
    rescue Errno::EPIPE
      @io = nil
    end

    def close
      return unless @io

      @io.puts "quit"
      @io.close
    rescue StandardError
      nil
    end
  end

  module_function

  def ensure_fifo(path)
    return true if File.exist?(path) && File.stat(path).pipe?

    if File.exist?(path)
      warn "fmrb_midi_monitor: #{path} exists and is not a FIFO"
      return false
    end

    # Readable and writable by anyone: the firmware may run in a container
    # under a different user than whoever creates the FIFO.
    system("mkfifo", "-m", "666", path) or return false
    puts "created FIFO #{path}"
    true
  end

  def run(argv)
    # A monitor is meant to be watched live, including when its output is
    # piped to a file.
    $stdout.sync = true
    options = {
      fifo: DEFAULT_FIFO, hex: false, log: nil, duration: nil,
      fluidsynth: false, soundfont: nil, audio: "pulseaudio", quiet: false, render: nil
    }
    OptionParser.new do |o|
      o.banner = "Usage: fmrb_midi_monitor.rb [options]"
      o.on("--fifo PATH", "FIFO to read (default #{DEFAULT_FIFO})") { |v| options[:fifo] = v }
      o.on("--hex", "also print raw bytes with arrival times") { options[:hex] = true }
      o.on("--log PATH", "append one JSON object per message") { |v| options[:log] = v }
      o.on("--duration SEC", Float, "stop after SEC seconds of silence") { |v| options[:duration] = v }
      o.on("--fluidsynth", "play through fluidsynth (needs it installed)") { options[:fluidsynth] = true }
      o.on("--soundfont PATH", "SoundFont for fluidsynth") { |v| options[:soundfont] = v }
      o.on("--audio DRIVER", "fluidsynth audio driver (default pulseaudio)") { |v| options[:audio] = v }
      o.on("--render PATH", "render fluidsynth output to a WAV instead of playing") do |v|
        options[:render] = v
      end
      o.on("-q", "--quiet", "no per-message output") { options[:quiet] = true }
      o.on("-h", "--help") do
        puts o
        puts
        puts "To hear the output:"
        puts "  sudo apt install fluidsynth fluid-soundfont-gm"
        puts "  ruby tools/fmrb_midi_monitor.rb --fluidsynth"
        return 0
      end
    end.parse!(argv)

    return 1 unless ensure_fifo(options[:fifo])

    synth = if options[:fluidsynth] || options[:render]
              Fluidsynth.new(options[:soundfont], options[:audio], options[:render])
            end
    log = options[:log] ? File.open(options[:log], "a") : nil
    parser = Parser.new
    started = nil
    count = 0
    bytes = 0

    puts "reading #{options[:fifo]} (Ctrl+C to stop)" unless options[:quiet]

    # Opening read-write keeps the reader from seeing EOF every time the
    # firmware closes its end, and never blocks waiting for a writer.
    File.open(options[:fifo], File::RDWR | File::NONBLOCK) do |fifo|
      last_data = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      loop do
        ready = IO.select([fifo], nil, nil, 0.05)
        now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        if ready.nil?
          if options[:duration] && (now - last_data) > options[:duration] && count > 0
            break
          end

          next
        end

        chunk = begin
          fifo.read_nonblock(4096)
        rescue IO::WaitReadable, EOFError
          next
        end
        next if chunk.nil? || chunk.empty?

        last_data = now
        started ||= now
        chunk.each_byte do |byte|
          bytes += 1
          at = now - started
          printf("  %8.3f  %02X\n", at, byte) if options[:hex]
          message = parser.feed(byte, at)
          next if message.nil?

          count += 1
          puts format("  %8.3f  %s", at, message) unless options[:quiet]
          synth&.play(message)
          if log
            log.puts({ at: at.round(4), status: message.status,
                       data: message.data, kind: message.kind.to_s }.to_s.gsub("=>", ":"))
            log.flush
          end
        end
      end
    end

    puts "#{count} messages, #{bytes} bytes"
    0
  rescue Interrupt
    puts
    puts "#{count} messages, #{bytes} bytes"
    0
  ensure
    synth&.close
    log&.close
  end
end

exit(FmrbMidiMonitor.run(ARGV)) if $PROGRAM_NAME == __FILE__
