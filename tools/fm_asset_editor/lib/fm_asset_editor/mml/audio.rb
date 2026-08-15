# frozen_string_literal: true

require 'tmpdir'

module FmAssetEditor
  module Mml
    # Turning a tune into something audible on the desktop.
    #
    # The notes and their timing come from the machine's parser, so they are
    # exact. The sound is made here and is only a likeness of the APU: a part
    # on a pulse voice comes out as a square wave of the duty it asks for, the
    # triangle as a triangle and the noise as noise, which is enough to tell
    # the voices apart and to hear that a duty change did something. A part
    # with a GM program still sounds like a square wave -- what an external
    # instrument makes of program 24 is that instrument's business.
    module Audio
      RATE = 22_050
      AMPLITUDE = 5000
      FADE = 40 # samples, so a note neither clicks on nor off
      TAIL = 0.25 # seconds of silence after the last note
      # Pulse widths the APU has, in the order the duty setting numbers them.
      DUTY_WIDTHS = [0.125, 0.25, 0.5, 0.75].freeze
      NOISE_SEED = 0x2A5F # fixed, so the same tune renders the same bytes

      # In the order they are tried. paplay and aplay come with PulseAudio and
      # ALSA, play with sox, ffplay with ffmpeg.
      PLAYERS = [
        ['paplay', []],
        ['play', ['-q']],
        ['ffplay', ['-nodisp', '-autoexit', '-loglevel', 'quiet']],
        ['aplay', ['-q']]
      ].freeze

      module_function

      def player_command
        PLAYERS.each do |name, arguments|
          path = which(name)
          return [path, *arguments] if path
        end
        nil
      end

      def which(name)
        ENV['PATH'].to_s.split(File::PATH_SEPARATOR).each do |directory|
          candidate = File.join(directory, name)
          return candidate if File.executable?(candidate) && !File.directory?(candidate)
        end
        nil
      end

      # 16 bit mono WAV of the tune from `from` seconds on, or nil when it has
      # no notes. Starting part way through is done by rendering the whole
      # thing and cutting: it costs a few milliseconds and works whatever the
      # player is, where seeking would depend on which one was found.
      def render(tune, from: 0.0)
        events = tune.events
        return nil if events.nil? || events.empty?

        seconds_per_clock = 60.0 / tune.bpm / Engine::CLOCKS_PER_QUARTER
        length = ((tune.total_clocks * seconds_per_clock) + TAIL) * RATE
        samples = Array.new(length.ceil, 0)

        parts = tune.parts.each_with_object({}) { |part, index| index[part.channel] = part }
        events.each do |event|
          next unless event[:type] == :note_on

          clocks = event[:duration_clocks] || duration_of(events, event)
          next if clocks.nil? || clocks <= 0

          add_note(samples, frequency(event[:note]),
                   (event[:clock] * seconds_per_clock * RATE).to_i,
                   (clocks * seconds_per_clock * RATE).to_i,
                   event[:velocity] || 100,
                   parts[event[:part] || event[:channel]])
        end

        skip = (from.to_f * RATE).to_i
        samples = samples.drop(skip) if skip.positive?
        return nil if samples.empty?

        wav(samples)
      end

      def write(tune, path, from: 0.0)
        body = render(tune, from: from)
        return nil if body.nil?

        File.binwrite(path, body)
        path
      end

      def frequency(note)
        440.0 * (2**((note - 69) / 12.0))
      end

      def duration_of(events, note_on)
        off = events.find do |event|
          event[:type] == :note_off && event[:note] == note_on[:note] &&
            event[:channel] == note_on[:channel] && event[:clock] > note_on[:clock]
        end
        off && (off[:clock] - note_on[:clock])
      end

      def add_note(samples, frequency, start, length, velocity, part = nil)
        return if length <= 0

        period = RATE / frequency
        width = DUTY_WIDTHS[part&.duty || Tune::DEFAULT_DUTY]
        voice = part&.voice
        level = AMPLITUDE * (velocity.clamp(1, 127) / 100.0) * ((part&.volume || 127) / 127.0)
        noise = NOISE_SEED
        held = level

        length.times do |i|
          index = start + i
          break if index >= samples.size

          phase = (i % period) / period
          case voice
          when 'triangle'
            # Up for the first half, down for the second.
            value = (phase < 0.5 ? (phase * 4 - 1) : (3 - phase * 4)) * level
          when 'noise'
            # A new random level every half period: the pitch is heard as the
            # rate at which it changes, which is how the APU's noise works.
            if (i % (period / 2).ceil).zero?
              noise = (noise * 1_103_515_245 + 12_345) & 0x7FFF_FFFF
              held = noise.even? ? level : -level
            end
            value = held
          else
            value = phase < width ? level : -level
          end

          gain = [[i, length - i, FADE].min.to_f / FADE, 1.0].min
          samples[index] = (samples[index] + value * gain).clamp(-32_000, 32_000).to_i
        end
      end

      def wav(samples)
        body = samples.pack('s<*')
        header = 'RIFF'.b + [36 + body.bytesize].pack('V') + 'WAVEfmt '.b +
                 [16, 1, 1, RATE, RATE * 2, 2, 16].pack('VvvVVvv') +
                 'data'.b + [body.bytesize].pack('V')
        header + body
      end
    end

    # Plays a rendered tune in another process, so the window keeps answering
    # while a tune runs and stopping is a matter of ending it.
    #
    # Where it has got to is counted off the clock rather than asked of the
    # player, which none of them will say: the tune was handed over as a whole
    # and plays at its own speed, so the count is right to within the moment
    # the player takes to open the sound device.
    class Playback
      attr_reader :duration

      def initialize
        @pid = nil
        @file = nil
        @offset = 0.0
        @started_at = nil
        @duration = 0.0
      end

      def available?
        !Audio.player_command.nil?
      end

      def playing?
        return false if @pid.nil?

        running = Process.waitpid(@pid, Process::WNOHANG).nil?
        @pid = nil unless running
        running
      rescue Errno::ECHILD
        @pid = nil
        false
      end

      # Seconds into the tune, or nil when nothing is playing.
      def position
        return nil if @started_at.nil?

        elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - @started_at
        [@offset + elapsed, @duration].min
      end

      # Returns nil when it started, or a sentence saying why it could not.
      def start(tune, from: 0.0)
        stop
        command = Audio.player_command
        return 'no wav player found (install pulseaudio-utils, sox or ffmpeg)' if command.nil?

        @duration = tune.seconds + Audio::TAIL
        from = from.to_f.clamp(0.0, [tune.seconds - 0.05, 0.0].max)
        @file = File.join(Dir.tmpdir, "fm_asset_editor_#{Process.pid}.wav")
        return 'the tune has no notes to play' if Audio.write(tune, @file, from: from).nil?

        @offset = from
        @started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        @pid = Process.spawn(*command, @file, out: File::NULL, err: File::NULL)
        nil
      rescue StandardError => e
        e.message
      end

      def stop
        @started_at = nil
        return if @pid.nil?

        begin
          Process.kill('TERM', @pid)
          Process.waitpid(@pid)
        rescue Errno::ESRCH, Errno::ECHILD
          nil
        end
        @pid = nil
      end
    end
  end
end
