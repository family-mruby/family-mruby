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

    # The levels the hardware actually has: 8 reds, 8 greens, 4 blues.
    def levels(value)
      [(value >> 5) & 0x07, (value >> 2) & 0x07, value & 0x03]
    end

    def from_levels(red, green, blue)
      ((red.clamp(0, 7)) << 5) | ((green.clamp(0, 7)) << 2) | blue.clamp(0, 3)
    end

    # Accepts an RGB332 byte ("5E", "0x5E", "#5E") or a 24-bit colour
    # ("#RRGGBB", "RRGGBB", "#RGB"), the latter quantised to the nearest RGB332.
    # Returns nil for anything else, so it can be fed straight from an entry.
    def parse(text)
      token = text.to_s.strip.sub(/\A#/, '').sub(/\A0[xX]/, '')
      return nil unless /\A\h+\z/.match?(token)

      case token.length
      when 1, 2 then token.to_i(16)
      when 3 then from_rgb888(*token.chars.map { |digit| (digit * 2).to_i(16) })
      when 6 then from_rgb888(*[token[0, 2], token[2, 2], token[4, 2]].map { |pair| pair.to_i(16) })
      end
    end

    def label(value)
      format('0x%02X (R%d G%d B%d)', value, (value >> 5) & 7, (value >> 2) & 7, value & 3)
    end

    PALETTE = (0..255).map { |value| to_rgb888(value) }.freeze
  end
end
