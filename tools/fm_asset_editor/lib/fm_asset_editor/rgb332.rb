# frozen_string_literal: true

module FmAssetEditor
  # RGB332: 3 bits red, 3 bits green, 2 bits blue in one byte.
  #
  # This is the colour the machine actually shows. Sprite and icon BMPs store
  # the value straight in the pixel byte -- the loader never looks at the file
  # palette -- so the editor always paints from this table rather than from
  # whatever palette happens to be in the file.
  module Rgb332
    module_function

    def to_rgb888(value)
      [((value >> 5) & 0x07) * 255 / 7,
       ((value >> 2) & 0x07) * 255 / 7,
       (value & 0x03) * 255 / 3]
    end

    def from_rgb888(red, green, blue)
      ((red * 7 / 255) << 5) | ((green * 7 / 255) << 2) | (blue * 3 / 255)
    end

    def label(value)
      format('0x%02X (R%d G%d B%d)', value, (value >> 5) & 7, (value >> 2) & 7, value & 3)
    end

    PALETTE = (0..255).map { |value| to_rgb888(value) }.freeze
  end
end
