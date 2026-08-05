#!/usr/bin/env python3
"""Fill artwork gaps from the progetto-SNAPS full sets.

libretro-thumbnails only covers about a fifth of a merged MAME set -- it indexes
by full game title and simply has no entry for most of the gambling, mahjong and
prototype machines that make up the bulk of a 16k romset. progetto-SNAPS ships
one PNG per MAME machine name for all ~50,000, which is both better coverage and
an easier match: the filenames ARE the rom names, so no title mangling.

The downloads are .zip files with a .7z NESTED INSIDE them -- the PNGs are two
archives deep. The outer zip is already unpacked; this reads the inner 7z, which
is why p7zip-full has to be installed:

    sudo apt install p7zip-full

Only games in the romlist are extracted (~15k of 50k), and only those currently
missing, so existing libretro artwork and any F12 captures are left alone.

  staging/snap.7z    -> ~/arcade/snap    (in-game screenshot)
  staging/titles.7z  -> ~/arcade/flyer   (title screen)

'flyer' is where get-artwork.py already puts title screens: an otherwise-unused
artwork slot the layouts can display. They are not really flyers.

Usage:  python3 ~/progettosnaps-artwork.py [romlist-name]   (default: mame-all)
        python3 ~/progettosnaps-artwork.py --force          (replace existing)
"""

import os
import shutil
import subprocess
import sys
import tempfile

STAGING = "/home/paul/arcade/staging"
ART_ROOT = "/home/paul/arcade"
ROMLIST_DIR = "/home/paul/.attract/romlists"

PACKS = [("snap.7z", "snap"), ("titles.7z", "flyer")]

MIN_FREE_BYTES = 2 * 1024**3


def romnames(path):
    """Rom names from an AM+ romlist. latin-1: some titles are not valid utf-8."""
    names = set()
    with open(path, encoding="latin-1") as fh:
        for line in fh:
            if line.startswith("#") or not line.strip():
                continue
            names.add(line.split(";")[0])
    return names


def free_bytes(path):
    st = os.statvfs(path)
    return st.f_bavail * st.f_frsize


def main():
    if shutil.which("7z") is None:
        sys.exit("7z not found -- run:  sudo apt install p7zip-full")

    force = "--force" in sys.argv
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    name = args[0] if args else "mame-all"

    romlist = os.path.join(ROMLIST_DIR, "%s.txt" % name)
    if not os.path.exists(romlist):
        sys.exit("no romlist at %s" % romlist)
    wanted = romnames(romlist)
    print("%s: %d games\n" % (name, len(wanted)))

    total = 0
    for packname, art_type in PACKS:
        pack = os.path.join(STAGING, packname)
        dest_dir = os.path.join(ART_ROOT, art_type)
        os.makedirs(dest_dir, exist_ok=True)

        if not os.path.exists(pack):
            print("%-12s MISSING -- skipped" % packname)
            continue

        # Only ask for what is actually missing. Extracting all 50k and deleting
        # the surplus would write about 1.2 GB of files we do not want, on a card
        # that is already 89% full.
        todo = [r for r in sorted(wanted)
                if force or not os.path.exists(os.path.join(dest_dir, "%s.png" % r))]
        print("%s -> %s/   %d missing of %d" % (packname, art_type, len(todo), len(wanted)))
        if not todo:
            continue
        if free_bytes(dest_dir) < MIN_FREE_BYTES:
            sys.exit("under 2 GiB free -- refusing to extract")

        before = len(os.listdir(dest_dir))
        with tempfile.NamedTemporaryFile("w", suffix=".txt", delete=False) as lf:
            lf.write("\n".join("%s.png" % r for r in todo) + "\n")
            listfile = lf.name
        try:
            # 'e' flattens any directory structure inside the archive, so the
            # result is <dest>/<rom>.png regardless of how the pack is laid out.
            proc = subprocess.run(
                ["7z", "e", pack, "-o" + dest_dir, "@" + listfile, "-y"],
                capture_output=True, text=True)
            if proc.returncode != 0:
                # A pack containing none of the requested names is a warning
                # (exit 1), not a failure worth aborting the whole run for.
                print("  7z exit %d: %s" % (proc.returncode,
                                            proc.stderr.strip()[:200]))
        finally:
            os.unlink(listfile)

        added = len(os.listdir(dest_dir)) - before
        print("  added %d\n" % added)
        total += added

    print("added %d file(s) total" % total)
    print("free space now: %.1f G" % (free_bytes(ART_ROOT) / 1024**3))


if __name__ == "__main__":
    main()
