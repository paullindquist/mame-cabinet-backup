#!/usr/bin/env bash
# Make the cabinet boot silently -- no rainbow screen, no Ubuntu logo, no
# scrolling kernel text -- straight from power-on to the frontend.
#
# There are three separate things drawing on the screen during boot:
#
#   1. The Pi firmware's colour-test screen, before Linux exists at all.
#      Killed by disable_splash=1 in config.txt.
#   2. Plymouth's Ubuntu logo, from the `splash` kernel argument.
#      Killed by removing `splash`.
#   3. Kernel and systemd messages printed on tty1 -- the same console the
#      frontend takes over. Moved to tty3 so they never appear.
#
# It also stops NetworkManager-wait-online, which blocks boot for ~7 seconds
# waiting for wifi that nothing needs before the frontend starts.
#
# Run with:  sudo bash ~/hide-boot-splash.sh                # black screen
#            sudo bash ~/hide-boot-splash.sh --keep-splash  # show the theme
#            sudo bash ~/hide-boot-splash.sh --revert
#
# --keep-splash leaves the `splash` argument in place so Plymouth still runs and
# can draw the Mortal Kombat theme. Everything else -- firmware rainbow, kernel
# text on tty1, boot delay -- is suppressed either way. Without it, Plymouth
# never starts and any installed theme is simply never seen.
set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
    echo "Run this with sudo:  sudo bash ~/hide-boot-splash.sh" >&2
    exit 1
fi

# This box uses the Pi A/B tryboot layout, so the ACTIVE kernel command line is
# inside current/, not the top level. config.txt is read from the top level.
CMDLINE=/boot/firmware/current/cmdline.txt
CONFIG=/boot/firmware/config.txt
STAMP=.pre-silentboot

KEEP_SPLASH=false
[ "${1:-}" = "--keep-splash" ] && KEEP_SPLASH=true

if [ ! -f "$CMDLINE" ]; then
    echo "Expected $CMDLINE and it is not there. Stopping rather than" >&2
    echo "guessing -- getting this file wrong stops the Pi booting." >&2
    exit 1
fi

# ---------------------------------------------------------------- revert ----
if [ "${1:-}" = "--revert" ]; then
    for f in "$CMDLINE" "$CONFIG"; do
        if [ -f "${f}${STAMP}" ]; then
            cp -a "${f}${STAMP}" "$f"
            echo "restored $f"
        else
            echo "no backup for $f, leaving it alone"
        fi
    done
    systemctl enable NetworkManager-wait-online.service 2>/dev/null || true
    echo
    echo "Reverted. Reboot to apply."
    exit 0
fi

# ------------------------------------------------------------- back it up ---
for f in "$CMDLINE" "$CONFIG"; do
    [ -f "${f}${STAMP}" ] || cp -a "$f" "${f}${STAMP}"
done
echo "== Backed up (restore any time with --revert) =="
echo "   ${CMDLINE}${STAMP}"
echo "   ${CONFIG}${STAMP}"
echo

# ---------------------------------------------------------------- cmdline ---
# Read as one line, edit as words. Rebuilding word-by-word keeps this idempotent
# -- running it twice cannot duplicate an argument or corrupt root=.
OLD=$(tr -d '\n' < "$CMDLINE")
NEW=""
for word in $OLD; do
    case "$word" in
        splash)              continue ;;              # re-added below if kept
        console=tty1)        word=console=tty3 ;;      # keep boot text off tty1
        loglevel=*)          continue ;;               # re-added below
        vt.global_cursor_default=*) continue ;;
        logo.nologo)         continue ;;
    esac
    NEW="${NEW}${NEW:+ }${word}"
done
# quiet is usually already present; only add what is missing.
case " $NEW " in *" quiet "*) ;; *) NEW="$NEW quiet" ;; esac
NEW="$NEW loglevel=3 vt.global_cursor_default=0 logo.nologo"
# Plymouth only runs when `splash` is on the command line, so a themed boot
# needs it back. Stripping and re-adding rather than skipping the strip keeps
# the result identical no matter how many times this runs.
if [ "$KEEP_SPLASH" = true ]; then
    NEW="$NEW splash"
fi

# A cmdline missing root= is an unbootable machine. Refuse rather than write it.
case " $NEW " in
    *" root="*) ;;
    *) echo "Refusing to write: root= vanished from the command line." >&2
       exit 1 ;;
esac

printf '%s\n' "$NEW" > "$CMDLINE"
echo "== New kernel command line =="
echo "   $NEW"
echo

# ----------------------------------------------------------------- config ---
if ! grep -q '^disable_splash=1' "$CONFIG"; then
    cat >> "$CONFIG" <<'EOF'

# Arcade cabinet: suppress the firmware's colour-test screen at power-on.
disable_splash=1
EOF
    echo "== Added disable_splash=1 to config.txt =="
else
    echo "== disable_splash=1 already set =="
fi
echo

# ------------------------------------------------------------- boot speed ---
# Nothing on this machine needs the network before the frontend comes up; the
# nightly backup runs at 04:17, long after wifi is up. This is ~7s of the boot.
if systemctl is-enabled NetworkManager-wait-online.service >/dev/null 2>&1; then
    systemctl disable NetworkManager-wait-online.service
    echo "== Disabled NetworkManager-wait-online (was ~7s of the boot) =="
else
    echo "== NetworkManager-wait-online already disabled =="
fi

cat <<'EOF'

================================================================
Done. Reboot to see it:   sudo reboot

If anything goes wrong, tty2-tty6 still have normal logins
(Ctrl+Alt+F2) and SSH is untouched, so you are not locked out.
To undo everything:

    sudo bash ~/hide-boot-splash.sh --revert
    sudo reboot

One caveat worth knowing: this Pi uses the A/B tryboot layout,
so a future kernel update may regenerate current/cmdline.txt and
bring `splash` back. If the Ubuntu logo reappears after an
update, just run this script again.
================================================================
EOF
