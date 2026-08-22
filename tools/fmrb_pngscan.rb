#!/usr/bin/env ruby
# Read one row or column of a Family mruby screen capture as colour runs.
#
# Window borders are one pixel wide and rounded corners are three, so "the
# frame is still there" and "a hole was punched in that panel" are questions
# about a handful of pixels. Print the line as runs of equal colour and read
# the answer off it instead of squinting at a screenshot
# (fmruby-core/doc/ui_widgets/verify.md).
#
# Usage: fmrb_pngscan.rb img.png row Y [X0 X1]
#        fmrb_pngscan.rb img.png col X [Y0 Y1]
#
#   $ ruby tools/fmrb_pngscan.rb after.png row 155 100 320
#   after.png row 155 [100,320): 27 runs
#      100- 102 (  3px) #b66d55      <- outside the panel (wallpaper)
#      103- 103 (  1px) #6d0000      <- border
#      104- 177 ( 74px) #ffffff      <- panel, where a button used to be
#
# What to look for: wallpaper colours inside a panel (the colour key punched
# a hole), a missing one-pixel border, and the trace of a widget that was
# taken away being anything but one flat colour. Runs only mean anything on
# an exact capture (the simulator's shared memory); a JPEG from a device
# dithers every edge into noise.

require_relative "fmrb_png"

unless [3, 5].include?(ARGV.size)
  abort("usage: fmrb_pngscan.rb img.png row|col N [FROM TO]")
end
width, height, px = FmrbPng.read_rgb(ARGV[0])
kind = ARGV[1]
abort("second argument must be 'row' or 'col'") unless kind == "row" || kind == "col"
n = Integer(ARGV[2], 10)
limit = kind == "row" ? width : height
lo = ARGV.size == 5 ? Integer(ARGV[3], 10) : 0
hi = ARGV.size == 5 ? Integer(ARGV[4], 10) : limit
lo = [0, lo].max
hi = [hi, limit].min

runs = []
i = lo
while i < hi
  c = kind == "row" ? FmrbPng.pixel(px, i, n) : FmrbPng.pixel(px, n, i)
  if !runs.empty? && runs[-1][0] == c
    runs[-1][2] = i
  else
    runs << [c, i, i]
  end
  i += 1
end

puts "#{ARGV[0]} #{kind} #{n} [#{lo},#{hi}): #{runs.size} runs"
runs.each do |c, s, e|
  puts format("  %4d-%4d (%3dpx) #%02x%02x%02x", s, e, e - s + 1, *c)
end
