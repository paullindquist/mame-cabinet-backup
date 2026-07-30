#!/bin/bash
# Boot-to-arcade setup: systemd unit on tty1 + disable GDM
# Run with:  sudo bash ~/arcade-boot.sh
# NOTE: does NOT purge GNOME -- GDM is only disabled, so the desktop can be
# restored with:  sudo systemctl set-default graphical.target && sudo systemctl enable gdm
set -e

SRC=/home/paul/src/attractplus
BIN=/usr/local/bin/attractplus

if [ ! -x "$SRC/attractplus" ]; then
    echo "ERROR: $SRC/attractplus not found. The build must succeed first."
    exit 1
fi

echo "== Installing Attract-Mode Plus to /usr/local =="
make -C "$SRC" USE_DRM=1 install

if [ ! -x "$BIN" ]; then
    echo "ERROR: install did not produce $BIN"
    exit 1
fi
echo "Installed: $($BIN --version 2>&1 | head -1)"
echo

echo "== Writing /etc/systemd/system/arcade.service =="
cat > /etc/systemd/system/arcade.service <<'UNIT'
[Unit]
Description=Arcade frontend (Attract-Mode Plus)
After=systemd-user-sessions.service getty@tty1.service
Conflicts=getty@tty1.service

[Service]
Type=simple
User=paul
Group=paul
PAMName=login
WorkingDirectory=/home/paul
Environment=HOME=/home/paul
Environment=SDL_VIDEODRIVER=kmsdrm
ExecStart=/usr/local/bin/attractplus
Restart=always
RestartSec=2
TTYPath=/dev/tty1
TTYReset=yes
TTYVHangup=yes
StandardInput=tty
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
UNIT

echo "== Disabling GDM (not removing it) =="
# On Ubuntu, gdm.service reports "disabled" while GDM still starts via the
# display-manager.service alias, so `disable gdm` alone short-circuits and
# does nothing. Disable both names; the multi-user default below is what
# actually keeps the desktop from coming up.
systemctl disable gdm3 2>/dev/null || true
systemctl disable gdm 2>/dev/null || true

echo "== Default boot target -> multi-user (no desktop) =="
systemctl set-default multi-user.target

echo "== Enabling arcade.service =="
systemctl daemon-reload
systemctl enable arcade.service

echo
echo "== Done. NOT started yet -- start it manually to test: =="
echo "     sudo systemctl start arcade"
echo "   Stop it and get the console back with:"
echo "     sudo systemctl stop arcade"
echo
echo "SSH is untouched; tty2-tty6 remain normal login consoles."
