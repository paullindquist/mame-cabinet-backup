#!/usr/bin/env python3
"""Fetch snap and title artwork for everything in the Attract-Mode romlist.

Pulls from libretro-thumbnails, which indexes MAME artwork by the game's full
MAME description -- the same string AM+ stores in field 2 of its romlist, so the
two line up without any name mangling.

Files are written as <romname>.png into the artwork tree that mame.ini and
AM+ both point at (/home/paul/arcade/...), which is where F12 captures also go.

Other sources, if coverage here is thin:
  progettosnaps.net          complete MAME extras sets (manual download)
  adb.arcadeitalia.net       marquees/wheels -- use `attractplus --scrape-art`
  emumovies.com              animated video snaps (subscription)

Usage:  python3 get-artwork.py            # fetch anything missing
        python3 get-artwork.py --force    # re-fetch even if present
"""
import os
import subprocess
import sys
import urllib.parse

ROMLIST = '/home/paul/.attract/romlists/mame.txt'
ART_ROOT = '/home/paul/arcade'
BASE = 'https://raw.githubusercontent.com/libretro-thumbnails/MAME/master'

# libretro directory -> local artwork type AM+ is configured to read.
# Title screens go to 'flyer' simply because it is an otherwise-unused slot that
# layouts can display; they are not really flyers.
SOURCES = [
    ('Named_Snaps',  'snap'),
    ('Named_Titles', 'flyer'),
]


def libretro_name(title):
    """Convert a MAME description to libretro-thumbnails' filename form.

    Characters that are illegal in filenames are replaced with underscores --
    without this, any game with a date or a colon in its title (e.g. Mortal
    Kombat's "rev 5.0 T-Unit 03/19/93") silently 404s.
    """
    for ch in '&*/:`<>?\\|':
        title = title.replace(ch, '_')
    return title


def read_romlist(path):
    """Yield (romname, full MAME title) from an AM+ romlist."""
    games = []
    with open(path, encoding='utf-8') as fh:
        for line in fh:
            line = line.strip()
            if not line or line.startswith('#'):
                continue
            parts = line.split(';')
            if len(parts) >= 2 and parts[0] and parts[1]:
                games.append((parts[0], parts[1]))
    return games


def fetch(url, dest):
    """Download url to dest. Returns size on success, None on failure."""
    tmp = dest + '.part'
    rc = subprocess.run(
        ['wget', '-q', '--timeout=25', '--tries=2', '-O', tmp, url],
        capture_output=True).returncode
    if rc != 0 or not os.path.exists(tmp) or os.path.getsize(tmp) == 0:
        if os.path.exists(tmp):
            os.remove(tmp)
        return None
    os.replace(tmp, dest)
    return os.path.getsize(dest)


def main():
    force = '--force' in sys.argv

    if not os.path.exists(ROMLIST):
        print("no romlist at %s -- run:\n"
              "  attractplus --build-romlist mame -o mame" % ROMLIST)
        return 1

    games = read_romlist(ROMLIST)
    if not games:
        print("romlist is empty")
        return 1
    print("%d game(s) in romlist\n" % len(games))

    got = missing = skipped = 0
    for romname, title in games:
        print("%s  (%s)" % (romname, title))
        for remote_dir, art_type in SOURCES:
            dest_dir = os.path.join(ART_ROOT, art_type)
            os.makedirs(dest_dir, exist_ok=True)
            dest = os.path.join(dest_dir, '%s.png' % romname)

            # A symlink here is our own fallback to an F12 capture; a real file
            # is artwork we or the user placed deliberately.
            if os.path.exists(dest) and not os.path.islink(dest) and not force:
                print("    %-8s already present, skipped" % art_type)
                skipped += 1
                continue

            url = '%s/%s/%s.png' % (BASE, remote_dir,
                                    urllib.parse.quote(libretro_name(title)))
            size = fetch(url, dest)
            if size:
                print("    %-8s %6d bytes -> %s" % (art_type, size, dest))
                got += 1
            else:
                print("    %-8s not available upstream" % art_type)
                missing += 1
        print()

    print("downloaded %d, skipped %d, unavailable %d" % (got, skipped, missing))
    if got:
        print("\nRestart the frontend to pick these up:")
        print("  sudo systemctl restart arcade")
    return 0


if __name__ == '__main__':
    sys.exit(main())
