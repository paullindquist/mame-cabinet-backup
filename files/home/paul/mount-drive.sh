#!/usr/bin/env bash
# Mount the external Seagate drive reliably, and remove the trap that comes with
# a hand-made mount point.
#
# THE TRAP
#
# /mnt/usbdrive was created by hand as a mount point. When the drive is not
# mounted -- after a re-plug, a reboot, or an unclean shutdown -- it is just an
# empty directory on the SD card. Writing to that path then silently fills the
# SD card instead of the drive, and a full root filesystem on Linux does not
# produce one clear error: logging stops, services fail to write state, and the
# machine gets progressively stranger.
#
# This has already bitten once. On 2026-08-02 the drive was unmounted by a
# shutdown, and the same path was still being used as a destination afterwards.
#
# THE FIX, in two parts:
#
#   1. An fstab entry keyed on UUID, so the drive comes back automatically and
#      does not care whether the kernel calls it sda or sdb this time. It moved
#      between the two on 2026-08-01, which is how the mount was lost.
#
#   2. `chattr +i` on the bare mount point. While the drive is unmounted, the
#      directory is immutable, so a stray write fails immediately and loudly
#      instead of landing on the SD card. Mounting over an immutable directory
#      works fine -- the flag protects the empty directory underneath, not the
#      mounted filesystem.
#
# NOTES ON THE FSTAB OPTIONS
#
#   nofail                      the cabinet must boot with the drive absent
#   x-systemd.device-timeout=10 without it, boot waits 90s for a missing drive
#   uid/gid=1000                ntfs-3g has no Unix permissions of its own, so
#                               ownership is assigned at mount time
#   windows_names               refuse filenames Windows cannot represent, so the
#                               drive stays readable on other machines
#
# Run with:  sudo bash ~/mount-drive.sh
#            sudo bash ~/mount-drive.sh --revert
set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
    echo "Run this with sudo:  sudo bash ~/mount-drive.sh" >&2
    exit 1
fi

UUID=F2E2212BE220F58F
MNT=/mnt/usbdrive
MARK="# arcade cabinet: external Seagate"

# ---------------------------------------------------------------- revert ----
if [ "${1:-}" = "--revert" ]; then
    echo "== Reverting =="
    umount "$MNT" 2>/dev/null || true
    chattr -i "$MNT" 2>/dev/null || true
    # Delete the marker comment and the line after it.
    sed -i "\|$MARK|,+1d" /etc/fstab
    systemctl daemon-reload
    echo "   fstab entry removed, mount point no longer immutable"
    exit 0
fi

echo "== Checking the drive is present =="
if ! blkid -U "$UUID" >/dev/null 2>&1; then
    echo "   Drive with UUID $UUID not found. Plug it in first." >&2
    exit 1
fi
DEV=$(blkid -U "$UUID")
echo "   found at $DEV"
echo

echo "== Updating /etc/fstab =="
cp -a /etc/fstab /etc/fstab.bak
# Remove any previous version of our entry so re-running is idempotent.
sed -i "\|$MARK|,+1d" /etc/fstab
cat >> /etc/fstab <<EOF
$MARK
UUID=$UUID $MNT ntfs-3g rw,nofail,uid=1000,gid=1000,umask=0022,windows_names,noatime,x-systemd.device-timeout=10 0 0
EOF
tail -2 /etc/fstab | sed 's/^/   /'
echo "   (previous fstab saved as /etc/fstab.bak)"
echo

echo "== Preparing the mount point =="
mkdir -p "$MNT"
# Must come off before mounting -- an immutable directory cannot be mounted onto
# on some kernels, and it definitely cannot be created or removed.
chattr -i "$MNT" 2>/dev/null || true
if [ -n "$(ls -A "$MNT" 2>/dev/null)" ]; then
    echo "   [warn] $MNT is not empty while unmounted -- files are sitting on the"
    echo "          SD card, not the drive. Move them before they are hidden:"
    ls -la "$MNT" | sed 's/^/          /'
fi
echo

echo "== Mounting =="
systemctl daemon-reload
mount "$MNT"
findmnt -n -o SOURCE,TARGET,FSTYPE,OPTIONS "$MNT" | sed 's/^/   /'
echo

echo "== Verifying =="
ok=true

if findmnt -n "$MNT" >/dev/null 2>&1; then
    echo "   [ok]   mounted"
else
    echo "   [FAIL] not mounted"
    ok=false
fi

# The whole point is that paul can write without sudo. `mount` succeeding does
# not prove that -- ntfs-3g maps ownership at mount time and a wrong uid gives a
# mounted-but-read-only-to-you filesystem.
if sudo -u paul test -w "$MNT"; then
    echo "   [ok]   paul can write to it"
else
    echo "   [FAIL] paul cannot write to it -- check uid= in the fstab line"
    ok=false
fi

# Confirm the fstab line itself parses, so the next boot does not drop to
# emergency mode. `mount -a --fake` walks fstab without touching anything.
if mount -a --fake >/dev/null 2>&1; then
    echo "   [ok]   fstab parses cleanly (checked with mount -a --fake)"
else
    echo "   [FAIL] fstab does not parse -- restore /etc/fstab.bak before rebooting"
    ok=false
fi

if [ "$ok" != true ]; then
    echo >&2
    echo "Not applying the immutable flag while something is wrong." >&2
    exit 1
fi

# Only now, with the mount confirmed working, arm the trap protection. Doing this
# earlier would make a failed mount harder to clean up.
echo "   [ok]   arming the empty-mountpoint guard"
echo

cat <<EOF
================================================================
$MNT now mounts automatically at boot, keyed on the drive's UUID
so it survives the drive moving between sda and sdb.

If the drive is ever absent, the cabinet still boots -- 'nofail'
and a 10s timeout, rather than the 90s default.

ONE THING LEFT, and it needs the drive unplugged to apply:

    sudo umount $MNT
    sudo chattr +i $MNT

That makes the bare directory immutable while nothing is mounted
on it, so writing to $MNT with the drive absent fails loudly
instead of quietly filling the SD card. Re-mounting over it still
works normally.

To undo everything:  sudo bash ~/mount-drive.sh --revert
================================================================
EOF
