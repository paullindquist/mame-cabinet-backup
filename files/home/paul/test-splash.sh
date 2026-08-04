#!/bin/bash
# test-splash.sh -- show the boot splash on demand, to find out whether it
# renders at all.
#
# Run as:  sudo /home/paul/test-splash.sh [seconds]
#
# The boot log cannot answer this. Plymouth starts at ~1.0s but there is no
# DRM device until vc4 loads at ~5.7s (config.txt sets disable_fw_kms_setup=1,
# so the firmware never makes a framebuffer and the monitor gets no signal at
# all until then). Plymouth quits at ~9.5s. After the panel's own sync delay
# that leaves a visible window of maybe two seconds, possibly none -- which is
# indistinguishable in the logs from the theme silently failing to render.
#
# This stops the frontend, brings Plymouth up by hand, and holds the splash so
# you can actually look at it.
#
#   Artwork appears -> the theme is fine, the problem is purely the boot-time
#                      window being too short. Fix by holding the splash until
#                      the frontend has drawn, not by touching the theme.
#   Black / nothing  -> the theme or renderer is at fault, and the boot timing
#                      is a red herring.
#
# The frontend is always restored on exit, including on Ctrl-C or error.

set -uo pipefail

SECS="${1:-10}"
[[ $EUID -eq 0 ]] || { echo "ERROR: must run with sudo" >&2; exit 1; }

restore() {
    echo
    echo "-- restoring frontend"
    plymouth quit >/dev/null 2>&1 || true
    pkill -x plymouthd >/dev/null 2>&1 || true
    systemctl start arcade.service
    echo "-- arcade.service: $(systemctl is-active arcade.service)"
}
trap restore EXIT INT TERM

echo "-- stopping frontend so it is not holding DRM master"
systemctl stop arcade.service
sleep 2

echo "-- default theme: $(readlink -f /etc/alternatives/default.plymouth)"
echo "-- starting plymouthd"
plymouthd --mode=boot --tty=/dev/tty1 || echo "   (plymouthd returned $?)"

echo "-- show-splash"
plymouth show-splash || echo "   (show-splash returned $?)"

echo "-- holding for ${SECS}s -- LOOK AT THE CABINET NOW"
sleep "$SECS"

echo "-- is plymouth alive and what does it think it is doing?"
plymouth --ping && echo "   ping: alive" || echo "   ping: NOT RUNNING"
