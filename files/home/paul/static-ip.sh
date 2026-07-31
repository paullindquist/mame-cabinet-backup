#!/usr/bin/env bash
# Pin the cabinet to a fixed IP address.
#
# The wifi lease here is only an hour long, so the address can move after any
# outage or reboot -- which breaks anything that refers to the Pi by number.
#
# We keep the address it already has (192.168.0.105) rather than picking a new
# one. Two reasons: the router already associates that address with this
# machine, and choosing an arbitrary address risks landing inside the router's
# DHCP pool, where it can later be handed to some other device. That collision
# is intermittent and horrible to diagnose.
#
# IMPORTANT: this only WRITES the configuration. It does not reactivate the
# connection, because doing that over SSH drops the very session running the
# script. The change takes effect at the next reboot, or immediately with:
#
#     sudo bash ~/static-ip.sh --apply-now
#
# Run with:  sudo bash ~/static-ip.sh
#            sudo bash ~/static-ip.sh --apply-now
#            sudo bash ~/static-ip.sh --revert     # back to DHCP
set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
    echo "Run this with sudo:  sudo bash ~/static-ip.sh" >&2
    exit 1
fi

CON="Beulahbarker"
ADDR="192.168.0.105/24"
GATEWAY="192.168.0.1"
DNS="192.168.0.1,205.171.2.65"

if ! nmcli -t -f NAME connection show | grep -qx "$CON"; then
    echo "No connection named '$CON'. Available:" >&2
    nmcli -t -f NAME,TYPE connection show | sed 's/^/  /' >&2
    exit 1
fi

# ---------------------------------------------------------------- revert ----
if [ "${1:-}" = "--revert" ]; then
    echo "== Returning $CON to DHCP =="
    nmcli connection modify "$CON" \
        ipv4.method auto \
        ipv4.addresses "" \
        ipv4.gateway "" \
        ipv4.dns ""
    echo "   done -- takes effect on reconnect or reboot"
    exit 0
fi

echo "== Pinning $CON to $ADDR =="
# With method=manual NetworkManager stops asking DHCP for anything, including
# DNS, so the nameservers have to be set explicitly or name resolution dies.
nmcli connection modify "$CON" \
    ipv4.method manual \
    ipv4.addresses "$ADDR" \
    ipv4.gateway "$GATEWAY" \
    ipv4.dns "$DNS"

echo
echo "== Stored configuration =="
nmcli -t -f ipv4.method,ipv4.addresses,ipv4.gateway,ipv4.dns \
    connection show "$CON" | sed 's/^/   /'
echo

if [ "${1:-}" = "--apply-now" ]; then
    echo "== Applying immediately =="
    echo "   Your SSH session will freeze for a few seconds. The address is not"
    echo "   changing, so it should recover on its own; if it does not, just"
    echo "   reconnect -- the Pi is still at ${ADDR%/*}."
    echo
    # Detach so the reactivation survives this session being cut, otherwise the
    # connection can be left half-applied when the shell dies with it.
    systemd-run --unit=arcade-static-ip --description="Apply static IP" \
        nmcli connection up "$CON" >/dev/null 2>&1 || \
        nohup nmcli connection up "$CON" >/dev/null 2>&1 &
    echo "   reactivation dispatched"
else
    cat <<EOF
Not applied yet -- reactivating wifi would drop this SSH session.

    Apply on the next reboot (nothing more to do), or now with:
        sudo bash ~/static-ip.sh --apply-now

EOF
fi

cat <<'EOF'
================================================================
Worth doing as well: add a DHCP RESERVATION for this machine on
the router at http://192.168.0.1 -- same address, tied to the
Pi's wifi MAC. A static address set only on the Pi is invisible
to the router, which may still hand that address to another
device. The reservation makes the router agree, and belt-and-
braces costs nothing.

    Pi wifi MAC: see below

To undo:
    sudo bash ~/static-ip.sh --revert
================================================================
EOF
echo "Pi wifi MAC: $(cat /sys/class/net/wlan0/address)"
