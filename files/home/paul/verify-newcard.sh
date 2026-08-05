#!/bin/bash
# verify-newcard.sh -- check a freshly migrated SD card before trusting it.
#
# Run as:  sudo /home/paul/verify-newcard.sh /dev/sdX
#
# Mounts the new card READ-ONLY, checks that the things which actually make the
# cabinet work came across, and unmounts. Read-only is the point: this must not
# be able to damage what it is inspecting.
#
# What it is really looking for is the class of failure that boots far enough to
# look fine and then strands you -- wrong labels, a missing kernel cmdline, an
# arcade.service that did not come across -- rather than a corrupt copy, which
# rsync would already have complained about.

set -uo pipefail

TARGET="${1:-}"
MNT=/mnt/verifynew
PASS=0
FAIL=0

die()  { echo "ERROR: $*" >&2; exit 1; }
ok()   { echo "  PASS  $*"; PASS=$((PASS+1)); }
bad()  { echo "  FAIL  $*"; FAIL=$((FAIL+1)); }
head_() { echo; echo "=== $* ==="; }

[[ $EUID -eq 0 ]] || die "must run with sudo"
[[ -n $TARGET ]]  || die "usage: sudo $0 /dev/sdX"
[[ -b $TARGET ]]  || die "$TARGET is not a block device"

ROOTDEV=$(findmnt -no SOURCE / | sed 's/p\?[0-9]*$//')
[[ $TARGET == "$ROOTDEV"* ]] && die "$TARGET is the RUNNING card, not the new one"

if   [[ -b ${TARGET}1 ]]; then P1=${TARGET}1; P2=${TARGET}2
elif [[ -b ${TARGET}p1 ]]; then P1=${TARGET}p1; P2=${TARGET}p2
else die "cannot find partitions on $TARGET"; fi

# --- Labels, read from the filesystems themselves ---------------------------
head_ "Filesystem labels"
WANT_BOOT=$(lsblk -no LABEL "$(findmnt -no SOURCE /boot/firmware)")
WANT_ROOT=$(lsblk -no LABEL "$(findmnt -no SOURCE /)")
GOT_BOOT=$(blkid -s LABEL -o value "$P1" 2>/dev/null)
GOT_ROOT=$(blkid -s LABEL -o value "$P2" 2>/dev/null)
[[ $GOT_BOOT == "$WANT_BOOT" ]] && ok "boot label '$GOT_BOOT'" || bad "boot label is '$GOT_BOOT', fstab wants '$WANT_BOOT'"
[[ $GOT_ROOT == "$WANT_ROOT" ]] && ok "root label '$GOT_ROOT'" || bad "root label is '$GOT_ROOT', fstab wants '$WANT_ROOT'"

# --- Mount read-only --------------------------------------------------------
mkdir -p "$MNT"
mount -o ro "$P2" "$MNT"       || die "cannot mount $P2"
mkdir -p "$MNT/boot/firmware"  2>/dev/null || true
mount -o ro "$P1" "$MNT/boot/firmware" || die "cannot mount $P1"
cleanup() {
    umount "$MNT/boot/firmware" 2>/dev/null
    umount "$MNT" 2>/dev/null
    rmdir "$MNT" 2>/dev/null
}
trap cleanup EXIT

# Check the running card FIRST. Without this, a typo in the list below reports
# as a migration failure -- which is exactly what happened on the first run,
# where a wrong path for attract.cfg looked like the frontend config had been
# lost. A check that cannot tell "the copy is broken" from "my path is wrong"
# is worse than no check, because it spends your trust on a false alarm.
have() {
    if [[ ! -e "$1" ]]; then
        echo "  SKIP  $1"
        echo "        (absent on the RUNNING card too -- this check is wrong, not the copy)"
        return
    fi
    [[ -e "$MNT$1" ]] && ok "$1" || bad "MISSING: $1"
}

