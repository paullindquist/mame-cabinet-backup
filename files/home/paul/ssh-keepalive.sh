#!/bin/bash
# Stop idle SSH sessions from being silently dropped.
# Run with:  sudo bash ~/ssh-keepalive.sh
#
# sshd's ClientAliveInterval defaults to 0 (no probes), so an idle connection
# dies in a NAT table somewhere and sshd only notices on the next read. Sending
# a probe every 60s both detects breakage early and keeps the NAT mapping warm.
set -e

CONF=/etc/ssh/sshd_config.d/10-keepalive.conf

echo "== Writing $CONF =="
cat > "$CONF" <<'EOF'
# Probe the client every 60s; give up after 5 unanswered probes (5 minutes).
ClientAliveInterval 60
ClientAliveCountMax 5

# Also enable TCP-level keepalives.
TCPKeepAlive yes
EOF

echo "== Validating sshd config =="
if ! sshd -t; then
    echo "ERROR: config invalid -- removing $CONF and leaving sshd untouched."
    rm -f "$CONF"
    exit 1
fi
echo "Config OK."

echo "== Reloading sshd (existing sessions are NOT dropped) =="
systemctl reload ssh

echo
echo "== Effective values now =="
sshd -T | grep -iE 'clientaliveinterval|clientalivecountmax|tcpkeepalive'

echo
echo "Done. Your current session is unaffected; new connections get the keepalive."
