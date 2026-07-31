#!/usr/bin/env python3
"""Render a boot splash image from a game's title screen.

The source art is a 400x254 title screen -- tiny by modern standards, so any
smooth upscale turns it to mush. Instead this scales by a whole-number factor
with nearest-neighbour sampling, which keeps every pixel a hard square. On a
CRT-style cabinet that reads as deliberate rather than low-res.

Output is a PNG sized to the screen, art centred on black, which is what the
Plymouth theme expects.

Usage:  python3 make-splash.py [romname] [-o out.png] [-W 1280] [-H 960]
"""
import argparse
import os
import sys

from PIL import Image

ART_DIRS = ['/home/paul/arcade/flyer', '/home/paul/arcade/snap']


def find_art(rom):
    for d in ART_DIRS:
        p = os.path.join(d, '%s.png' % rom)
        if os.path.isfile(p):
            return p
    return None


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('rom', nargs='?', default='mk')
    ap.add_argument('-o', '--out', default='/home/paul/arcade/splash.png')
    ap.add_argument('-W', '--width', type=int, default=1280)
    ap.add_argument('-H', '--height', type=int, default=960)
    # Leave a margin so the art never touches the bezel on an overscanning
    # arcade monitor.
    # 0.95 rather than 0.90 deliberately: at 0.90 a 400px-wide source just
    # misses 3x on a 1280 screen and drops to 2x, which wastes half the panel.
    ap.add_argument('--margin', type=float, default=0.95)
    args = ap.parse_args()

    src = find_art(args.rom)
    if not src:
        print("no artwork found for %r in: %s" % (args.rom, ', '.join(ART_DIRS)),
              file=sys.stderr)
        return 1

    art = Image.open(src).convert('RGB')
    aw, ah = art.size

    # Largest WHOLE-number scale that still fits inside the margin. Integer
    # scaling is the whole point -- 2.7x would reintroduce the blurring that
    # nearest-neighbour is here to avoid.
    limit_w = args.width * args.margin
    limit_h = args.height * args.margin
    scale = min(int(limit_w // aw), int(limit_h // ah))
    if scale < 1:
        scale = 1
        print("warning: screen smaller than the source art; not scaling",
              file=sys.stderr)

    art = art.resize((aw * scale, ah * scale), Image.NEAREST)

    canvas = Image.new('RGB', (args.width, args.height), (0, 0, 0))
    canvas.paste(art, ((args.width - art.width) // 2,
                       (args.height - art.height) // 2))

    os.makedirs(os.path.dirname(args.out), exist_ok=True)
    canvas.save(args.out)
    print("%s  %dx%d  (source %s, %dx%d scaled %dx)"
          % (args.out, args.width, args.height, os.path.basename(src),
             aw, ah, scale))
    return 0


if __name__ == '__main__':
    sys.exit(main())
