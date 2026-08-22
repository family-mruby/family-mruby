# Read a screen capture into RGB rows, with nothing but the Ruby stdlib.
#
# PNG is decoded here directly: chunk walk, one Zlib.inflate, and the five
# scanline filters undone by hand. That covers everything our own tools
# write (fmrb_screenshot.py and friends emit 8-bit non-interlaced PNGs).
# JPEG -- the frames fmrb_rd_snap.rb pulls from a device -- would need a
# real codec, so for those one Pillow one-liner converts to a temporary PNG
# first (python3 + Pillow are already host dependencies of the screenshot
# tool; they are only touched for JPEG input).
#
#   w, h, rows = FmrbPng.read_rgb(path)
#
# rows is an Array of binary Strings, 3 bytes (R, G, B) per pixel; alpha,
# greyscale and palette images come back expanded to plain RGB, matching
# what Pillow's convert("RGB") used to hand the Python versions of these
# tools.

require "zlib"

module FmrbPng
  SIGNATURE = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A].pack("C8")

  # -> [width, height, rows]
  def self.read_rgb(path)
    head = File.open(path, "rb") { |f| f.read(8) }
    abort("#{path}: empty or unreadable") if head.nil? || head.bytesize < 8
    return read_png(path) if head == SIGNATURE
    return read_via_pillow(path) if head.getbyte(0) == 0xFF && head.getbyte(1) == 0xD8
    abort("#{path}: not a PNG or JPEG")
  end

  # Pull one pixel of read_rgb's rows as [r, g, b].
  def self.pixel(rows, x, y)
    o = x * 3
    row = rows[y]
    [row.getbyte(o), row.getbyte(o + 1), row.getbyte(o + 2)]
  end

  def self.read_png(path)
    data = File.binread(path)
    pos = 8
    width = height = bit_depth = color_type = interlace = nil
    palette = nil
    idat = +""
    while pos + 8 <= data.bytesize
      length = data[pos, 4].unpack1("N")
      type = data[pos + 4, 4]
      body = data[pos + 8, length]
      case type
      when "IHDR"
        width, height, bit_depth, color_type, _comp, _filt, interlace =
          body.unpack("NNC5")
      when "PLTE"
        palette = body
      when "IDAT"
        idat << body
      when "IEND"
        break
      end
      pos += 12 + length # length + type + body + CRC
    end
    abort("#{path}: no IHDR") if width.nil?
    abort("#{path}: interlaced PNG not supported") if interlace != 0
    abort("#{path}: bit depth #{bit_depth} not supported (8 only)") if bit_depth != 8
    channels = { 0 => 1, 2 => 3, 3 => 1, 4 => 2, 6 => 4 }[color_type]
    abort("#{path}: colour type #{color_type} not supported") if channels.nil?

    rows = unfilter(Zlib.inflate(idat), width, height, channels, path)
    [width, height, to_rgb(rows, width, color_type, palette, path)]
  end

  # Undo the per-scanline filters (0 none, 1 sub, 2 up, 3 average, 4 paeth).
  def self.unfilter(raw, width, height, channels, path)
    stride = width * channels
    rows = []
    prev = nil
    pos = 0
    height.times do
      filter = raw.getbyte(pos)
      cur = raw[pos + 1, stride]
      abort("#{path}: truncated image data") if cur.nil? || cur.bytesize < stride
      pos += 1 + stride
      case filter
      when 0 # None
      when 1 # Sub
        i = channels
        while i < stride
          cur.setbyte(i, (cur.getbyte(i) + cur.getbyte(i - channels)) & 0xFF)
          i += 1
        end
      when 2 # Up
        if prev
          i = 0
          while i < stride
            cur.setbyte(i, (cur.getbyte(i) + prev.getbyte(i)) & 0xFF)
            i += 1
          end
        end
      when 3 # Average
        i = 0
        while i < stride
          a = i >= channels ? cur.getbyte(i - channels) : 0
          b = prev ? prev.getbyte(i) : 0
          cur.setbyte(i, (cur.getbyte(i) + ((a + b) >> 1)) & 0xFF)
          i += 1
        end
      when 4 # Paeth
        i = 0
        while i < stride
          a = i >= channels ? cur.getbyte(i - channels) : 0
          b = prev ? prev.getbyte(i) : 0
          c = prev && i >= channels ? prev.getbyte(i - channels) : 0
          p = a + b - c
          pa = (p - a).abs
          pb = (p - b).abs
          pc = (p - c).abs
          pred = pa <= pb && pa <= pc ? a : pb <= pc ? b : c
          cur.setbyte(i, (cur.getbyte(i) + pred) & 0xFF)
          i += 1
        end
      else
        abort("#{path}: unknown scanline filter #{filter}")
      end
      rows << cur
      prev = cur
    end
    rows
  end

  # Expand every supported colour type to 3 bytes per pixel, the way
  # Pillow's convert("RGB") does: alpha dropped, grey replicated, palette
  # looked up.
  def self.to_rgb(rows, width, color_type, palette, path)
    case color_type
    when 6 # RGBA: drop alpha
      rows.map! do |row|
        out = +""
        i = 0
        while i < width * 4
          out << row[i, 3]
          i += 4
        end
        out
      end
    when 0 # greyscale
      rows.map! do |row|
        out = +""
        i = 0
        while i < width
          g = row[i]
          out << g << g << g
          i += 1
        end
        out
      end
    when 4 # greyscale + alpha
      rows.map! do |row|
        out = +""
        i = 0
        while i < width * 2
          g = row[i]
          out << g << g << g
          i += 2
        end
        out
      end
    when 3 # palette
      abort("#{path}: palette image without PLTE") if palette.nil?
      rows.map! do |row|
        out = +""
        i = 0
        while i < width
          out << palette[row.getbyte(i) * 3, 3]
          i += 1
        end
        out
      end
    end
    rows # colour type 2 (plain RGB) passes through untouched
  end

  # JPEG: have Pillow rewrite it as a PNG in a temporary file and read that.
  def self.read_via_pillow(path)
    require "tempfile"
    Tempfile.create(["fmrb_png", ".png"]) do |tmp|
      tmp.close
      ok = system("python3", "-c",
                  "import sys\n" \
                  "from PIL import Image\n" \
                  "Image.open(sys.argv[1]).convert('RGB').save(sys.argv[2], 'PNG')",
                  path, tmp.path)
      abort("#{path}: JPEG input needs python3 + Pillow (only PNG is decoded natively)") unless ok
      return read_png(tmp.path)
    end
  end

  private_class_method :read_png, :unfilter, :to_rgb, :read_via_pillow
end
