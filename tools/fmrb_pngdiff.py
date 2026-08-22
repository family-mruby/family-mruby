#!/usr/bin/env python3
"""Count the pixels that differ between two Family mruby screen captures.

Eyeballing two screenshots caught one screen defect in six during the widget
work (fmruby-core/doc/ui_widgets/issues_s3.md). Counting them catches the
rest: open a dialog, close it, and the ground behind it must come back with
zero pixels changed.

Two things to know before the numbers mean anything (both in
fmruby-core/doc/ui_widgets/verify.md):

  * the mouse cursor is drawn on the canvas, so park it at the same place
    before each capture (`fmrb_input.rb move 410 200`), or it shows up as a
    difference;
  * the clock in the menu bar changes every second, so leave the bar out of
    the compared rectangle (y >= 13).

Usage: fmrb_pngdiff.py a.png b.png [X Y W H] [--tol N]
       (no rectangle = the whole image)

  $ python3 tools/fmrb_pngdiff.py base.png after.png 0 13 426 227
  rect (0,13,426,227) of 426x240: 0 differing pixels

--tol N ignores channel differences of N or less. Captures from the
simulator's shared memory are exact, so leave it off there; frames pulled
from a device's remote desktop (fmrb_rd_snap.rb) are JPEG and differ by a
few levels everywhere, so compare those with --tol 24 or so -- a widget-sized
patch of the wrong colour is hundreds of levels away and still counted.

Exit status is 0 when the images match over the rectangle, 1 when they do
not, so it can gate a check in a script.
"""
import sys

try:
    from PIL import Image
except ImportError:
    sys.exit("Pillow is required: pip install pillow")

MAX_LISTED = 20


def main(argv):
    tol = 0
    if "--tol" in argv:
        i = argv.index("--tol")
        if i + 1 >= len(argv):
            sys.exit("--tol needs a number")
        tol = int(argv[i + 1])
        argv = argv[:i] + argv[i + 2:]
    if len(argv) not in (3, 7):
        sys.exit(__doc__.strip().splitlines()[0] +
                 "\nusage: fmrb_pngdiff.py a.png b.png [X Y W H] [--tol N]")
    a = Image.open(argv[1]).convert("RGB")
    b = Image.open(argv[2]).convert("RGB")
    if a.size != b.size:
        print(f"size differs: {a.size} vs {b.size}")
        return 1
    width, height = a.size
    if len(argv) == 7:
        x0, y0, w, h = (int(v) for v in argv[3:7])
    else:
        x0, y0, w, h = 0, 0, width, height
    pa, pb = a.load(), b.load()
    diff = []
    for y in range(max(0, y0), min(y0 + h, height)):
        for x in range(max(0, x0), min(x0 + w, width)):
            ca, cb = pa[x, y], pb[x, y]
            if max(abs(ca[i] - cb[i]) for i in range(3)) > tol:
                diff.append((x, y, ca, cb))
    suffix = f" (tolerance {tol})" if tol else ""
    print(f"rect ({x0},{y0},{w},{h}) of {width}x{height}: "
          f"{len(diff)} differing pixels{suffix}")
    for x, y, ca, cb in diff[:MAX_LISTED]:
        print(f"   ({x},{y}) #{ca[0]:02x}{ca[1]:02x}{ca[2]:02x}"
              f" -> #{cb[0]:02x}{cb[1]:02x}{cb[2]:02x}")
    if len(diff) > MAX_LISTED:
        print(f"   ... {len(diff) - MAX_LISTED} more")
    return 1 if diff else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
