#!/bin/bash
# sd-migrate.sh — clone this running cabinet onto a larger SD card.
#
# Run as:  sudo /home/paul/sd-migrate.sh /dev/sdX
# where /dev/sdX is the NEW card in a USB reader (NOT a partition, NOT /dev/sda).
#
# Safe by design: it only ever writes to the target you name, and the card
# currently running the cabinet is never touched. If anything goes wrong you
# still have the old card, unmodified, to fall back to.

set -euo pipefail

TARGET="${1:-}"
NEWROOT=/mnt/newroot
BOOT_MB=512

die() { echo "ERROR: $*" >&2; exit 1; }
say() { echo -e "\n=== $* ==="; }

[[ $EUID -eq 0 ]] || die "must run with sudo"
[[ -n $TARGET ]] || die "usage: sudo $0 /dev/sdX   (the new card's whole disk)"
[[ -b $TARGET ]] || die "$TARGET is not a block device"

# --- Safety interlocks -------------------------------------------------------
# Order matters: identify dangerous devices before complaining about naming,
# so a mistyped /dev/mmcblk0 reports the real reason it was refused.
ROOTDEV=$(findmnt -no SOURCE / | sed 's/p\?[0-9]*$//')
[[ $TARGET == "$ROOTDEV"* ]] && die "$TARGET holds the running root filesystem — that is the card you are migrating AWAY from"
[[ $TARGET == /dev/mmcblk0* ]] && die "$TARGET is the card currently running this system"

# NEVER identify a drive by its kernel name. USB devices are enumerated in
# whatever order they answer on the bus, and the Seagate has already moved from
# sda to sdc once — an earlier version of this script hardcoded "/dev/sda is the
# ROM drive", which by then was pointing at the blank card instead. Ask what is
# actually mounted, and ask fstab what the ROM drive's UUID is.
while read -r part; do
    [[ -n $part ]] || continue
    # || true matters: findmnt exits non-zero when the device is NOT mounted,
    # which is the normal case, and pipefail would abort the whole script.
    mp=$(findmnt -rno TARGET -S "/dev/$part" 2>/dev/null | paste -sd, - || true)
    [[ -n $mp ]] && die "/dev/$part on $TARGET is mounted at $mp — refusing"
done < <(lsblk -lno NAME "$TARGET")

# Catches the ROM drive even when it happens to be unmounted.
ROM_UUID=$(awk '!/^[[:space:]]*#/ && $2=="/mnt/usbdrive" {print $1}' /etc/fstab | sed 's/^UUID=//')
if [[ -n ${ROM_UUID:-} ]]; then
    rompart=$(blkid -U "$ROM_UUID" 2>/dev/null || true)
    if [[ -n $rompart ]]; then
        romdisk="/dev/$(lsblk -no PKNAME "$rompart" | head -1)"
        [[ $TARGET == "$romdisk" ]] && die "$TARGET is the ROM drive (UUID $ROM_UUID)"
    fi
fi

# Use the kernel's own view rather than guessing from a trailing digit, which
# would wrongly reject a legitimately mmcblk-named target.
DEVTYPE=$(lsblk -dno TYPE "$TARGET" 2>/dev/null || echo unknown)
[[ $DEVTYPE == disk ]] || die "$TARGET is type '$DEVTYPE', not a whole disk; give e.g. /dev/sdb"

TRAN=$(lsblk -dno TRAN "$TARGET")
[[ $TRAN == usb ]] || die "$TARGET is not USB-attached (got '$TRAN'); refusing"

SIZE_B=$(blockdev --getsize64 "$TARGET")
SIZE_G=$((SIZE_B / 1024 / 1024 / 1024))
(( SIZE_G >= 100 )) || die "$TARGET is only ${SIZE_G}GiB; expected a 128GB card"
(( SIZE_G <= 250 )) || die "$TARGET is ${SIZE_G}GiB — too big to be the card you meant"

USED_G=$(df -B1 --output=used / | tail -1 | awk '{printf "%.0f", $1/2^30}')

# --- Learn the labels rather than hardcoding them ----------------------------
# fstab mounts / and /boot/firmware by LABEL=, and /dev/disk/by-label entries
# are created verbatim — LABEL=system-boot does NOT match a partition labelled
# SYSTEM-BOOT. This script used to hardcode the uppercase form, which would have
# booted the firmware fine (it reads the partition directly) and then dropped to
# an emergency shell when systemd could not mount /boot/firmware. Read the
# labels off the running card so they match whatever fstab expects.
BOOT_LABEL=$(lsblk -no LABEL "$(findmnt -no SOURCE /boot/firmware)")
ROOT_LABEL=$(lsblk -no LABEL "$(findmnt -no SOURCE /)")
[[ -n $BOOT_LABEL && -n $ROOT_LABEL ]] || die "could not read current filesystem labels"
grep -q "LABEL=$ROOT_LABEL[[:space:]]" /etc/fstab || die "fstab does not mount / by LABEL=$ROOT_LABEL; check it by hand"

# Match the existing swapfile rather than assuming 1GiB.
if [[ -f /swapfile ]]; then
    SWAP_MB=$(( $(stat -c %s /swapfile) / 1024 / 1024 ))
else
    SWAP_MB=0
fi

say "About to ERASE $TARGET"
lsblk -o NAME,SIZE,FSTYPE,LABEL,MODEL "$TARGET"
echo
echo "  Target size:     ${SIZE_G} GiB"
echo "  Data to copy:    ${USED_G} GiB (current root, minus swap)"
echo "  This card:       $ROOTDEV  (will NOT be touched)"
echo "  Labels to apply: $BOOT_LABEL (boot), $ROOT_LABEL (root)"
echo "  Swapfile:        ${SWAP_MB} MiB"
echo
read -rp "Type ERASE to continue: " confirm
[[ $confirm == ERASE ]] || die "aborted"

