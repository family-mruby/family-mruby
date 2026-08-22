#!/usr/bin/env ruby
# Count the pixels that differ between two Family mruby screen captures.
#
# Eyeballing two screenshots caught one screen defect in six during the
# widget work (fmruby-core/doc/ui_widgets/issues_s3.md). Counting them
# catches the rest: open a dialog, close it, and the ground behind it must
# come back with zero pixels changed.
#
# Two things to know before the numbers mean anything (both in
# fmruby-core/doc/ui_widgets/verify.md):
#
#   * the mouse cursor is drawn on the canvas, so park it at the same place
#     before each capture (`fmrb_input.rb move 410 200`), or it shows up as
#     a difference;
#   * the clock in the menu bar changes every second, so leave the bar out
#     of the compared rectangle (y >= 13).
#
# Usage: fmrb_pngdiff.rb a.png b.png [X Y W H] [--tol N]
#        (no rectangle = the whole image)
#
#   $ ruby tools/fmrb_pngdiff.rb base.png after.png 0 13 426 227
#   rect (0,13,426,227) of 426x240: 0 differing pixels
#
# --tol N ignores channel differences of N or less. Captures from the
# simulator's shared memory are exact, so leave it off there; frames pulled
# from a device's remote desktop (fmrb_rd_snap.rb) are JPEG and differ by a
# few levels everywhere, so compare those with --tol 24 or so -- a
# widget-sized patch of the wrong colour is hundreds of levels away and
# still counted. (JPEG input is handed to python3 + Pillow for decoding;
# PNG needs only Ruby.)
#
# Exit status is 0 when the images match over the rectangle, 1 when they do
# not, so it can gate a check in a script.

require_relative "fmrb_png"

MAX_LISTED = 20

argv = ARGV.dup
tol = 0
if (i = argv.index("--tol"))
  abort("--tol needs a number") if i + 1 >= argv.size
  tol = Integer(argv[i + 1], 10)
  argv.slice!(i, 2)
end
unless [2, 6].include?(argv.size)
  abort("Count the pixels that differ between two Family mruby screen captures.\n" \
        "usage: fmrb_pngdiff.rb a.png b.png [X Y W H] [--tol N]")
end

aw, ah, pa = FmrbPng.read_rgb(argv[0])
bw, bh, pb = FmrbPng.read_rgb(argv[1])
if aw != bw || ah != bh
  puts "size differs: (#{aw}, #{ah}) vs (#{bw}, #{bh})"
  exit 1
end
if argv.size == 6
  x0, y0, w, h = argv[2, 4].map { |v| Integer(v, 10) }
else
  x0, y0, w, h = 0, 0, aw, ah
end

diff = []
y = [0, y0].max
y_end = [y0 + h, ah].min
x_lo = [0, x0].max
x_end = [x0 + w, aw].min
while y < y_end
  ra = pa[y]
  rb = pb[y]
  x = x_lo
  while x < x_end
    o = x * 3
    if (ra.getbyte(o) - rb.getbyte(o)).abs > tol ||
       (ra.getbyte(o + 1) - rb.getbyte(o + 1)).abs > tol ||
       (ra.getbyte(o + 2) - rb.getbyte(o + 2)).abs > tol
      diff << [x, y]
    end
    x += 1
  end
  y += 1
end

suffix = tol != 0 ? " (tolerance #{tol})" : ""
puts "rect (#{x0},#{y0},#{w},#{h}) of #{aw}x#{ah}: " \
     "#{diff.size} differing pixels#{suffix}"
diff[0, MAX_LISTED].each do |x, yy|
  ca = FmrbPng.pixel(pa, x, yy)
  cb = FmrbPng.pixel(pb, x, yy)
  puts format("   (%d,%d) #%02x%02x%02x -> #%02x%02x%02x", x, yy, *ca, *cb)
end
puts "   ... #{diff.size - MAX_LISTED} more" if diff.size > MAX_LISTED
exit(diff.empty? ? 0 : 1)