head_ "Boot chain"
# This Pi uses the A/B tryboot layout, so the ACTIVE kernel command line is the
# one inside current/, not the top-level copy. Getting only the latter would
# boot to something subtly different.
have /boot/firmware/config.txt
have /boot/firmware/current/cmdline.txt
have /boot/firmware/autoboot.txt
if [[ -r "$MNT/boot/firmware/current/cmdline.txt" ]]; then
    if diff -q /boot/firmware/current/cmdline.txt "$MNT/boot/firmware/current/cmdline.txt" >/dev/null; then
        ok "cmdline.txt identical to the running one"
    else
        bad "cmdline.txt DIFFERS from the running one"
        diff /boot/firmware/current/cmdline.txt "$MNT/boot/firmware/current/cmdline.txt" | sed 's/^/        /'
    fi
fi

head_ "fstab"
if diff -q /etc/fstab "$MNT/etc/fstab" >/dev/null; then
    ok "fstab identical"
else
    bad "fstab DIFFERS"; diff /etc/fstab "$MNT/etc/fstab" | sed 's/^/        /'
fi

head_ "The cabinet itself"
have /etc/systemd/system/arcade.service
have /etc/systemd/system/arcade.service.d/10-console-vt.conf
have /etc/systemd/system/multi-user.target.wants/arcade.service   # i.e. enabled
have /home/paul/arcade-boot.sh
have /home/paul/.attract/config/attract.cfg      # AM+ keeps this under config/
have /home/paul/.attract/emulators/mame.cfg
have /home/paul/.attract/romlists/mame.txt
have /home/paul/.mame/mame.ini
have /home/paul/.mame/swimmer.ini
have /home/paul/.mame/mspacman.ini
have /home/paul/arcade/shaders/scanline-light_rgb32_dir.fsh
have /home/paul/.config/wireplumber/wireplumber.conf.d/51-default-volume.conf
have /home/paul/.config/wireplumber/wireplumber.conf.d/52-hdmi-no-suspend.conf
have /etc/udev/rules.d/65-arcade-panel-no-powerkey.rules

head_ "Per-game input maps (the hard-won part)"
for f in /home/paul/.mame/cfg/*.cfg; do
    [[ -e $f ]] || continue
    if [[ -e "$MNT$f" ]] && cmp -s "$f" "$MNT$f"; then
        ok "$(basename "$f") (identical)"
    else
        bad "$(basename "$f") missing or differs"
    fi
done

head_ "ROMs"
for z in /home/paul/roms/*.zip; do
    [[ -e $z ]] || continue
    if [[ -e "$MNT$z" ]] && cmp -s "$z" "$MNT$z"; then
        ok "$(basename "$z")"
    else
        bad "$(basename "$z") missing or differs"
    fi
done

head_ "Backup deploy key (excluded from the git backup on purpose)"
have /home/paul/.ssh/id_cabinet_deploy

head_ "Mount points and swap"
for d in proc sys dev run tmp mnt/usbdrive; do
    [[ -d "$MNT/$d" ]] && ok "/$d exists" || bad "/$d MISSING (rsync -x leaves these empty)"
done
if [[ -f "$MNT/swapfile" ]]; then
    a=$(stat -c %s /swapfile 2>/dev/null || echo 0)
    b=$(stat -c %s "$MNT/swapfile")
    [[ $a == "$b" ]] && ok "swapfile $((b/1024/1024)) MiB" || bad "swapfile is $((b/1024/1024)) MiB, running card has $((a/1024/1024)) MiB"
    # A swapfile of the right size but never mkswap'd fails silently at boot.
    if file -s "$MNT/swapfile" 2>/dev/null | grep -qi 'swap file'; then
        ok "swapfile formatted (mkswap ran)"
    else
        bad "swapfile is NOT formatted -- mkswap did not run"
    fi
else
    bad "no /swapfile"
fi

head_ "Space"
df -h "$MNT" | tail -1 | awk '{print "  new card root: "$2" total, "$3" used, "$4" free"}'

echo
if (( FAIL == 0 )); then
    echo "ALL $PASS CHECKS PASSED -- safe to swap the card in."
else
    echo "$PASS passed, $FAIL FAILED -- do not swap the card in until these are resolved."
fi

echo
echo "IMPORTANT: shut down and remove the USB reader before booting the new card."
echo "Both cards now carry the labels '$WANT_ROOT' and '$WANT_BOOT', so with both"
echo "attached a boot could resolve LABEL= to the wrong one."

exit $(( FAIL > 0 ))
