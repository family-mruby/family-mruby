# frozen_string_literal: true

module FmAssetEditor
  module Formats
    # Sprites, icons and tile sheets: flash/usr/share/sprites, usr/share/icon,
    # app/game/**/*.bmp and the launcher artwork in graphics-audio.
    #
    # The pixel byte is the RGB332 colour itself. The file palette is written
    # only so ordinary viewers show the right colours; the firmware loader
    # ignores it. Value 0 is transparent (SpriteImage transparent_color: 0).
    module Sprite332
      LABEL = 'Sprite / icon (pixel = RGB332)'
      EXTENSIONS = ['.bmp'].freeze
      TRANSPARENT = 0
      DEFAULT_VALUE = 0xFF

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
        nil
      end

      def default_value
        DEFAULT_VALUE
      end

      # What the right mouse button paints.
      def erase_value
        TRANSPARENT
      end

      # Anything the BMP reader accepts that is not a BASIC sheet. Kept last in
      # the registry so it acts as the fallback for 8bpp artwork.
      def detect?(path)
        return false unless File.extname(path).downcase == '.bmp'

        image = Bmp.read(path)
        image.width <= Bmp::MAX_SIDE && image.height <= Bmp::MAX_SIDE
      rescue Bmp::Error, SystemCallError
        false
      end

      def load(path)
        image = Bmp.read(path)
        if image.width > Bmp::MAX_SIDE || image.height > Bmp::MAX_SIDE
          raise Bmp::Error, "#{File.basename(path)}: #{image.width}x#{image.height} is over the #{Bmp::MAX_SIDE}px the loader accepts"
        end

        # The stored palette is decoration -- the loader reads the pixel byte as
        # the colour -- so it is carried through untouched. Some of the existing
        # artwork expands RGB332 with rounding rather than truncation, and
        # rewriting it would put 156 bytes of noise in every diff. Normalise
        # explicitly (normalise_palette) to get the canonical table.
        Document.new(format: self, path: path, width: image.width, height: image.height,
                     pixels: image.pixels,
                     meta: { palette: image.palette, color_count: image.color_count })
      end

      def blank(width = 16, height = 16)
        Document.new(format: self, path: nil, width: width, height: height,
                     pixels: Array.new(width * height, TRANSPARENT))
      end

      def write(document, path)
        palette = document.meta[:palette]
        if palette&.size == Bmp::PALETTE_ENTRIES
          color_count = document.meta[:color_count] || Bmp::PALETTE_ENTRIES
        else
          palette = Rgb332::PALETTE
          color_count = Bmp::PALETTE_ENTRIES
        end

        Bmp.write(path, Bmp::Image.new(width: document.width, height: document.height,
                                       pixels: document.pixels, palette: palette,
                                       color_count: color_count))
      end

      # Drop the stored palette so the next save writes the canonical RGB332
      # table, i.e. so the file looks in other viewers the way it looks on the
      # machine.
      def normalise_palette(document)
        return false unless document.meta.key?(:palette)

        document.meta.delete(:palette)
        document.meta.delete(:color_count)
        document.touch_meta
        true
      end

      def swatches(_document)
        (0..255).map { |value| [value, color(nil, value), value_label(value)] }
      end

      def color(_document, value)
        value == TRANSPARENT ? nil : Rgb332::PALETTE[value & 0xFF]
      end

      def value_label(value)
        value == TRANSPARENT ? '0x00 (transparent)' : Rgb332.label(value)
      end

      # Answering these three is what tells the window this format can be
      # picked by numbers as well as from the palette.
      def levels(value)
        Rgb332.levels(value)
      end

      def from_levels(red, green, blue)
        Rgb332.from_levels(red, green, blue)
      end

      def parse_color(text)
        Rgb332.parse(text)
      end

      # True when the file carries a palette that disagrees with RGB332, i.e. it
      # looks different in an image viewer than it will on the machine.
      def palette_mismatch?(document)
        palette = document.meta[:palette]
        return false unless palette&.size == Bmp::PALETTE_ENTRIES

        palette.each_with_index.any? { |entry, index| entry != Rgb332::PALETTE[index] }
      end
    end
  end
end
