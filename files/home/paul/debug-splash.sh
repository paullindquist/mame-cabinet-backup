#!/bin/bash
# debug-splash.sh -- capture why the boot splash renders black.
#
# Run as:  sudo /home/paul/debug-splash.sh
#
# test-splash.sh showed a black screen, so this is not the boot-timing window
# -- Plymouth genuinely is not drawing. The daemon says almost nothing without
# --debug, so this runs it with debug logging and leaves the log behind for
# analysis. It also probes the two things most likely to be wrong:
#
#   1. Which renderer plugin it picks. plymouthd.defaults sets UseSimpledrm=1,
#      but config.txt has disable_fw_kms_setup=1 so no simpledrm device exists.
#      If it falls back to a renderer with no device, nothing is drawn.
#   2. Whether the fault is the mkcabinet theme or the renderer underneath it,
#      by running the stock 'spinner' theme afterwards for comparison. If
#      spinner also draws nothing, the theme is innocent.
#
# The default theme alternative is restored and the frontend restarted on exit,
# including on Ctrl-C or error.

set -uo pipefail

LOG=/home/paul/plymouth-debug.log
ORIG=$(readlink -f /etc/alternatives/default.plymouth)
[[ $EUID -eq 0 ]] || { echo "ERROR: must run with sudo" >&2; exit 1; }

cleanup() {
    echo
    echo "-- cleaning up"
    plymouth quit >/dev/null 2>&1 || true
    pkill -x plymouthd >/dev/null 2>&1 || true
    if [[ -n "$ORIG" && -e "$ORIG" ]]; then
        ln -sf "$ORIG" /etc/alternatives/default.plymouth
        echo "-- theme restored to $ORIG"
    fi
    chown paul:paul "$LOG" 2>/dev/null || true
    systemctl start arcade.service
    echo "-- arcade.service: $(systemctl is-active arcade.service)"
    echo "-- log left at $LOG"
}
trap cleanup EXIT INT TERM

run_theme() {
    local label="$1" secs="$2"
    echo
    echo "=============== $label ==============="
    plymouth quit >/dev/null 2>&1 || true
    pkill -x plymouthd >/dev/null 2>&1 || true
    sleep 1
    plymouthd --mode=boot --tty=/dev/tty1 --debug --debug-file="$LOG.$label" \
        || echo "   plymouthd exited $?"
    plymouth show-splash || echo "   show-splash exited $?"
    echo "   holding ${secs}s -- WATCH THE CABINET"
    sleep "$secs"
    echo "   renderer/device lines:"
    grep -iE 'renderer|/dev/dri|simpledrm|drm|no device|cannot|fail|error' "$LOG.$label" 2>/dev/null \
        | grep -viE 'debug|trying to' | head -15 | sed 's/^/     /'
}

echo "-- stopping frontend"
systemctl stop arcade.service
sleep 2

echo "-- DRM devices present:"; ls -l /dev/dri/ | sed 's/^/     /'

run_theme "mkcabinet" 8

if [[ -d /usr/share/plymouth/themes/spinner ]]; then
    ln -sf /usr/share/plymouth/themes/spinner/spinner.plymouth /etc/alternatives/default.plymouth
    run_theme "spinner" 8
    echo
    echo ">>> Did the SPINNER draw anything? That is the question that matters."
fi
