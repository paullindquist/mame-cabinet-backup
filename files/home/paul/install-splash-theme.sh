#!/usr/bin/env bash
# Install the cabinet's boot splash theme and make it the default.
#
# Replaces Ubuntu's logo with the game's title screen. Regenerate the artwork
# for a different game first if you want something else:
#
#     python3 ~/make-splash.py mk        # or any romname with artwork
#
# This also applies the quiet-boot settings, keeping `splash` on the kernel
# command line -- Plymouth only runs when it is there, so a themed boot and a
# fully silent boot are mutually exclusive. Run hide-boot-splash.sh with no
# arguments instead if you would rather have a plain black screen.
#
# Run with:  sudo bash ~/install-splash-theme.sh
#            sudo bash ~/install-splash-theme.sh --revert
set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
    echo "Run this with sudo:  sudo bash ~/install-splash-theme.sh" >&2
    exit 1
fi

THEME=mkcabinet
SRC=/home/paul/arcade/plymouth-theme
SPLASH=/home/paul/arcade/splash.png
DEST=/usr/share/plymouth/themes/$THEME

# ---------------------------------------------------------------- revert ----
if [ "${1:-}" = "--revert" ]; then
    echo "== Restoring Ubuntu's default theme =="
    # bgrt is Ubuntu's stock choice; fall back to spinner if it is gone.
    if [ -f /usr/share/plymouth/themes/bgrt/bgrt.plymouth ]; then
        plymouth-set-default-theme -R bgrt
    else
        plymouth-set-default-theme -R spinner
    fi
    rm -rf "$DEST"
    echo
    echo "Reverted. The quiet-boot settings are untouched -- undo those with:"
    echo "    sudo bash ~/hide-boot-splash.sh --revert"
    exit 0
fi

for f in "$SRC/$THEME.plymouth" "$SRC/$THEME.script" "$SPLASH"; do
    if [ ! -f "$f" ]; then
        echo "Missing $f" >&2
        echo "Generate the artwork first:  python3 ~/make-splash.py mk2" >&2
        exit 1
    fi
done

echo "== Installing theme to $DEST =="
install -d -m 755 "$DEST"
install -m 644 "$SRC/$THEME.plymouth" "$DEST/"
install -m 644 "$SRC/$THEME.script"   "$DEST/"
install -m 644 "$SPLASH"              "$DEST/splash.png"
ls -l "$DEST"
echo

echo "== Setting it as the default and rebuilding the initramfs =="
# -R is the important part: Plymouth runs from the initramfs, so a theme that is
# only in /usr/share is never actually seen at boot.
plymouth-set-default-theme -R "$THEME"
echo
echo "   active theme is now: $(plymouth-set-default-theme)"
echo

echo "== Applying quiet-boot settings (keeping splash so the theme shows) =="
bash /home/paul/hide-boot-splash.sh --keep-splash

cat <<'EOF'

================================================================
Reboot to see it:   sudo reboot

You should get: black screen, then the Mortal Kombat II title
screen, then the frontend. No rainbow, no Ubuntu logo, no text.

To go back to Ubuntu's splash:
    sudo bash ~/install-splash-theme.sh --revert

To change which game is on the splash:
    python3 ~/make-splash.py <romname>
    sudo bash ~/install-splash-theme.sh

Note the initramfs holds a COPY of the artwork, so re-running the
installer is required after changing it -- regenerating the PNG
alone will not change what you see at boot.
================================================================
EOF
