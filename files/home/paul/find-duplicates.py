#!/usr/bin/env python3
"""Find duplicate files by content, and optionally quarantine the extras.

WHY THIS AND NOT `fdupes -d`
============================

The photo library this is aimed at is 11,749 JPEGs spanning 2001-2010, existing
in exactly one place, on a drive whose USB bridge dropped off the bus and lost
writes on 2026-08-02. A tool that deletes as it goes is the wrong shape for that.
So:

  * Read-only unless you explicitly ask otherwise. The default run touches
    nothing and writes its report outside the drive being scanned.
  * --quarantine MOVES duplicates into one folder rather than deleting them.
    Nothing is destroyed; you review the folder and delete it yourself when you
    are satisfied. That final delete is the one step deliberately left manual.
  * Identity is full-content SHA-256, never filename, size or timestamp. Two
    photos that happen to share a byte count are not duplicates.

HOW IT DECIDES WHAT TO KEEP
===========================

Exactly one file in each group is kept, chosen by a deterministic ranking rather
than by whichever the filesystem happened to return first:

  1. A path under a date-named folder (2007-04-25) beats a camera dump folder
     (100CANON) or a junk folder (New Folder, whatever) -- the dated copy is the
     one that has been filed.
  2. Failing that, the shallower path.
  3. Failing that, the shorter name -- "birthday 041.jpg" over
     "birthday 041 (copy).jpg".
  4. Failing that, alphabetical, so repeat runs make the same choice.

Run it, read the report, then decide.

    python3 ~/find-duplicates.py /mnt/usbdrive/Pictures
    python3 ~/find-duplicates.py /mnt/usbdrive/Pictures --quarantine
"""

import argparse
import hashlib
import os
import re
import shutil
import sys
from collections import defaultdict

# Read in chunks: some of these files are 5MB+ and there are thousands of them,
# and this runs over NTFS-on-USB where memory pressure is the last thing wanted.
CHUNK = 1024 * 1024
# Cheap discriminator before committing to a full read of a large file.
HEAD_BYTES = 65536

DATE_DIR = re.compile(r'(19|20)\d{2}[-_]?\d{1,2}[-_]?\d{1,2}')
JUNK_DIR = re.compile(r'new folder|whatever|untitled|copy|temp|tmp', re.I)


def file_hash(path, limit=None):
    """SHA-256 of a file, or of its first `limit` bytes."""
    h = hashlib.sha256()
    try:
        with open(path, 'rb') as fh:
            if limit is not None:
                h.update(fh.read(limit))
            else:
                while True:
                    b = fh.read(CHUNK)
                    if not b:
                        break
                    h.update(b)
    except OSError as e:
        # A drive that throws EIO mid-scan is exactly the failure this library
        # already suffered once. Report it rather than silently skipping.
        print(f"  ! unreadable: {path}  ({e.strerror})", file=sys.stderr)
        return None
    return h.hexdigest()


def keeper_rank(path):
    """Lower sorts better. See the docstring for the reasoning."""
    parts = path.split(os.sep)
    parent = parts[-2] if len(parts) > 1 else ''
    return (
        0 if DATE_DIR.search(parent) else (2 if JUNK_DIR.search(parent) else 1),
        len(parts),
        len(os.path.basename(path)),
        path,
    )


def human(n):
    for unit in ('B', 'KB', 'MB', 'GB', 'TB'):
        if n < 1024:
            return f"{n:.0f}{unit}" if unit == 'B' else f"{n:.1f}{unit}"
        n /= 1024
    return f"{n:.1f}PB"


