#!/usr/bin/env bash
# Grant paul passwordless sudo.
#
# WHY THIS EXISTS AS A SCRIPT
#
# The equivalent one-liner is long enough to wrap when pasted into a terminal,
# and a wrapped `sudo tee` silently writes nothing while the rest of the line is
# executed as a command. Doing it from a file removes that whole class of error.
#
# WHAT IT MEANS
#
# Passwordless sudo for paul means anything running as paul becomes root without
# a prompt -- including agents, scripts, and anything that gets in through a
# compromised session. On this machine that is bounded: the config is backed up
# nightly, the ROMs are replaceable, and the worst case is reflashing the card.
# Understand that before running it.
#
# SAFETY
#
# The file is written to a temp path, validated with `visudo -c` there, and only
# moved into /etc/sudoers.d if it parses. A malformed sudoers file locks the
# machine out of sudo entirely -- recovering from that means pulling the SD card
# and editing it on another computer. This ordering makes that impossible.
#
# Run with:  sudo bash ~/grant-sudo.sh
#            sudo bash ~/grant-sudo.sh --revert
set -euo pipefail

DEST=/etc/sudoers.d/99-paul-nopasswd
USERNAME=paul

if [ "$(id -u)" -ne 0 ]; then
    echo "Run this with sudo:  sudo bash ~/grant-sudo.sh" >&2
    exit 1
fi

# ---------------------------------------------------------------- revert ----
if [ "${1:-}" = "--revert" ]; then
    if [ ! -f "$DEST" ]; then
        echo "$DEST does not exist -- nothing to revert."
        exit 0
    fi
    rm -f "$DEST"
    echo "Removed $DEST"
    visudo -c >/dev/null && echo "sudoers still parses OK"
    echo "$USERNAME now needs a password for sudo again."
    exit 0
fi

TMP=$(mktemp /tmp/sudoers-paul.XXXXXX)
trap 'rm -f "$TMP"' EXIT

cat > "$TMP" <<EOF
# Passwordless sudo for $USERNAME.
#
# Added deliberately so an agent session with no controlling TTY can run
# privileged commands -- sudo refuses to prompt for a password without a TTY and
# fails with "interactive authentication is required" instead of asking.
#
# Remove with:  sudo bash ~/grant-sudo.sh --revert
$USERNAME ALL=(ALL) NOPASSWD: ALL
EOF
chmod 0440 "$TMP"

echo "== Validating before installing =="
# -c checks syntax, -f points it at the candidate file. If this fails the file
# never reaches /etc/sudoers.d, so a typo cannot lock anyone out.
if ! visudo -c -f "$TMP"; then
    echo >&2
    echo "Refusing to install -- the file does not parse. Nothing was changed." >&2
    exit 1
fi
echo

echo "== Installing to $DEST =="
install -o root -g root -m 0440 "$TMP" "$DEST"
echo "   written"
echo

echo "== Re-validating the whole sudoers set =="
visudo -c
echo

echo "== Verifying it actually works for $USERNAME =="
# `visudo -c` proves the file parses; it does NOT prove the rule takes effect.
# -n means "never prompt", so this fails rather than hanging if the rule is wrong.
# -k ignores any cached credential from the sudo that launched this script, which
# would otherwise make this succeed regardless.
if sudo -u "$USERNAME" sudo -n -k true 2>/dev/null; then
    echo "   [ok]   $USERNAME can now sudo without a password"
else
    echo "   [FAIL] the rule parsed but did not take effect" >&2
    echo "          check for a later file in /etc/sudoers.d overriding it:" >&2
    ls -la /etc/sudoers.d/ >&2
    exit 1
fi
echo

cat <<'EOF'
================================================================
Done. Keep this terminal open until you have confirmed sudo still
works in a NEW shell -- that is the safety net if anything is off.

To undo:  sudo bash ~/grant-sudo.sh --revert
================================================================
EOF
