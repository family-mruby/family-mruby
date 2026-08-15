# frozen_string_literal: true

module FmAssetEditor
  # Read and write the 8bpp indexed BMPs the firmware loads.
  #
  # Writing always produces the exact shape the loader accepts
  # (fmruby-graphics-audio/main/common/fmrb_bmp332.c): BITMAPINFOHEADER, 8 bits
  # per pixel, uncompressed, bottom-up rows, and a full 256 entry palette so the
  # pixel data starts at offset 1078. That is byte for byte what
  # fmruby-core/tool/gen_icon_bmp.rb and tool/basic/basic_sheet.rb already
  # generate, so re-saving an untouched file leaves the repository clean.
  #
  # Reading is deliberately more permissive (1, 4 and 8 bits per pixel, either
  # row order) because artwork may arrive from other editors.
  module Bmp
    class Error < StandardError; end

    FILE_HEADER_SIZE = 14
    DIB_HEADER_SIZE = 40
    PALETTE_ENTRIES = 256
    PIXEL_OFFSET = FILE_HEADER_SIZE + DIB_HEADER_SIZE + PALETTE_ENTRIES * 4 # 1078
    PIXELS_PER_METER = 2835 # what the existing generators write
    MAX_SIDE = 256          # the loader rejects anything larger

    # pixels:      flat Array of palette bytes, top-down, width * height entries
    # palette:     Array of [r, g, b], up to 256 entries (missing ones write as 0)
    # color_count: the biClrUsed field; also the signal that tells the two BMP
    #              flavours apart (4 = BASIC sheet, 256 = RGB332 sprite)
    Image = Struct.new(:width, :height, :pixels, :palette, :color_count, keyword_init: true)

    module_function

    def read(path)
      data = File.binread(path)
      raise Error, "#{path}: not a BMP" if data.bytesize < FILE_HEADER_SIZE + DIB_HEADER_SIZE
      raise Error, "#{path}: not a BMP" unless data[0, 2] == 'BM'

      pixel_offset = data[10, 4].unpack1('V')
      dib_size = data[14, 4].unpack1('V')
      width = data[18, 4].unpack1('l<')
      raw_height = data[22, 4].unpack1('l<')
      bpp = data[28, 2].unpack1('v')
      compression = data[30, 4].unpack1('V')
      color_count = data[46, 4].unpack1('V')

      raise Error, "#{path}: need an uncompressed BITMAPINFOHEADER BMP" if dib_size < DIB_HEADER_SIZE || compression != 0
      raise Error, "#{path}: need 1, 4 or 8 bits per pixel, got #{bpp}" unless [1, 4, 8].include?(bpp)

      top_down = raw_height.negative?
      height = raw_height.abs
      raise Error, "#{path}: bad size #{width}x#{height}" if width < 1 || height < 1

      entries = color_count.zero? ? (1 << bpp) : color_count
      palette_offset = FILE_HEADER_SIZE + dib_size
      palette = Array.new(entries) do |i|
        b, g, r = data[palette_offset + i * 4, 3].to_s.unpack('C3')
        [r.to_i, g.to_i, b.to_i]
      end

      stride = ((width * bpp + 31) / 32) * 4
      pixels = Array.new(width * height, 0)
      height.times do |y|
        file_row = top_down ? y : height - 1 - y
        row = data[pixel_offset + file_row * stride, stride].to_s.bytes
        base = y * width
        width.times do |x|
          pixels[base + x] =
            case bpp
            when 8 then row[x].to_i
            when 4 then x.odd? ? (row[x / 2].to_i & 0x0F) : (row[x / 2].to_i >> 4)
            else (row[x / 8].to_i >> (7 - (x % 8))) & 1
            end
        end
      end

      Image.new(width: width, height: height, pixels: pixels,
                palette: palette, color_count: color_count)
    end

    def write(path, image)
      width = image.width
      height = image.height
      raise Error, "bad size #{width}x#{height}" if width < 1 || height < 1
      raise Error, "#{width}x#{height} is over the #{MAX_SIDE}px the loader accepts" if width > MAX_SIDE || height > MAX_SIDE

      pad = (4 - (width % 4)) % 4
      palette = Array.new(PALETTE_ENTRIES) do |i|
        r, g, b = image.palette[i] || [0, 0, 0]
        [b, g, r, 0].pack('C4')
      end.join

      # BMP scanlines run bottom-up.
      body = (height - 1).downto(0).map { |y| image.pixels[y * width, width].pack('C*') + ("\0" * pad) }.join

      header = 'BM'.b + [PIXEL_OFFSET + body.bytesize, 0, PIXEL_OFFSET].pack('VVV')
      dib = [DIB_HEADER_SIZE, width, height].pack('Vll') +
            [1, 8].pack('vv') +
            [0, body.bytesize, PIXELS_PER_METER, PIXELS_PER_METER,
             image.color_count.to_i, 0].pack('V6')

      File.binwrite(path, header + dib + palette + body)
    end
  end
end