def main():
    ap = argparse.ArgumentParser(description="Find duplicate files by content.")
    ap.add_argument('root', help="directory to scan")
    ap.add_argument('--quarantine', action='store_true',
                    help="MOVE duplicates into a quarantine folder (still not a delete)")
    ap.add_argument('--quarantine-dir', default=None,
                    help="where to move them (default: <root>/../.duplicates-quarantine)")
    ap.add_argument('--ext', default='',
                    help="only consider these extensions, comma separated, e.g. jpg,jpeg,png")
    ap.add_argument('--min-size', type=int, default=1,
                    help="ignore files smaller than this many bytes (default 1, skips empties)")
    ap.add_argument('--report', default=os.path.expanduser('~/duplicates-report.txt'),
                    help="where to write the full report (kept OFF the scanned drive)")
    args = ap.parse_args()

    root = os.path.abspath(args.root)
    if not os.path.isdir(root):
        sys.exit(f"Not a directory: {root}")

    exts = {e.strip().lower().lstrip('.') for e in args.ext.split(',') if e.strip()}

    # --- pass 1: group by size. Files of different sizes cannot be identical,
    # and this avoids hashing anything that is already unique.
    print(f"Scanning {root} ...")
    by_size = defaultdict(list)
    total = 0
    for dirpath, dirnames, filenames in os.walk(root):
        # Never descend into our own quarantine, or Windows bookkeeping.
        dirnames[:] = [d for d in dirnames
                       if d not in ('.duplicates-quarantine',
                                    '$RECYCLE.BIN',
                                    'System Volume Information')]
        for fn in filenames:
            if exts and fn.rsplit('.', 1)[-1].lower() not in exts:
                continue
            p = os.path.join(dirpath, fn)
            try:
                st = os.stat(p)
            except OSError:
                continue
            if not os.path.isfile(p) or st.st_size < args.min_size:
                continue
            by_size[st.st_size].append(p)
            total += 1

    candidates = {s: ps for s, ps in by_size.items() if len(ps) > 1}
    print(f"  {total} files, {sum(len(p) for p in candidates.values())} share a size with something else")

    # --- pass 2: head hash, to cheaply split same-size-but-different files.
    by_head = defaultdict(list)
    for size, paths in candidates.items():
        for p in paths:
            h = file_hash(p, limit=HEAD_BYTES)
            if h:
                by_head[(size, h)].append(p)

    # --- pass 3: full hash, the only thing that actually proves identity.
    groups = defaultdict(list)
    for key, paths in by_head.items():
        if len(paths) < 2:
            continue
        for p in paths:
            h = file_hash(p)
            if h:
                groups[h].append(p)

    dupes = {h: ps for h, ps in groups.items() if len(ps) > 1}

    if not dupes:
        print("\nNo duplicates found.")
        return

    reclaim = 0
    lines = []
    for h, paths in sorted(dupes.items(), key=lambda kv: -os.path.getsize(kv[1][0])):
        paths.sort(key=keeper_rank)
        keep, extras = paths[0], paths[1:]
        size = os.path.getsize(keep)
        reclaim += size * len(extras)
        lines.append(f"{human(size)}  x{len(paths)}  sha256:{h[:16]}")
        lines.append(f"    KEEP  {keep}")
        for e in extras:
            lines.append(f"    dup   {e}")
        lines.append("")

    with open(args.report, 'w') as fh:
        fh.write(f"Duplicate report for {root}\n")
        fh.write(f"{len(dupes)} groups, {sum(len(p) - 1 for p in dupes.values())} redundant files, "
                 f"{human(reclaim)} reclaimable\n\n")
        fh.write("\n".join(lines))

    print(f"\n{len(dupes)} duplicate groups")
    print(f"{sum(len(p) - 1 for p in dupes.values())} redundant files")
    print(f"{human(reclaim)} would be reclaimed")
    print(f"\nFull report: {args.report}")
    print("\nLargest groups:")
    print("\n".join(lines[:24]))

    if not args.quarantine:
        print("Nothing was changed. Re-run with --quarantine to move the duplicates.")
        return

    qdir = args.quarantine_dir or os.path.join(os.path.dirname(root), '.duplicates-quarantine')
    os.makedirs(qdir, exist_ok=True)
    print(f"\nMoving duplicates to {qdir} ...")

    moved = failed = 0
    for h, paths in dupes.items():
        for src in paths[1:]:
            # Mirror the original path inside the quarantine so it is obvious
            # where each file came from, and so a restore is a plain copy back.
            rel = os.path.relpath(src, root)
            dst = os.path.join(qdir, rel)
            os.makedirs(os.path.dirname(dst), exist_ok=True)
            if os.path.exists(dst):
                base, ext = os.path.splitext(dst)
                dst = f"{base}.{h[:8]}{ext}"
            try:
                shutil.move(src, dst)
                moved += 1
            except OSError as e:
                print(f"  ! could not move {src}: {e.strerror}", file=sys.stderr)
                failed += 1

    print(f"\nMoved {moved} file(s)" + (f", {failed} failed" if failed else ""))
    print(f"""
Nothing has been deleted. Review {qdir},
and when you are satisfied, delete it yourself:

    rm -rf '{qdir}'

To undo instead, copy the tree back over the original:

    cp -an '{qdir}'/. '{root}'/
""")


if __name__ == '__main__':
    main()
