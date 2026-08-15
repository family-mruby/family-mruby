# frozen_string_literal: true

module FmAssetEditor
  module Ui
    # The colour (or index) picker.
    #
    # The whole palette is always visible: the layout is recomputed from the
    # space the area actually got, picking the column count that makes the
    # swatches largest, so all 256 RGB332 colours fit without scrolling.
    class PaletteView
      COLUMN_CHOICES = [4, 8, 16, 32, 64].freeze
      MAX_SWATCH = 48
      MIN_SWATCH = 4
      GAP = 1
      CHECKER = [[0x5A, 0x5A, 0x5A], [0x46, 0x46, 0x46]].freeze
      BACKDROP = [0x30, 0x30, 0x30].freeze
      SELECTED = [0xFF, 0xFF, 0x00].freeze

      attr_reader :document, :selected

      Layout = Struct.new(:cell_width, :cell_height, :columns, :rows, :left, :top)

      def initialize(document)
        @document = document
        @layout = Layout.new(0, 0, 1, 1, 0, 0)
        reload
      end

      def document=(document)
        @document = document
        reload
      end

      def reload
        @swatches = @document.format.swatches(@document)
        @selected = @document.format.default_value
        @selected = @swatches.first[0] unless @swatches.any? { |value, _, _| value == @selected }
      end

      def select(value)
        @selected = value
      end

      def size
        @swatches.size
      end

      def value_at(x, y)
        return nil if @layout.cell_width < MIN_SWATCH || @layout.cell_height < MIN_SWATCH

        column = ((x - @layout.left) / @layout.cell_width).floor
        row = ((y - @layout.top) / @layout.cell_height).floor
        return nil if column.negative? || row.negative?
        return nil if column >= @layout.columns || row >= @layout.rows

        index = row * @layout.columns + column
        index < @swatches.size ? @swatches[index][0] : nil
      end

      def label_for(value)
        entry = @swatches.find { |swatch_value, _, _| swatch_value == value }
        entry ? entry[2] : value.to_s
      end

      def draw(context, area_width, area_height)
        @layout = fit(area_width, area_height)
        cell_width = @layout.cell_width
        cell_height = @layout.cell_height
        columns = @layout.columns
        return if cell_width < MIN_SWATCH || cell_height < MIN_SWATCH

        Draw.fill_rect(context, 0, 0, area_width, area_height, BACKDROP)

        checker = [[], []]
        fills = Hash.new { |hash, key| hash[key] = [] }
        @swatches.each_with_index do |(_value, rgb, _label), index|
          x = @layout.left + (index % columns) * cell_width
          y = @layout.top + (index / columns) * cell_height
          width = cell_width - GAP
          height = cell_height - GAP
          if rgb.nil?
            # Transparent: half light, half dark, the same cue as the canvas.
            checker[0] << [x, y, width, height / 2]
            checker[1] << [x, y + height / 2, width, height - height / 2]
          else
            fills[rgb] << [x, y, width, height]
          end
        end
        Draw.fill_rects(context, checker[0], CHECKER[0])
        Draw.fill_rects(context, checker[1], CHECKER[1])
        fills.each { |rgb, rects| Draw.fill_rects(context, rects, rgb) }

        index = @swatches.index { |value, _, _| value == @selected }
        return if index.nil?

        x = @layout.left + (index % columns) * cell_width
        y = @layout.top + (index / columns) * cell_height
        thickness = [cell_width, cell_height].min >= 12 ? 2 : 1
        Draw.outline(context, x - 1, y - 1, cell_width + 1, cell_height + 1, SELECTED, thickness)
      end

      private

      # Pick the column count that makes the swatches biggest, then let the cells
      # fill the area: the palette is never scrolled, so every entry has to fit
      # in the space the box gave us. Whatever is left over (a small palette, or
      # rounding) is split as a margin, so the block sits in the middle.
      def fit(width, height)
        return Layout.new(0, 0, 1, 1, 0, 0) if width < 1 || height < 1

        best = nil
        candidates = COLUMN_CHOICES.select { |columns| columns <= @swatches.size }
        candidates << @swatches.size if candidates.empty?
        candidates.uniq.each do |columns|
          rows = (@swatches.size + columns - 1) / columns
          cell_width = [(width / columns).floor, MAX_SWATCH].min
          cell_height = [(height / rows).floor, MAX_SWATCH].min
          score = [cell_width, cell_height].min
          next unless best.nil? || score > [best.cell_width, best.cell_height].min

          best = Layout.new(cell_width, cell_height, columns, rows,
                            (width - columns * cell_width) / 2,
                            (height - rows * cell_height) / 2)
        end
        best
      end
    end
  end
end
