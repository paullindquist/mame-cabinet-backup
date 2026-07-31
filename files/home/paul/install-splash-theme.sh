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
# Note on mechanism: Ubuntu 26.04 no longer ships plymouth-set-default-theme.
# The default theme is now an update-alternatives link, and the initramfs is
# copied into the A/B boot directory by flash-kernel afterwards.
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
ALT_LINK=/usr/share/plymouth/themes/default.plymouth
# Ubuntu's own bgrt theme registers at priority 110, so anything above that wins
# in auto mode; we also --set explicitly, which pins it regardless.
PRIORITY=200

# The initramfs the Pi actually boots is the copy inside the A/B directory, not
# the one update-initramfs writes. flash-kernel syncs them; we verify it did.
BOOT_INITRD=/boot/firmware/current/initrd.img

# ---------------------------------------------------------------- revert ----
if [ "${1:-}" = "--revert" ]; then
    echo "== Removing the theme from update-alternatives =="
    update-alternatives --remove default.plymouth "$DEST/$THEME.plymouth" || true
    update-alternatives --auto default.plymouth || true
    rm -rf "$DEST"
    echo "   default theme is now: $(readlink -f "$ALT_LINK")"
    echo
    echo "== Rebuilding the initramfs =="
    update-initramfs -u
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

echo "== Making it the default theme =="
update-alternatives --install "$ALT_LINK" default.plymouth \
    "$DEST/$THEME.plymouth" "$PRIORITY"
update-alternatives --set default.plymouth "$DEST/$THEME.plymouth"
echo "   default.plymouth -> $(readlink -f "$ALT_LINK")"
echo

echo "== Rebuilding the initramfs =="
# Plymouth runs from the initramfs, so a theme that exists only in /usr/share is
# never actually seen at boot. This is the step that matters.
BEFORE=$(md5sum "$BOOT_INITRD" 2>/dev/null | cut -d' ' -f1 || echo none)
update-initramfs -u
AFTER=$(md5sum "$BOOT_INITRD" 2>/dev/null | cut -d' ' -f1 || echo none)
echo

echo "== Verifying =="
# Three things have to be true, and none of them is implied by the commands
# above having exited zero.
ok=true

if [ "$(readlink -f "$ALT_LINK")" = "$DEST/$THEME.plymouth" ]; then
    echo "   [ok]   default.plymouth points at the cabinet theme"
else
    echo "   [FAIL] default.plymouth points at $(readlink -f "$ALT_LINK")"
    ok=false
fi

if lsinitramfs "$BOOT_INITRD" 2>/dev/null | grep -q "themes/$THEME/splash.png"; then
    echo "   [ok]   the splash image is inside the booted initramfs"
else
    echo "   [FAIL] the splash image is NOT in $BOOT_INITRD"
    ok=false
fi

if [ "$BEFORE" != "$AFTER" ]; then
    echo "   [ok]   flash-kernel refreshed $BOOT_INITRD"
else
    echo "   [WARN] $BOOT_INITRD is unchanged -- flash-kernel may not have run"
    ok=false
fi
echo

if [ "$ok" != true ]; then
    echo "Something did not take. Do NOT assume the splash will appear;" >&2
    echo "re-run this script or check the messages above." >&2
    exit 1
fi

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
