# frozen_string_literal: true

module FmAssetEditor
  module Ui
    # The tune drawn as a piano roll: time to the right, pitch upwards, one
    # colour per part. It is the quickest way to see that a part comes in where
    # it should and that two parts land together.
    #
    # A keyboard down the left says which pitch a row is, and the rows of the
    # black keys are shaded across the whole roll, so a note can be read off
    # without counting lines. While a tune plays, the head shows where it is
    # and a click anywhere moves it.
    class MmlRoll
      BACKDROP = [0x24, 0x24, 0x28].freeze
      BLACK_ROW = [0x1E, 0x1E, 0x22].freeze
      BAR_LINE = [0x3A, 0x3A, 0x42].freeze
      BEAT_LINE = [0x2E, 0x2E, 0x36].freeze
      OCTAVE_LINE = [0x3C, 0x3C, 0x48].freeze
      GUTTER_BG = [0x18, 0x18, 0x1C].freeze
      WHITE_KEY = [0xD8, 0xD8, 0xE0].freeze
      BLACK_KEY = [0x30, 0x30, 0x38].freeze
      KEY_EDGE = [0x18, 0x18, 0x1C].freeze
      LABEL = [0x20, 0x20, 0x28].freeze
      HEAD = [0xFF, 0x60, 0x60].freeze
      # One per part, in order; parts beyond these repeat the list.
      PART_COLORS = [
        [0x4C, 0xC0, 0xFF], [0xFF, 0xC0, 0x4C], [0x8C, 0xE8, 0x6C],
        [0xFF, 0x8C, 0xB4], [0xC0, 0x9C, 0xFF]
      ].freeze
      NOTE_NAMES = %w[C C# D D# E F F# G G# A A# B].freeze
      BLACK_KEYS = [1, 3, 6, 8, 10].freeze
      GUTTER = 34 # the keyboard
      MIN_ROWS = 12 # never zoom a single note to fill the height
      LABEL_ROW_HEIGHT = 9 # below this a note name will not fit

      attr_accessor :tune
      attr_reader :position

      def initialize(tune = nil)
        @tune = tune
        @position = nil # seconds into the tune, or nil when not playing
      end

      def position=(seconds)
        @position = seconds
      end

      # Window x -> seconds into the tune, for seeking. nil in the keyboard.
      def seconds_at(x, width)
        return nil if @tune.nil? || x < GUTTER || width <= GUTTER

        span = (width - GUTTER).to_f
        seconds = (x - GUTTER) / span * @tune.seconds
        seconds.clamp(0.0, @tune.seconds)
      end

      def draw(context, width, height)
        Draw.fill_rect(context, 0, 0, width, height, BACKDROP)
        events = @tune&.events
        return if events.nil? || events.empty? || width <= GUTTER + 8 || height < 8

        notes = events.select { |event| event[:type] == :note_on }
        return if notes.empty?

        low, high = pitch_range(notes)
        rows = high - low + 1
        row_height = height.to_f / rows
        clocks = [@tune.total_clocks, 1].max
        scale = (width - GUTTER).to_f / clocks

        draw_rows(context, width, low, high, row_height)
        draw_time_lines(context, width, height, clocks, scale)
        draw_notes(context, notes, high, row_height, scale)
        draw_keyboard(context, low, high, row_height)
        draw_head(context, width, height)
      end

      private

      # Pad a narrow tune out to a readable band rather than stretching a
      # couple of notes over the whole pane.
      def pitch_range(notes)
        low = notes.map { |event| event[:note] }.min
        high = notes.map { |event| event[:note] }.max
        while high - low + 1 < MIN_ROWS
          low -= 1
          high += 1
        end
        [low.clamp(0, 127), high.clamp(0, 127)]
      end

      def row_top(note, high, row_height)
        (high - note) * row_height
      end

      # The black keys shaded right across, so a row can be placed at a glance.
      def draw_rows(context, width, low, high, row_height)
        shaded = []
        octaves = []
        (low..high).each do |note|
          top = row_top(note, high, row_height)
          shaded << [GUTTER, top, width - GUTTER, row_height] if BLACK_KEYS.include?(note % 12)
          octaves << [GUTTER, top, width - GUTTER, 1] if (note % 12).zero?
        end
        Draw.fill_rects(context, shaded, BLACK_ROW)
        Draw.fill_rects(context, octaves, OCTAVE_LINE)
      end

      def draw_time_lines(context, width, height, clocks, scale)
        quarter = Mml::Engine::CLOCKS_PER_QUARTER
        beats = []
        bars = []
        (0..(clocks / quarter)).each do |beat|
          x = GUTTER + beat * quarter * scale
          next if x > width

          (beat % 4).zero? ? bars << [x, 0, 1, height] : beats << [x, 0, 1, height]
        end
        Draw.fill_rects(context, beats, BEAT_LINE)
        Draw.fill_rects(context, bars, BAR_LINE)
      end

      def draw_notes(context, notes, high, row_height, scale)
        bars = Hash.new { |hash, key| hash[key] = [] }
        notes.each do |event|
          length = event[:duration_clocks] || 0
          next if length <= 0

          bars[event[:part] || event[:channel] || 0] <<
            [GUTTER + event[:clock] * scale, row_top(event[:note], high, row_height),
             [length * scale - 1, 1].max, [row_height - 1, 1].max]
        end
        bars.each { |part, rects| Draw.fill_rects(context, rects, PART_COLORS[part % PART_COLORS.size]) }
      end

      def draw_keyboard(context, low, high, row_height)
        height = (high - low + 1) * row_height
        Draw.fill_rect(context, 0, 0, GUTTER, height, GUTTER_BG)

        whites = []
        blacks = []
        edges = []
        (low..high).each do |note|
          top = row_top(note, high, row_height)
          key = [0, top, GUTTER - 2, [row_height - 1, 1].max]
          BLACK_KEYS.include?(note % 12) ? blacks << key : whites << key
          edges << [0, top, GUTTER - 2, 1] if [0, 5].include?(note % 12) # under E and B
        end
        Draw.fill_rects(context, whites, WHITE_KEY)
        Draw.fill_rects(context, blacks, BLACK_KEY)
        Draw.fill_rects(context, edges, KEY_EDGE)

        return if row_height < LABEL_ROW_HEIGHT

        # Name the Cs, and every white key too when there is room for it.
        every_key = row_height >= 14
        (low..high).each do |note|
          next if BLACK_KEYS.include?(note % 12)
          next unless (note % 12).zero? || every_key

          Draw.text(context, 2, row_top(note, high, row_height) + (row_height - 10) / 2,
                    name_of(note), LABEL, size: 8.0)
        end
      end

      def name_of(note)
        "#{NOTE_NAMES[note % 12]}#{(note / 12) - 1}"
      end

      def draw_head(context, width, height)
        return if @position.nil? || @tune.nil? || @tune.seconds <= 0

        x = GUTTER + (@position / @tune.seconds) * (width - GUTTER)
        return if x < GUTTER || x > width

        Draw.fill_rect(context, x, 0, 2, height, HEAD)
      end
    end
  end
end