# --- Unmount anything already on the target ---------------------------------
say "Unmounting any existing partitions on $TARGET"
for p in $(lsblk -lno NAME "$TARGET" | tail -n +2); do
    umount -f "/dev/$p" 2>/dev/null || true
done
swapoff "$TARGET"* 2>/dev/null || true

# --- Partition: MBR, matching the current layout ----------------------------
# p1 = 512MiB FAT32, bootable, type c   -> system-boot
# p2 = remainder ext4                   -> writable
say "Partitioning $TARGET"
wipefs -a "$TARGET"
sfdisk "$TARGET" <<EOF
label: dos
unit: sectors

start=2048, size=$((BOOT_MB * 2048)), type=c, bootable
start=$((2048 + BOOT_MB * 2048)), type=83
EOF

partprobe "$TARGET"; sleep 3

# Handle both /dev/sdb1 and /dev/mmcblk1p1 naming
if [[ -b ${TARGET}1 ]]; then P1=${TARGET}1; P2=${TARGET}2
elif [[ -b ${TARGET}p1 ]]; then P1=${TARGET}p1; P2=${TARGET}p2
else die "cannot find new partitions on $TARGET"; fi

# --- Format. Temporary labels: two filesystems both labelled "writable"
# would make LABEL= lookups ambiguous while the copy runs. Renamed at the end.
say "Formatting $P1 (boot) and $P2 (root)"
mkfs.vfat -F 32 -n SYSBOOTNEW "$P1"
mkfs.ext4 -F -L newroot-tmp "$P2"

# --- Mount ------------------------------------------------------------------
say "Mounting new card at $NEWROOT"
mkdir -p "$NEWROOT"
mount "$P2" "$NEWROOT"
mkdir -p "$NEWROOT/boot/firmware"
mount "$P1" "$NEWROOT/boot/firmware"

# --- Copy root. -x keeps rsync on the root filesystem, so /boot/firmware,
# /mnt/usbdrive, /proc, /sys and /dev are all skipped automatically.
say "Copying root filesystem (${USED_G} GiB — this is the slow part)"
rsync -aHAXx --info=progress2 --numeric-ids \
    --exclude='/swapfile' \
    --exclude='/lost+found' \
    --exclude='/var/tmp/*' \
    --exclude='/var/cache/apt/archives/*.deb' \
    / "$NEWROOT/"

# Recreate the mount points -x left empty
mkdir -p "$NEWROOT"/{proc,sys,dev,run,tmp,mnt/usbdrive}
chmod 1777 "$NEWROOT/tmp"

# --- Copy the firmware/boot partition (vfat: no perms/owners to preserve) ---
say "Copying /boot/firmware"
rsync -rltD --info=progress2 --delete \
    --exclude='.Spotlight-V100' \
    --exclude='.fseventsd' \
    /boot/firmware/ "$NEWROOT/boot/firmware/"

# --- Swap file --------------------------------------------------------------
if (( SWAP_MB > 0 )); then
    say "Recreating ${SWAP_MB}MiB swapfile"
    dd if=/dev/zero of="$NEWROOT/swapfile" bs=1M count="$SWAP_MB" status=none
    chmod 600 "$NEWROOT/swapfile"
    mkswap "$NEWROOT/swapfile" >/dev/null
fi

# --- Finish -----------------------------------------------------------------
say "Flushing to card"
sync
umount "$NEWROOT/boot/firmware"
umount "$NEWROOT"

say "Applying final labels"
# fatlabel warns about lowercase labels; it stores them correctly regardless,
# and lowercase is what fstab asks for on an Ubuntu image.
fatlabel "$P1" "$BOOT_LABEL"
e2label "$P2" "$ROOT_LABEL"
e2fsck -fp "$P2" || true
sync

# --- Verify before declaring success ----------------------------------------
# The failure this catches is a silent one: wrong labels boot the firmware fine
# and then strand you in an emergency shell, with no obvious cause on screen.
say "Verifying"
partprobe "$TARGET" 2>/dev/null || true; sleep 2
NEW_BOOT=$(blkid -s LABEL -o value "$P1" 2>/dev/null || true)
NEW_ROOT=$(blkid -s LABEL -o value "$P2" 2>/dev/null || true)
ok=true
[[ $NEW_BOOT == "$BOOT_LABEL" ]] || { echo "  MISMATCH: boot label is '$NEW_BOOT', fstab wants '$BOOT_LABEL'"; ok=false; }
[[ $NEW_ROOT == "$ROOT_LABEL" ]] || { echo "  MISMATCH: root label is '$NEW_ROOT', fstab wants '$ROOT_LABEL'"; ok=false; }
if $ok; then
    echo "  labels OK:  $P1 = $NEW_BOOT,  $P2 = $NEW_ROOT"
else
    die "labels are wrong — the new card would drop to an emergency shell. Fix with: fatlabel $P1 $BOOT_LABEL ; e2label $P2 $ROOT_LABEL"
fi

say "DONE"
echo "New card is ready. To use it:"
echo "  1. sudo shutdown -h now"
echo "  2. Swap in the new card (keep the old one — it's untouched)"
echo "  3. Power on. It should boot straight to the cabinet."
echo "  4. Confirm the new size with:  df -h /"
echo
echo "If it does not boot, put the old card back. Nothing was changed on it."
