# frozen_string_literal: true

module FmAssetEditor
  module Formats
    # The FMRuby BASIC character sheets: flash/usr/share/basic/font_b.bmp (text
    # glyphs) and tile_a.bmp (graphic characters).
    #
    # 128x128 holding 16x16 cells of 8x8 pixels; the character code is
    # row * 16 + column. The pixel byte is a palette index, not a colour:
    # 0 is off, 1 is the ink the renderer draws today, 2 and 3 are reserved for
    # the colour attributes. Colours below match fmruby-core/tool/basic/
    # basic_sheet.rb so the sheets keep opening the same way in other editors.
    module BasicSheet
      LABEL = 'BASIC character sheet (128x128, 16x16 cells of 8x8)'
      EXTENSIONS = ['.bmp'].freeze
      DIM = 128
      CELL = 8
      COLS = DIM / CELL
      COLOR_COUNT = 4
      PALETTE = [
        [0x00, 0x00, 0x00], # 0: off
        [0xFF, 0xFF, 0xFF], # 1: on
        [0xE0, 0x40, 0x40], # 2: reserved (colour attribute 2)
        [0x40, 0xC0, 0xE0]  # 3: reserved (colour attribute 3)
      ].freeze
      # Values are the 2bpp colour attribute, not a colour. The shipped sheets
      # are drawn with 3 because the built-in 1bpp artwork is promoted to index 3
      # when the firmware falls back to it (components/basic/assets/
      # basic_assets.c), so 3 is what new artwork should use to match.
      VALUE_NAMES = ['0 off', '1 attribute 1', '2 attribute 2', '3 ink'].freeze
      INK = 3

      module_function

      def label
        LABEL
      end

      def extensions
        EXTENSIONS
      end

      def view
        :grid
      end

      def cell
        CELL
      end

      def default_value
        INK
      end

      def erase_value
        0
      end

      # biClrUsed is what separates the two BMP flavours: the sheet writer
      # declares 4 colours, the sprite writer declares 256.
      def detect?(path)
        return false unless File.extname(path).downcase == '.bmp'

        image = Bmp.read(path)
        image.width == DIM && image.height == DIM && image.color_count == COLOR_COUNT
      rescue Bmp::Error, SystemCallError
        false
      end

      def load(path)
        image = Bmp.read(path)
        # The firmware clamps anything above 3 to the ink index; do the same so
        # what is on screen is what the machine will draw.
        pixels = image.pixels.map { |value| value > 3 ? 3 : value }
        Document.new(format: self, path: path, width: image.width, height: image.height,
                     pixels: pixels)
      end

      def blank
        Document.new(format: self, path: nil, width: DIM, height: DIM,
                     pixels: Array.new(DIM * DIM, 0))
      end

      def write(document, path)
        Bmp.write(path, Bmp::Image.new(width: document.width, height: document.height,
                                       pixels: document.pixels, palette: PALETTE,
                                       color_count: COLOR_COUNT))
      end

      def swatches(_document)
        (0..3).map { |value| [value, PALETTE[value], VALUE_NAMES[value]] }
      end

      # Index 0 is a real background here, not transparency, so it is drawn.
      def color(_document, value)
        PALETTE[value] || PALETTE[3]
      end

      def value_label(value)
        VALUE_NAMES[value] || value.to_s
      end

      # Character code of the cell holding a pixel, for the status line.
      def code_at(x, y)
        (y / CELL) * COLS + (x / CELL)
      end
    end
  end
end
