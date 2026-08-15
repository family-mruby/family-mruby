# frozen_string_literal: true

module FmAssetEditor
  module Mml
    # A .mml file: settings lines, then one part per line.
    #
    #   # a comment, at the start of a line only ('#' is a sharp inside a part)
    #   bpm 120          the tempo, because the dialect has no tempo command
    #   loop on          repeat when the end is reached (default off)
    #   velocity 80      applies to the parts below it (default 100)
    #   voice triangle   which APU voice plays the part (pulse1/2, triangle, noise)
    #   duty 1           pulse width 0-3 (12.5, 25, 50, 75 per cent)
    #   volume 100       channel volume 0-127 (CC 7)
    #   program 24       instrument for an external MIDI sound source (GM)
    #   o5 l4 cegegegc   a part; the next one goes on the next line
    #
    # The four sound settings are per part, since the dialect itself has no way
    # to say them: a program written as MML picks notes, and what plays them is
    # a property of the channel. They apply to the parts below them, like
    # velocity. Left out, the machine's own defaults stand (channel 0 on
    # pulse1, 1 on pulse2, 2 on the triangle, 9 on noise).
    #
    # Parts are numbered in order and each plays on its own MIDI channel, which
    # is how FmrbMidi::MmlPlayer wants them (load_string then add_string).
    #
    # The text is the file: this class reads it and answers questions about it,
    # but never rewrites what it did not have to.
    class Tune
      DEFAULT_BPM = 120
      DEFAULT_VELOCITY = 100
      DEFAULT_DUTY = 2 # 50 per cent, what the transport starts with
      BPM_RANGE = (1..1000).freeze
      VELOCITY_RANGE = (1..127).freeze
      DUTY_RANGE = (0..3).freeze
      PROGRAM_RANGE = (0..127).freeze
      VOLUME_RANGE = (0..127).freeze
      VOICES = %w[pulse1 pulse2 triangle noise].freeze
      SETTINGS = %w[bpm loop velocity voice duty volume program].freeze

      # Everything MIDI::MML::Sequence acts on. Anything else in a part is
      # dropped by the parser without a word, which is worth pointing out.
      DIALECT = "cdefgabrolv<>[]&+-#.0123456789 \t"

      Part = Struct.new(:mml, :channel, :velocity, :voice, :duty, :volume, :program, :line,
                        keyword_init: true) do
        # What the part sounds like, for the pane and for the preview.
        def summary
          words = []
          words << (voice || 'auto')
          words << "duty#{duty}" if duty
          words << "vol#{volume}" if volume
          words << "gm#{program}" if program
          words << "vel#{velocity}"
          words.join(' ')
        end
      end
      Problem = Struct.new(:line, :message, keyword_init: true)

      attr_reader :bpm, :loop, :parts, :problems

      def initialize(text)
        @text = text.to_s
        parse
      end

      def loop?
        @loop
      end

      def part_count
        @parts.size
      end

      # Events of every part, merged and sorted, as the player merges them.
      # nil when the parser is not available.
      def events
        return @events if defined?(@events)

        @events = collect_events
      end

      # The length of the longest part, which is what the player uses. It is
      # not the last event: a tune ending in a rest goes on after its last
      # note off.
      def total_clocks
        events # fills in @length while collecting
        @length || 0
      end

      def note_count
        events&.count { |event| event[:type] == :note_on } || 0
      end

      def seconds
        total_clocks * 60.0 / @bpm / Engine::CLOCKS_PER_QUARTER
      end

      # Replace (or add) a setting line, leaving the rest of the file alone.
      def self.with_setting(text, key, value)
        lines = text.to_s.split("\n", -1)
        index = lines.index { |line| line.strip.split(/\s+/, 2).first&.downcase == key }
        if index
          lines[index] = "#{key} #{value}"
        else
          # Above the first part, so the file still reads top to bottom.
          insert_at = lines.index { |line| part_line?(line) } || lines.size
          lines.insert(insert_at, "#{key} #{value}")
        end
        lines.join("\n")
      end

      def self.part_line?(line)
        stripped = line.to_s.strip
        return false if stripped.empty? || stripped.start_with?('#')

        !SETTINGS.include?(stripped.split(/\s+/, 2).first.to_s.downcase)
      end

      private

      def parse
        @bpm = DEFAULT_BPM
        @loop = false
        @parts = []
        @problems = []
        sound = { velocity: DEFAULT_VELOCITY, voice: nil, duty: nil, volume: nil, program: nil }

        @text.split("\n").each_with_index do |raw, index|
          line = index + 1
          stripped = raw.strip
          next if stripped.empty? || stripped.start_with?('#')

          key, argument = stripped.split(/\s+/, 2)
          case key.downcase
          when 'bpm'
            @bpm = integer(argument, BPM_RANGE, DEFAULT_BPM, 'bpm', line)
          when 'loop'
            @loop = boolean(argument, line)
          when 'velocity'
            sound[:velocity] = integer(argument, VELOCITY_RANGE, DEFAULT_VELOCITY, 'velocity', line)
          when 'voice'
            sound[:voice] = voice(argument, line)
          when 'duty'
            sound[:duty] = integer(argument, DUTY_RANGE, DEFAULT_DUTY, 'duty', line)
          when 'volume'
            sound[:volume] = integer(argument, VOLUME_RANGE, 127, 'volume', line)
          when 'program'
            sound[:program] = integer(argument, PROGRAM_RANGE, 0, 'program', line)
          else
            @parts << Part.new(mml: stripped, channel: @parts.size, line: line, **sound)
            report_stray_characters(stripped, line)
          end
        end

        @problems << Problem.new(line: nil, message: 'no parts: the file holds no MML') if @parts.empty?
      end

      def integer(argument, range, fallback, key, line)
        value = argument.to_s.strip
        unless /\A\d+\z/.match?(value)
          @problems << Problem.new(line: line, message: "#{key} wants a number, got #{value.inspect}")
          return fallback
        end

        number = value.to_i
        return number if range.cover?(number)

        @problems << Problem.new(line: line, message: "#{key} #{number} is outside #{range.first}..#{range.last}")
        number.clamp(range.first, range.last)
      end

      def voice(argument, line)
        name = argument.to_s.strip.downcase
        return name if VOICES.include?(name)

        # The numbers the transport uses are allowed too, since that is what
        # map_channel takes.
        return VOICES[name.to_i] if /\A[0-3]\z/.match?(name)

        @problems << Problem.new(line: line,
                                 message: "voice wants one of #{VOICES.join(' ')}, got #{name.inspect}")
        nil
      end

      def boolean(argument, line)
        case argument.to_s.strip.downcase
        when 'on', 'yes', 'true', '1' then true
        when 'off', 'no', 'false', '0', '' then false
        else
          @problems << Problem.new(line: line, message: "loop wants on or off, got #{argument.strip.inspect}")
          false
        end
      end

      # The parser skips what it does not know instead of complaining, so a
      # typo comes out as silence rather than as an error. Say so here.
      def report_stray_characters(part, line)
        stray = part.each_char.each_with_index.reject { |char, _| DIALECT.include?(char) }
        return if stray.empty?

        columns = stray.map { |_, index| index + 1 }
        listed = stray.map { |char, _| char }.uniq.join(' ')
        @problems << Problem.new(line: line,
                                 message: "the parser ignores #{listed} (column #{columns.join(', ')})")
      end

      def collect_events
        return nil unless Engine.available?

        merged = []
        @length = 0
        @parts.each do |part|
          events, length = Engine.parse(part.mml, channel: part.channel, velocity: part.velocity)
          next if events.nil?

          @length = length if length > @length
          events.each { |event| merged << event.merge(part: part.channel) }
        end
        merged.sort_by { |event| [event[:clock], event[:type] == :note_on ? 1 : 0] }
      end
    end
  end
end
