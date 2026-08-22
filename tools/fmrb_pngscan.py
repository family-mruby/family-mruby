#!/usr/bin/env python3
"""Read one row or column of a Family mruby screen capture as colour runs.

Window borders are one pixel wide and rounded corners are three, so "the
frame is still there" and "a hole was punched in that panel" are questions
about a handful of pixels. Print the line as runs of equal colour and read
the answer off it instead of squinting at a screenshot
(fmruby-core/doc/ui_widgets/verify.md).

Usage: fmrb_pngscan.py img.png row Y [X0 X1]
       fmrb_pngscan.py img.png col X [Y0 Y1]

  $ python3 tools/fmrb_pngscan.py after.png row 155 100 320
  after.png row 155 [100,320): 27 runs
     100- 102 (  3px) #b66d55      <- outside the panel (wallpaper)
     103- 103 (  1px) #6d0000      <- border
     104- 177 ( 74px) #ffffff      <- panel, where a button used to be

What to look for: wallpaper colours inside a panel (the colour key punched a
hole), a missing one-pixel border, and the trace of a widget that was taken
away being anything but one flat colour.
"""
import sys

try:
    from PIL import Image
except ImportError:
    sys.exit("Pillow is required: pip install pillow")


def main(argv):
    if len(argv) not in (4, 6):
        sys.exit("usage: fmrb_pngscan.py img.png row|col N [FROM TO]")
    im = Image.open(argv[1]).convert("RGB")
    px = im.load()
    width, height = im.size
    kind = argv[2]
    if kind not in ("row", "col"):
        sys.exit("second argument must be 'row' or 'col'")
    n = int(argv[3])
    limit = width if kind == "row" else height
    lo = int(argv[4]) if len(argv) == 6 else 0
    hi = int(argv[5]) if len(argv) == 6 else limit
    lo, hi = max(0, lo), min(hi, limit)
    runs = []
    for i in range(lo, hi):
        c = px[i, n] if kind == "row" else px[n, i]
        if runs and runs[-1][0] == c:
            runs[-1][2] = i
        else:
            runs.append([c, i, i])
    print(f"{argv[1]} {kind} {n} [{lo},{hi}): {len(runs)} runs")
    for c, start, end in runs:
        print(f"  {start:4d}-{end:4d} ({end - start + 1:3d}px) "
              f"#{c[0]:02x}{c[1]:02x}{c[2]:02x}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
