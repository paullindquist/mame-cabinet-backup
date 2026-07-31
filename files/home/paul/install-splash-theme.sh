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

# The initramfs the Pi actually boots is the copy inside the A/B boot set, not
# the one update-initramfs writes -- flash-kernel copies it across. And it does
# NOT overwrite current/: it stages a whole new set in new/, which the bootloader
# tries at the next reboot ("will boot twice") and only then promotes over
# current/. So the file to verify is new/ when it exists, current/ otherwise.
# Checking current/ right after an install always fails, and that failure means
# nothing.
if [ -f /boot/firmware/new/initrd.img ]; then
    BOOT_INITRD=/boot/firmware/new/initrd.img
    BOOT_SLOT="new (staged; promoted on next boot)"
else
    BOOT_INITRD=/boot/firmware/current/initrd.img
    BOOT_SLOT="current"
fi

# ---------------------------------------------------------------- revert ----
if [ "${1:-}" = "--revert" ]; then
    echo "== Removing the theme from update-alternatives =="
    update-alternatives --remove default.plymouth "$DEST/$THEME.plymouth" || true
    update-alternatives --auto default.plymouth || true
    rm -rf "$DEST"
    rm -f /etc/dracut.conf.d/20-arcade-splash.conf
    # Drop the initramfs-tools line too, in case an earlier version added one.
    if [ -f /etc/initramfs-tools/modules ]; then
        sed -i '/^# Arcade cabinet: the Pi/,+2d' /etc/initramfs-tools/modules
    fi
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

# Quiet boot comes FIRST, deliberately. It is the part that matters most and the
# part that always works; the splash is cosmetic and depends on Plymouth finding
# a display. Doing it the other way round meant a failed splash check aborted the
# script before the quiet settings were ever applied -- losing the thing that was
# actually wanted in order to protect the thing that was optional.
echo "== Applying quiet-boot settings (keeping splash so the theme can show) =="
bash /home/paul/hide-boot-splash.sh --keep-splash
echo

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

echo "== Ensuring the display driver is in the initramfs =="
# Plymouth needs a KMS device to draw on. On this Pi the HDMI output is driven
# by vc4, which is NOT in the default initramfs -- so plymouthd starts several
# seconds before any display exists, falls back to a renderer that cannot draw,
# and you get a flickering screen with boot text and no splash.
#
# Ubuntu 26.04 builds initramfs images with DRACUT, not initramfs-tools;
# /usr/sbin/update-initramfs is only a compatibility shim. That means
# /etc/initramfs-tools/modules is dead config here and is silently ignored --
# drivers have to be requested through /etc/dracut.conf.d instead.
DRACUT_CONF=/etc/dracut.conf.d/20-arcade-splash.conf
install -d -m 755 /etc/dracut.conf.d
cat > "$DRACUT_CONF" <<'EOF'
# Arcade cabinet: the Pi's HDMI driver, forced into the initramfs so the boot
# splash has a display to render on before switch-root. The surrounding spaces
# are required -- dracut appends this verbatim to its driver list.
add_drivers+=" vc4 "
EOF
echo "   wrote $DRACUT_CONF"
# Remove the initramfs-tools entry if an earlier version of this script added
# one; it does nothing here and is just misleading.
if [ -f /etc/initramfs-tools/modules ]; then
    sed -i '/^# Arcade cabinet: the Pi/,+2d' /etc/initramfs-tools/modules
fi
echo

echo "== Rebuilding the initramfs =="
# Plymouth runs from the initramfs, so a theme that exists only in /usr/share is
# never actually seen at boot. This is the step that matters.
update-initramfs -u
echo

# Re-resolve the slot AFTER the rebuild: flash-kernel creates new/ as part of
# this step, so a value computed beforehand can point at the wrong file.
if [ -f /boot/firmware/new/initrd.img ]; then
    BOOT_INITRD=/boot/firmware/new/initrd.img
    BOOT_SLOT="new (staged; promoted on next boot)"
else
    BOOT_INITRD=/boot/firmware/current/initrd.img
    BOOT_SLOT="current"
fi

echo "== Verifying =="
echo "   boot slot: $BOOT_SLOT"
# Neither of these is implied by the commands above having exited zero.
ok=true

if [ "$(readlink -f "$ALT_LINK")" = "$DEST/$THEME.plymouth" ]; then
    echo "   [ok]   default.plymouth points at the cabinet theme"
else
    echo "   [FAIL] default.plymouth points at $(readlink -f "$ALT_LINK")"
    ok=false
fi

if lsinitramfs "$BOOT_INITRD" 2>/dev/null | grep -q "themes/$THEME/splash.png"; then
    echo "   [ok]   the splash image is inside $BOOT_INITRD"
else
    echo "   [FAIL] the splash image is NOT in $BOOT_INITRD"
    ok=false
fi

# Without this the theme is present but never drawn -- the failure mode that
# looks like flickering and boot text rather than an obvious error.
if lsinitramfs "$BOOT_INITRD" 2>/dev/null | grep -q '/vc4\.ko'; then
    echo "   [ok]   the vc4 display driver is in the initramfs"
else
    echo "   [FAIL] vc4 is NOT in the initramfs -- Plymouth will have no screen"
    ok=false
fi
echo

if [ "$ok" != true ]; then
    cat >&2 <<'WARN'
The SPLASH did not fully take -- do not expect artwork at boot.

The quiet-boot settings were applied before this point and are fine,
so the boot will still be silent. If you would rather stop chasing the
splash and just have a black screen, remove Plymouth from the picture
entirely:

    sudo bash ~/install-splash-theme.sh --revert
    sudo bash ~/hide-boot-splash.sh          # note: no --keep-splash
    sudo reboot
WARN
    exit 1
fi

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
