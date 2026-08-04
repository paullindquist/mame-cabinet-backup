#!/bin/bash
# fix-splash.sh -- make the boot splash actually render.
#
# Run as:  sudo /home/paul/fix-splash.sh
#          sudo /home/paul/fix-splash.sh --undo
#
# THE CAUSE (from plymouthd --debug, not guesswork)
#   add_console: console /dev/tty3 found!
#   create_dev : serial consoles detected, managing them with details forced
#   create_dev : creating devices for (renderer type: 4294967295) (terminal: /dev/tty3)
#   create_tex : adding text display for terminal /dev/tty3
#
# Plymouth reads /sys/class/tty/console/active and treats ANY console that is
# not tty0 as a serial console. The cmdline carries console=tty3, so Plymouth
# decides this is a headless serial box, forces the text-only "details" theme
# and creates no graphical renderer at all -- renderer type 4294967295 is (-1),
# meaning none. It then runs perfectly happily for the whole boot drawing
# nothing, which is why the journal showed no errors.
#
# The theme was never at fault: mkcabinet is installed correctly, the
# default.plymouth alternative points at it, splash.png is 1280x960 matching
# the mode exactly, and both the theme and Plymouth's drm.so renderer are
# present in the initramfs. The stock spinner theme failed identically.
#
# THE FIX
# plymouth.ignore-serial-consoles tells Plymouth to disregard serial consoles
# when choosing a renderer. console=tty3 stays, so kernel messages continue to
# land on tty3 and off the visible VT -- which is what that setting was for.
#
# Requires a reboot: this is a kernel command line change.

set -euo pipefail

CMDLINE=/boot/firmware/current/cmdline.txt
FLAG=plymouth.ignore-serial-consoles
BACKUP="$CMDLINE.pre-splash-fix"

die() { echo "ERROR: $*" >&2; exit 1; }
[[ $EUID -eq 0 ]] || die "must run with sudo"
[[ -f $CMDLINE ]] || die "$CMDLINE not found (config.txt sets os_prefix=current/, so this is the live one)"

if [[ "${1:-}" == "--undo" ]]; then
    [[ -f $BACKUP ]] || die "no backup at $BACKUP"
    cp -v "$BACKUP" "$CMDLINE"
    echo "Reverted. Reboot to apply."
    exit 0
fi

if grep -q "$FLAG" "$CMDLINE"; then
    echo "$FLAG is already present -- nothing to do."
    exit 0
fi

# The cmdline must stay a SINGLE line; the firmware ignores anything after a
# newline, which would silently drop root= and leave an unbootable system.
[[ $(wc -l < "$CMDLINE") -le 1 ]] || die "$CMDLINE has more than one line; refusing to touch it"

cp -v "$CMDLINE" "$BACKUP"
printf '%s %s\n' "$(tr -d '\n' < "$BACKUP")" "$FLAG" > "$CMDLINE"

echo
echo "--- before ---"; cat "$BACKUP"
echo "--- after ----"; cat "$CMDLINE"
echo

grep -q 'root=LABEL=writable' "$CMDLINE" || die "root= vanished -- restoring";
[[ $(wc -l < "$CMDLINE") -eq 1 ]] || die "result is not one line -- restore from $BACKUP"

echo "Looks sane. Reboot to apply:"
echo "    sudo reboot"
echo
echo "To revert:  sudo /home/paul/fix-splash.sh --undo   (then reboot)"
