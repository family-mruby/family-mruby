# frozen_string_literal: true

module FmAssetEditor
  module Ui
    # The colour (or index) picker. Lays the format's swatches out in a grid and
    # maps clicks back to a value.
    class PaletteView
      SWATCH = 17
      MAX_COLUMNS = 16
      CHECKER = [[0x5A, 0x5A, 0x5A], [0x46, 0x46, 0x46]].freeze
      BACKDROP = [0x30, 0x30, 0x30].freeze
      SELECTED = [0xFF, 0xFF, 0x00].freeze
      SEPARATOR = [0x20, 0x20, 0x20].freeze

      attr_reader :document, :selected

      def initialize(document)
        @document = document
        reload
      end

      def document=(document)
        @document = document
        reload
      end

      def reload
        @swatches = @document.format.swatches(@document)
        @columns = [@swatches.size, MAX_COLUMNS].min
        @selected = @document.format.default_value
        @selected = @swatches.first[0] unless @swatches.any? { |value, _, _| value == @selected }
      end

      def select(value)
        @selected = value
      end

      def columns
        @columns
      end

      def rows
        (@swatches.size + @columns - 1) / @columns
      end

      def width
        @columns * SWATCH
      end

      def height
        rows * SWATCH
      end

      def value_at(x, y)
        column = (x / SWATCH).floor
        row = (y / SWATCH).floor
        return nil if column.negative? || row.negative? || column >= @columns

        index = row * @columns + column
        return nil if index >= @swatches.size

        @swatches[index][0]
      end

      def label_for(value)
        entry = @swatches.find { |swatch_value, _, _| swatch_value == value }
        entry ? entry[2] : value.to_s
      end

      def draw(context)
        Draw.fill_rect(context, 0, 0, width, height, BACKDROP)

        checker = [[], []]
        fills = Hash.new { |hash, key| hash[key] = [] }
        @swatches.each_with_index do |(_value, rgb, _label), index|
          x = (index % @columns) * SWATCH
          y = (index / @columns) * SWATCH
          if rgb.nil?
            # Transparent: half light, half dark, the same cue as the canvas.
            checker[0] << [x, y, SWATCH - 1, (SWATCH - 1) / 2]
            checker[1] << [x, y + (SWATCH - 1) / 2, SWATCH - 1, (SWATCH - 1) / 2]
          else
            fills[rgb] << [x, y, SWATCH - 1, SWATCH - 1]
          end
        end
        Draw.fill_rects(context, checker[0], CHECKER[0])
        Draw.fill_rects(context, checker[1], CHECKER[1])
        fills.each { |rgb, rects| Draw.fill_rects(context, rects, rgb) }

        index = @swatches.index { |value, _, _| value == @selected }
        return if index.nil?

        x = (index % @columns) * SWATCH
        y = (index / @columns) * SWATCH
        Draw.outline(context, x - 1, y - 1, SWATCH + 1, SWATCH + 1, SELECTED, 2)
      end
    end
  end
end
