#!/bin/bash
# fix-console-bleed.sh -- stop the tty3 login prompt showing through the frontend.
#
# Run as:  sudo /home/paul/fix-console-bleed.sh
#          sudo /home/paul/fix-console-bleed.sh --undo
#
# THE PROBLEM
# The kernel cmdline carries console=tty3, so tty3 is the ACTIVE VT and
# getty@tty3.service puts a login prompt on it. arcade.service correctly keeps
# getty off tty1 (Conflicts=getty@tty1.service) and sets TTYPath=/dev/tty1, but
# it never makes tty1 the active VT. So tty3 sits underneath everything, and
# each time MAME takes or releases DRM master the console is repainted for a
# moment -- the login prompt Paul sees when starting and exiting a game.
#
# It is not only cosmetic. The kernel delivers keystrokes to the ACTIVE VT, so
# the I-PAC has been typing into that login prompt all along: ^[[A ^[[B ^[[C
# ^[[D from the joystick (arrow-key escapes) and 1/5 from Start and Coin. The
# frontend is unaffected because it reads evdev directly, but a root login
# prompt should not be accumulating panel input.
#
# THE FIX
# Make tty1 -- the VT the frontend already owns and which has no getty -- the
# active one, and leave it silent: cursor off, echo off, blanking off, cleared
# including scrollback. Kernel messages still go to tty3 via console=tty3, so
# they stay off the visible VT; that part of the existing setup helps us.
#
# Installed as a drop-in so the original unit is untouched and --undo is a
# single file removal.

set -euo pipefail

DROPIN_DIR=/etc/systemd/system/arcade.service.d
DROPIN="$DROPIN_DIR/10-console-vt.conf"

die() { echo "ERROR: $*" >&2; exit 1; }
[[ $EUID -eq 0 ]] || die "must run with sudo"

if [[ "${1:-}" == "--undo" ]]; then
    rm -f "$DROPIN"
    rmdir "$DROPIN_DIR" 2>/dev/null || true
    systemctl daemon-reload
    echo "Removed $DROPIN. Restart the frontend to apply:"
    echo "    sudo systemctl restart arcade.service"
    exit 0
fi

mkdir -p "$DROPIN_DIR"
cat > "$DROPIN" <<'EOF'
# Make tty1 the active VT and keep it silent, so the tty3 login prompt is
# never what shows through during a DRM master handoff.
# The '+' prefix runs these as root; the service itself still runs as paul.
[Service]
ExecStartPre=+/usr/bin/chvt 1
ExecStartPre=+/bin/sh -c '\
    /usr/bin/setterm --blank 0 --powersave off --cursor off >/dev/tty1 || true; \
    /usr/bin/stty -F /dev/tty1 -echo || true; \
    printf "\033[2J\033[3J\033[H" >/dev/tty1 || true'
EOF

systemctl daemon-reload
echo "Wrote $DROPIN"
echo
echo "Apply it:"
echo "    sudo systemctl restart arcade.service"
echo
echo "Then confirm the active VT is tty1:"
echo "    cat /sys/class/tty/tty0/active"
echo
echo "To revert:  sudo /home/paul/fix-console-bleed.sh --undo"
