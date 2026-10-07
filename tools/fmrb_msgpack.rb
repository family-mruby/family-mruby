# frozen_string_literal: true

# A small MessagePack encoder / decoder in plain Ruby (standard library
# only), for the PC tools that talk to Asterism objects on the boards
# (tools/fmrb_zenoh.rb call / meta). It covers what Asterism sends: nil,
# true, false, Integer (64 bit), Float, String, Symbol (as a String), Array
# and Hash. Decoding also accepts bin (as a binary String) and float 32;
# ext types are not supported.
#
#   FmrbMsgpack.pack(["status", [], {}])   # => binary String
#   FmrbMsgpack.unpack(bytes)               # => Ruby value
module FmrbMsgpack
  class Error < StandardError; end

  module_function

  def pack(value)
    out = +"".b
    write(out, value)
    out
  end

  def write(out, v)
    case v
    when nil then out << "\xc0".b
    when false then out << "\xc2".b
    when true then out << "\xc3".b
    when Integer then write_int(out, v)
    when Float then out << "\xcb".b << [v].pack("G")
    when Symbol then write_str(out, v.to_s)
    when String then write_str(out, v)
    when Array
      write_len(out, v.size, 0x90, 15, "\xdc", "\xdd")
      v.each { |e| write(out, e) }
    when Hash
      write_len(out, v.size, 0x80, 15, "\xde", "\xdf")
      v.each do |k, x|
        write(out, k)
        write(out, x)
      end
    else
      raise Error, "cannot encode a #{v.class}"
    end
  end

  def write_int(out, v)
    if v >= 0
      if v < 0x80 then out << [v].pack("C")
      elsif v < 0x100 then out << "\xcc".b << [v].pack("C")
      elsif v < 0x10000 then out << "\xcd".b << [v].pack("n")
      elsif v < 0x100000000 then out << "\xce".b << [v].pack("N")
      elsif v < 0x10000000000000000 then out << "\xcf".b << [v].pack("Q>")
      else raise Error, "integer too large: #{v}"
      end
    elsif v >= -32 then out << [v].pack("c")
    elsif v >= -0x80 then out << "\xd0".b << [v].pack("c")
    elsif v >= -0x8000 then out << "\xd1".b << [v].pack("s>")
    elsif v >= -0x80000000 then out << "\xd2".b << [v].pack("l>")
    elsif v >= -0x8000000000000000 then out << "\xd3".b << [v].pack("q>")
    else raise Error, "integer too small: #{v}"
    end
  end

  def write_str(out, s)
    bytes = s.b
    n = bytes.bytesize
    if n < 32 then out << [0xa0 | n].pack("C")
    elsif n < 0x100 then out << "\xd9".b << [n].pack("C")
    elsif n < 0x10000 then out << "\xda".b << [n].pack("n")
    else out << "\xdb".b << [n].pack("N")
    end
    out << bytes
  end

  def write_len(out, n, fix, fix_max, tag16, tag32)
    if n <= fix_max then out << [fix | n].pack("C")
    elsif n < 0x10000 then out << tag16.b << [n].pack("n")
    else out << tag32.b << [n].pack("N")
    end
  end

  # One value from the start of bytes (the rest must be empty).
  def unpack(bytes)
    r = Reader.new(bytes.b)
    v = r.read
    raise Error, "#{r.left} trailing bytes" unless r.left.zero?
    v
  end

  class Reader
    def initialize(bytes)
      @b = bytes
      @i = 0
    end

    def left
      @b.bytesize - @i
    end

    def take(n)
      raise Error, "truncated data" if left < n
      s = @b.byteslice(@i, n)
      @i += n
      s
    end

    def u8 = take(1).unpack1("C")

    def str(n)
      s = take(n)
      u = s.dup.force_encoding("UTF-8")
      u.valid_encoding? ? u : s
    end

    def read
      t = u8
      case t
      when 0x00..0x7f then t
      when 0x80..0x8f then map(t & 0x0f)
      when 0x90..0x9f then array(t & 0x0f)
      when 0xa0..0xbf then str(t & 0x1f)
      when 0xc0 then nil
      when 0xc2 then false
      when 0xc3 then true
      when 0xc4 then take(u8)
      when 0xc5 then take(take(2).unpack1("n"))
      when 0xc6 then take(take(4).unpack1("N"))
      when 0xca then take(4).unpack1("g")
      when 0xcb then take(8).unpack1("G")
      when 0xcc then u8
      when 0xcd then take(2).unpack1("n")
      when 0xce then take(4).unpack1("N")
      when 0xcf then take(8).unpack1("Q>")
      when 0xd0 then take(1).unpack1("c")
      when 0xd1 then take(2).unpack1("s>")
      when 0xd2 then take(4).unpack1("l>")
      when 0xd3 then take(8).unpack1("q>")
      when 0xd9 then str(u8)
      when 0xda then str(take(2).unpack1("n"))
      when 0xdb then str(take(4).unpack1("N"))
      when 0xdc then array(take(2).unpack1("n"))
      when 0xdd then array(take(4).unpack1("N"))
      when 0xde then map(take(2).unpack1("n"))
      when 0xdf then map(take(4).unpack1("N"))
      when 0xe0..0xff then t - 0x100
      else raise Error, format("unsupported type byte 0x%02x", t)
      end
    end

    def array(n)
      Array.new(n) { read }
    end

    def map(n)
      h = {}
      n.times do
        k = read
        h[k] = read
      end
      h
    end
  end
end
