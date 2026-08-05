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
#
# ---------------------------------------------------------------------------
# SECOND CAUSE, found later: the login prompt came back, on a DIFFERENT VT.
#
# arcade.service sets SDL_VIDEODRIVER=kmsdrm, and MAME inherits it from
# Attract-Mode. Two SDL/KMSDRM programs cannot share one VT, so every time a
# game launches SDL claims a FREE vt and switches to it. logind's autovt
# mechanism (NAutoVTs=6 by default) then spawns getty@thatVT, and the moment
# MAME hands back DRM master the login prompt is what shows.
#
# The evidence was three gettys that were "disabled" yet "active", started
# within 30 seconds of each other on tty6, tty3 and tty2 -- nothing enabled
# them, logind spawned them in response to VT switches.
#
# Fixing which VT is active at STARTUP (above) cannot help, because the switch
# happens later, at game launch. The fix is to stop logind creating login
# prompts on VTs at all: NAutoVTs=0 and ReserveVT=0. A VT switch then reveals a
# blank console instead of a prompt.
#
# This removes local console login entirely. That is the right trade here
# because there is NO KEYBOARD attached to the cabinet -- the only thing that
# can type at a console is the control panel, which is exactly the problem.
# Access is over SSH/Tailscale, which is unaffected.

set -euo pipefail

DROPIN_DIR=/etc/systemd/system/arcade.service.d
DROPIN="$DROPIN_DIR/10-console-vt.conf"
LOGIND_DIR=/etc/systemd/logind.conf.d
LOGIND_CONF="$LOGIND_DIR/10-no-autovt.conf"

die() { echo "ERROR: $*" >&2; exit 1; }
[[ $EUID -eq 0 ]] || die "must run with sudo"

if [[ "${1:-}" == "--undo" ]]; then
    rm -f "$DROPIN" "$LOGIND_CONF"
    rmdir "$DROPIN_DIR" "$LOGIND_DIR" 2>/dev/null || true
    systemctl daemon-reload
    systemctl restart systemd-logind
    echo "Removed $DROPIN and $LOGIND_CONF."
    echo "Console logins are available again after a reboot."
    echo "Restart the frontend to apply the rest:"
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

mkdir -p "$LOGIND_DIR"
cat > "$LOGIND_CONF" <<'EOF'
# Stop logind spawning a login prompt on any VT. MAME's SDL/KMSDRM backend
# switches to a free VT on every game launch; without this, logind puts a getty
# there and that prompt is what bleeds through when the game starts and exits.
# No keyboard is attached, so a console login has no use here anyway.
[Login]
NAutoVTs=0
ReserveVT=0
EOF

systemctl daemon-reload

# Stop the gettys logind already spawned. Without this the prompts stay until
# a reboot, on exactly the VTs that are bleeding through right now.
for t in 2 3 4 5 6; do
    systemctl stop "getty@tty$t.service" 2>/dev/null || true
done
systemctl restart systemd-logind

echo "Wrote $DROPIN"
echo "Wrote $LOGIND_CONF"
echo
echo "Stopped stray gettys. Still running (should be none but tty1):"
systemctl list-units 'getty@*' --state=active --no-legend | sed 's/^/    /' || true
echo
echo "Apply the rest:"
echo "    sudo systemctl restart arcade.service"
echo
echo "Then launch and exit a game, and confirm no new getty appeared:"
echo "    systemctl list-units 'getty@*' --state=active"
echo
echo "NOTE: this disables console login. Access is via SSH only."
echo "To revert:  sudo /home/paul/fix-console-bleed.sh --undo"
