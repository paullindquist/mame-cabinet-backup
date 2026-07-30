#!/usr/bin/env bash
# Install Tailscale on the arcade cabinet.
#
# Adds Tailscale's own apt repo (Ubuntu does not package it), installs the
# daemon, and enables it. It deliberately does NOT run `tailscale up` -- that
# step prints a login URL you have to open in a browser, so it belongs in your
# hands, not in a script.
#
# Nothing here affects the arcade: tailscaled is a network daemon, it does not
# touch tty1, the display, or MAME.
#
# Run with:  sudo bash ~/tailscale-install.sh
set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
    echo "Run this with sudo:  sudo bash ~/tailscale-install.sh" >&2
    exit 1
fi

CODENAME=resolute        # Ubuntu 26.04; verified that Tailscale publishes this
KEYRING=/usr/share/keyrings/tailscale-archive-keyring.gpg
LIST=/etc/apt/sources.list.d/tailscale.list

echo "== Adding Tailscale's package signing key =="
# .noarmor.gpg is already in binary keyring form, so it drops straight in.
wget -qO "$KEYRING" \
    "https://pkgs.tailscale.com/stable/ubuntu/${CODENAME}.noarmor.gpg"

echo "== Adding the apt source =="
# signed-by pins this repo to that one key, so it cannot sign anything else on
# the system.
cat > "$LIST" <<EOF
deb [signed-by=${KEYRING}] https://pkgs.tailscale.com/stable/ubuntu ${CODENAME} main
EOF

echo "== Installing =="
apt-get update -qq
apt-get install -y tailscale

echo "== Enabling the daemon =="
systemctl enable --now tailscaled
systemctl is-active tailscaled

cat <<'EOF'

================================================================
Installed. One step left, and it has to be you -- it opens a
browser login:

    sudo tailscale up

That prints a URL. Open it on your phone or laptop, sign in, and
the cabinet joins your tailnet. After that:

    tailscale ip -4      # the cabinet's tailnet address
    tailscale status     # what else is on the tailnet

You can then SSH to the cabinet from anywhere with no ports open
on your router.

Note this does NOT route any of your household traffic. Tailscale
only carries traffic between devices you have explicitly signed
in. If you later want the cabinet to act as an exit node, that is
a separate opt-in on both ends -- ask me and I will set it up.

To undo all of this:
    sudo tailscale down
    sudo apt-get remove --purge tailscale
    sudo rm -f /etc/apt/sources.list.d/tailscale.list
================================================================
EOF
