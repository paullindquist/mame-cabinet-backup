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

Usage:  python3 get-artwork.py                     # mame.txt, fetch missing
        python3 get-artwork.py --force             # re-fetch even if present
        python3 get-artwork.py mame-all            # a different romlist
        python3 get-artwork.py mame-all --tag bestgames   # only tagged games
        python3 get-artwork.py mame-all --jobs 12  # concurrency (default 8)

The --tag option exists because the full list is 15,043 games and artwork is
worth having on the ones actually browsed first; --tag bestgames covers the 378
in the Best Games filter in a few minutes, and the rest can follow.
"""
import os
import shutil
import subprocess
import sys
import urllib.parse
from concurrent.futures import ThreadPoolExecutor

ROMLIST_DIR = '/home/paul/.attract/romlists'
ART_ROOT = '/home/paul/arcade'
BASE = 'https://raw.githubusercontent.com/libretro-thumbnails/MAME/master'

# Stop rather than fill the root filesystem. The cabinet boots from this card,
# and a full root is a much worse problem than missing artwork.
MIN_FREE_BYTES = 3 * 1024**3

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
    """Yield (romname, full MAME title) from an AM+ romlist.

    latin-1, NOT utf-8. Several MAME titles carry bytes that are not valid
    utf-8, and decoding the 15k list as utf-8 raises UnicodeDecodeError before
    a single file is fetched. latin-1 maps every byte, so it never throws.
    """
    games = []
    with open(path, encoding='latin-1') as fh:
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


def arg_value(flag, default):
    """Read '--flag value' from argv."""
    if flag in sys.argv:
        i = sys.argv.index(flag)
        if i + 1 < len(sys.argv):
            return sys.argv[i + 1]
    return default


def main():
    force = '--force' in sys.argv
    jobs = int(arg_value('--jobs', 8))
    tag = arg_value('--tag', None)

    # First bare argument is the romlist name; everything else is a flag or a
    # flag's value.
    name = 'mame'
    flags = {'--force'}
    skip_next = False
    for a in sys.argv[1:]:
        if skip_next:
            skip_next = False
            continue
        if a.startswith('--'):
            skip_next = a not in flags
            continue
        name = a
        break

    romlist = os.path.join(ROMLIST_DIR, '%s.txt' % name)
    if not os.path.exists(romlist):
        print("no romlist at %s -- run:\n"
              "  attractplus --build-romlist mame -o %s" % (romlist, name))
        return 1

    games = read_romlist(romlist)
    if not games:
        print("romlist is empty")
        return 1

    if tag:
        tagfile = os.path.join(ROMLIST_DIR, name, '%s.tag' % tag)
        if not os.path.exists(tagfile):
            print("no tag file at %s" % tagfile)
            return 1
        wanted = set(open(tagfile, encoding='latin-1').read().split())
        games = [g for g in games if g[0] in wanted]
        print("%s: %d game(s) tagged '%s'" % (name, len(games), tag))
    else:
        print("%s: %d game(s)" % (name, len(games)))
    print("%d parallel job(s)\n" % jobs)

    counts = {'got': 0, 'skipped': 0, 'missing': 0}
    stop = []

    def do_game(entry):
        romname, title = entry
        if stop:
            return
        for remote_dir, art_type in SOURCES:
            dest_dir = os.path.join(ART_ROOT, art_type)
            os.makedirs(dest_dir, exist_ok=True)
            dest = os.path.join(dest_dir, '%s.png' % romname)

            # A symlink here is our own fallback to an F12 capture; a real file
            # is artwork we or the user placed deliberately.
            if os.path.exists(dest) and not os.path.islink(dest) and not force:
                counts['skipped'] += 1
                continue

            if shutil.disk_usage(ART_ROOT).free < MIN_FREE_BYTES:
                if not stop:
                    stop.append(True)
                    print("STOPPING: less than %d GiB free"
                          % (MIN_FREE_BYTES // 1024**3))
                return

            url = '%s/%s/%s.png' % (BASE, remote_dir,
                                    urllib.parse.quote(libretro_name(title)))
            if fetch(url, dest):
                counts['got'] += 1
            else:
                counts['missing'] += 1

    with ThreadPoolExecutor(max_workers=jobs) as pool:
        for i, _ in enumerate(pool.map(do_game, games), 1):
            if i % 250 == 0:
                print("  %5d/%d  got=%d skipped=%d unavailable=%d  free=%.1fG"
                      % (i, len(games), counts['got'], counts['skipped'],
                         counts['missing'],
                         shutil.disk_usage(ART_ROOT).free / 1024**3))

    got, skipped, missing = counts['got'], counts['skipped'], counts['missing']
    print("\ndownloaded %d, skipped %d, unavailable %d" % (got, skipped, missing))
    if got:
        print("\nRestart the frontend to pick these up:")
        print("  sudo systemctl restart arcade")
    return 0


if __name__ == '__main__':
    sys.exit(main())
