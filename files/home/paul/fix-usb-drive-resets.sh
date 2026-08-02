#!/usr/bin/env bash
# Stop the external Seagate drive dropping off the USB bus mid-write.
#
# WHAT HAPPENS WITHOUT THIS
#
#     11:16:53  usb 3-1: cmd cmplt err -71            <- USB protocol error
#     11:16:59  usb 3-1: reset SuperSpeed USB device
#     11:16:59  sd 1:0:0:0: [sdb] Attached SCSI disk  <- came back as a NEW node
#     11:17:20  Buffer I/O error on dev sda2 ... lost async page write
#
# The drive resets, re-enumerates under a different device node, and the existing
# mount is left pointing at a device that no longer exists. Every subsequent read
# and write returns EIO. Worse, "lost async page write" means dirty data in the
# page cache never reached the platter -- that is silent data loss, not just an
# inconvenience.
#
# WHY IT HAPPENS
#
# The drive is a Seagate 0bc2:2320 USB 3.0 bridge, running under the `uas` driver
# (USB Attached SCSI) at SuperSpeed. This bridge family has well-known UAS
# firmware bugs; err -71 (EPROTO) under sustained write load is the classic
# signature.
#
# Ruled out, rather than assumed:
#   - Power. usb_max_current_enable=1 in the devicetree, meaning the firmware
#     detected a PSU capable of full USB current, and there are no undervoltage
#     or throttling events anywhere in the log.
#   - Filesystem damage. ntfsfix processed the volume cleanly afterwards.
#
# THE FIX
#
# usb-storage.quirks=0bc2:2320:u tells the kernel to disable UAS for this one
# device, falling back to the older bulk-only transport. It costs throughput --
# expect roughly a third less on large sequential transfers -- and buys a drive
# that stays attached. For an archive drive on an arcade cabinet that is a good
# trade; a drive that vanishes mid-write is worth nothing at any speed.
#
# Scoped by vendor:product, so any other USB storage keeps using UAS.
#
# Set on the kernel command line rather than in /etc/modprobe.d because
# usb-storage can load from the initramfs, before modprobe.d is readable.
#
# Run with:  sudo bash ~/fix-usb-drive-resets.sh
#            sudo bash ~/fix-usb-drive-resets.sh --revert
set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
    echo "Run this with sudo:  sudo bash ~/fix-usb-drive-resets.sh" >&2
    exit 1
fi

QUIRK="usb-storage.quirks=0bc2:2320:u"

# This Pi uses the A/B tryboot layout, so there is more than one cmdline.txt and
# each boot slot has its own. Editing only the active one means the change is
# silently discarded the next time flash-kernel promotes new/ over current/.
CMDLINES=()
for f in /boot/firmware/cmdline.txt \
         /boot/firmware/current/cmdline.txt \
         /boot/firmware/new/cmdline.txt; do
    [ -f "$f" ] && CMDLINES+=("$f")
done

if [ ${#CMDLINES[@]} -eq 0 ]; then
    echo "No cmdline.txt found -- unexpected boot layout, refusing to guess." >&2
    exit 1
fi

rewrite() {
    local f="$1" line
    line=$(tr -d '\n' < "$f")

    # Strip any existing copy of the setting so re-running is idempotent and a
    # stale value cannot linger alongside a new one.
    line=$(printf '%s' "$line" | sed -E 's/[[:space:]]*usb-storage\.quirks=[^[:space:]]*//g')

    if [ "${2:-}" != "--remove" ]; then
        line="$line $QUIRK"
    fi

    # Collapse whitespace: the Pi bootloader takes the whole file as one line and
    # is unforgiving about stray blanks.
    line=$(printf '%s' "$line" | tr -s ' ' | sed -E 's/^ +| +$//g')

    # Never write a command line that lost root= -- that produces an unbootable
    # card that has to be fixed on another machine.
    if ! printf '%s' "$line" | grep -q 'root='; then
        echo "   [FAIL] root= vanished while rewriting $f -- leaving it alone" >&2
        return 1
    fi

    cp -a "$f" "$f.bak"
    printf '%s\n' "$line" > "$f"
    echo "   updated $f"
}

if [ "${1:-}" = "--revert" ]; then
    echo "== Removing the quirk =="
    for f in "${CMDLINES[@]}"; do rewrite "$f" --remove; done
    echo
    echo "Reverted. Reboot for it to take effect -- UAS will be used again."
    exit 0
fi

echo "== Adding $QUIRK to every boot slot =="
for f in "${CMDLINES[@]}"; do rewrite "$f"; done
echo

echo "== Resulting command lines =="
for f in "${CMDLINES[@]}"; do
    echo "   $f:"
    fold -w 92 -s "$f" | sed 's/^/      /'
done
echo

echo "== Verifying =="
ok=true
for f in "${CMDLINES[@]}"; do
    grep -q -- "$QUIRK" "$f" || { echo "   [FAIL] quirk missing from $f"; ok=false; }
    grep -q 'root='   "$f" || { echo "   [FAIL] root= missing from $f";  ok=false; }
done
$ok && echo "   [ok]   all $((${#CMDLINES[@]})) boot slot(s) carry the quirk, root= intact"
echo

if [ "$ok" != true ]; then
    echo "Something is wrong. Restore from the .bak files before rebooting." >&2
    exit 1
fi

cat <<'EOF'
================================================================
Takes effect at the next reboot. Afterwards, confirm the driver
actually changed -- this is the check that matters:

    lsusb -t | grep -i 'Mass Storage'

Before:  Driver=uas
After:   Driver=usb-storage

If it still says uas, the quirk did not apply and the drive will
keep dropping.

Expect large transfers to be noticeably slower. That is the trade.

To undo:  sudo bash ~/fix-usb-drive-resets.sh --revert
================================================================
EOF
