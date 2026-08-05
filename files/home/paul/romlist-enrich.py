#!/usr/bin/env python3
"""Fill in a romlist's Category and Extra columns from catver.ini / nplayers.ini.

Why this exists: Attract-Mode Plus knows about catver.ini (the string is in the
binary) but does NOT read it during --build-romlist. Verified with strace: a
full build of 15,048 entries produced not one openat() for catver.ini or
nplayers.ini. MAME's -listxml, which is the only info_source the build uses,
has never carried genre data. So the Category column comes out empty and the
genre filters Paul wants have nothing to match on.

A romlist is a plain semicolon-delimited text file, so filling the columns in
directly is more dependable than hunting for a GUI path that may not exist.
Re-run this after any --build-romlist; it is idempotent.

  Category  <- catver.ini   e.g. "Fighter / 2.5D", "Shooter / Gallery"
  Extra     <- nplayers.ini e.g. "2P sim", "2P alt", "4P sim"

Players is deliberately LEFT ALONE. listxml's numeric count is reliable and
some layouts display it; nplayers' value is a string like "2P sim", so it goes
in Extra (unused by the build) where it can't break a numeric comparison. That
keeps "2 players" and "2 players simultaneously" as separate, both filterable.

Usage:  python3 ~/romlist-enrich.py [romlist-name]     (default: mame-all)
"""

import sys
import shutil
from pathlib import Path

ATTRACT = Path.home() / ".attract"
META = Path.home() / "arcade" / "metadata"

NAME = sys.argv[1] if len(sys.argv) > 1 else "mame-all"
ROMLIST = ATTRACT / "romlists" / f"{NAME}.txt"

# Field positions in the romlist header, 0-based. Named rather than numbered at
# the call site so a future header change is a one-line fix here.
F_NAME, F_CATEGORY, F_EXTRA = 0, 6, 15


def load_ini(path, section):
    """Read a MAME-style ini section into {romname: value}.

    These files are latin-1 in practice, not utf-8 -- a few entries carry
    accented characters and utf-8 decoding throws on them.
    """
    out = {}
    if not path.exists():
        print(f"  MISSING: {path}")
        return out
    in_section = False
    with open(path, encoding="latin-1") as fh:
        for line in fh:
            line = line.strip()
            if line.startswith("["):
                in_section = line.lower() == section.lower()
                continue
            if not in_section or "=" not in line or line.startswith(";"):
                continue
            key, _, value = line.partition("=")
            out[key.strip()] = value.strip()
    print(f"  {path.name}: {len(out)} entries")
    return out


def main():
    if not ROMLIST.exists():
        sys.exit(f"no such romlist: {ROMLIST}")

    print("Loading metadata:")
    category = load_ini(META / "catver.ini", "[Category]")
    players = load_ini(META / "nplayers.ini", "[NPlayers]")
    if not category and not players:
        sys.exit("no metadata loaded; nothing to do")

    # Never clobber an existing backup: re-running after a bad pass would
    # otherwise overwrite the last known-good copy with the damaged one.
    backup = ROMLIST.with_suffix(".txt.bak")
    if backup.exists():
        print(f"\nBackup already exists, keeping it: {backup.name}")
    else:
        shutil.copy2(ROMLIST, backup)
        print(f"\nBacked up to {backup.name}")

    # split("\n"), NOT splitlines(). Python's splitlines() also breaks on \x0b,
    # \x0c, \x1c-\x1e and \x85; decoded as latin-1, byte 0x85 becomes U+0085
    # (NEL) and splitlines() treats it as a line break. Several MAME titles
    # carry that byte, so an earlier version of this script tore 4 entries into
    # 8 malformed fragments -- 15048 rows in, 15052 out.
    text = ROMLIST.read_text(encoding="latin-1")
    lines = [ln.rstrip("\r") for ln in text.split("\n")]
    if lines and lines[-1] == "":
        lines.pop()
    hits_cat = hits_ply = 0
    out = []

    for line in lines:
        if line.startswith("#") or not line.strip():
            out.append(line)
            continue
        f = line.split(";")
        # Pad rather than skip: a short row would otherwise raise IndexError and
        # lose the entry entirely.
        if len(f) <= F_EXTRA:
            f += [""] * (F_EXTRA + 1 - len(f))
        rom = f[F_NAME]
        if rom in category:
            f[F_CATEGORY] = category[rom]
            hits_cat += 1
        if rom in players:
            f[F_EXTRA] = players[rom]
            hits_ply += 1
        out.append(";".join(f))

    # Drop duplicate stubs. A ROM present in more than one rompath directory
    # gets scanned twice, and Attract-Mode's own dedupe does not always catch
    # it: Paul's six curated sets live in ~/roms AND inside the merged set in
    # ~/roms-full, and 5 of the 6 came through twice -- once properly, once as
    # a stub with Title==Name and no year or manufacturer. In the frontend those
    # read as blank duplicate tiles. Keep whichever row carries more data.
    seen = {}
    order = []
    dropped = 0
    for row in out:
        if row.startswith("#") or not row.strip():
            order.append(row)
            continue
        name = row.split(";")[F_NAME]
        filled = sum(1 for x in row.split(";") if x.strip())
        if name in seen:
            dropped += 1
            if filled > seen[name][1]:
                order[seen[name][0]] = row          # replace the weaker row
                seen[name] = (seen[name][0], filled)
        else:
            seen[name] = (len(order), filled)
            order.append(row)
    if dropped:
        print(f"  Dropped {dropped} duplicate row(s)")
    out = order

    # Field-level damage is easy to miss by eye across 15k rows, and a corrupt
    # romlist shows up as games silently vanishing from the frontend rather
    # than as an error.
    if len(out) > len(lines):
        sys.exit(f"ABORT: {len(lines)} rows in, {len(out)} out -- not writing")
    bad = [i for i, x in enumerate(out, 1)
           if x and not x.startswith("#") and x.count(";") != 20]
    if bad:
        sys.exit(f"ABORT: {len(bad)} rows have the wrong field count "
                 f"(first at line {bad[0]}) -- not writing")

    ROMLIST.write_text("\n".join(out) + "\n", encoding="latin-1")

    total = len([x for x in lines if x and not x.startswith("#")])
    print(f"\n{total} entries")
    print(f"  Category set: {hits_cat}  ({100 * hits_cat // max(total, 1)}%)")
    print(f"  Extra set:    {hits_ply}  ({100 * hits_ply // max(total, 1)}%)")
    print(f"\nWrote {ROMLIST}")


if __name__ == "__main__":
    main()
