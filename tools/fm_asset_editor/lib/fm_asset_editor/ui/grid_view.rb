# frozen_string_literal: true

module FmAssetEditor
  module Ui
    # Draws a Document as a zoomed pixel grid and maps window coordinates back
    # to pixels. It owns no control: the window hands it a drawing context.
    class GridView
      CHECKER = [[0x5A, 0x5A, 0x5A], [0x46, 0x46, 0x46]].freeze
      GRID_LINE = [0x28, 0x28, 0x28].freeze
      CELL_LINE = [0xFF, 0x99, 0x22].freeze
      CURSOR = [0xFF, 0xFF, 0x00].freeze
      BACKDROP = [0x30, 0x30, 0x30].freeze
      MIN_ZOOM = 1
      MAX_ZOOM = 32
      GRID_MIN_ZOOM = 4 # below this the lines would eat the artwork

      attr_reader :document, :zoom
      attr_accessor :show_grid, :cell_override, :cursor

      def initialize(document, zoom: 8)
        @document = document
        @zoom = zoom
        @show_grid = true
        @cell_override = nil
        @cursor = nil
      end

      def document=(document)
        @document = document
        @cursor = nil
      end

      def zoom=(value)
        @zoom = value.clamp(MIN_ZOOM, MAX_ZOOM)
      end

      def width
        @document.width * @zoom
      end

      def height
        @document.height * @zoom
      end

      def cell
        @cell_override || @document.format.cell
      end

      # Window coordinates -> [x, y] in the document, or nil when outside.
      def pixel_at(x, y)
        px = (x / @zoom).floor
        py = (y / @zoom).floor
        @document.inside?(px, py) ? [px, py] : nil
      end

      def draw(context, clip)
        format = @document.format
        x0, y0, x1, y1 = visible_range(clip)
        return if x1 < x0 || y1 < y0

        Draw.fill_rect(context, x0 * @zoom, y0 * @zoom,
                       (x1 - x0 + 1) * @zoom, (y1 - y0 + 1) * @zoom, BACKDROP)

        runs = Hash.new { |hash, key| hash[key] = [] }
        checker = [[], []]
        (y0..y1).each do |y|
          x = x0
          while x <= x1
            value = @document.get(x, y)
            length = 1
            length += 1 while x + length <= x1 && @document.get(x + length, y) == value
            if format.color(@document, value).nil?
              # Transparent: a checkerboard so it cannot be mistaken for black.
              length.times do |i|
                checker[(x + i + y).even? ? 0 : 1] << [(x + i) * @zoom, y * @zoom, @zoom, @zoom]
              end
            else
              runs[value] << [x * @zoom, y * @zoom, length * @zoom, @zoom]
            end
            x += length
          end
        end

        Draw.fill_rects(context, checker[0], CHECKER[0])
        Draw.fill_rects(context, checker[1], CHECKER[1])
        runs.each { |value, rects| Draw.fill_rects(context, rects, format.color(@document, value)) }

        draw_lines(context, x0, y0, x1, y1)
        draw_cursor(context)
      end

      private

      def visible_range(clip)
        x0 = ((clip[:clip_x] || 0) / @zoom).floor
        y0 = ((clip[:clip_y] || 0) / @zoom).floor
        x1 = (((clip[:clip_x] || 0) + (clip[:clip_width] || width)) / @zoom).ceil
        y1 = (((clip[:clip_y] || 0) + (clip[:clip_height] || height)) / @zoom).ceil
        [x0.clamp(0, @document.width - 1), y0.clamp(0, @document.height - 1),
         x1.clamp(0, @document.width - 1), y1.clamp(0, @document.height - 1)]
      end

      def draw_lines(context, x0, y0, x1, y1)
        step = cell
        pixel_lines = @show_grid && @zoom >= GRID_MIN_ZOOM

        if pixel_lines
          rects = []
          (x0..x1 + 1).each { |x| rects << [x * @zoom, y0 * @zoom, 1, (y1 - y0 + 1) * @zoom] }
          (y0..y1 + 1).each { |y| rects << [x0 * @zoom, y * @zoom, (x1 - x0 + 1) * @zoom, 1] }
          Draw.fill_rects(context, rects, GRID_LINE)
        end

        return if step.nil? || step < 2

        rects = []
        ((x0 / step) * step).step(x1 + step, step) { |x| rects << [x * @zoom, y0 * @zoom, 1, (y1 - y0 + 1) * @zoom] }
        ((y0 / step) * step).step(y1 + step, step) { |y| rects << [x0 * @zoom, y * @zoom, (x1 - x0 + 1) * @zoom, 1] }
        Draw.fill_rects(context, rects, CELL_LINE)
      end

      def draw_cursor(context)
        return if @cursor.nil? || @zoom < 3

        x, y = @cursor
        return unless @document.inside?(x, y)

        Draw.outline(context, x * @zoom, y * @zoom, @zoom, @zoom, CURSOR, @zoom >= 8 ? 2 : 1)
      end
    end
  end
end
