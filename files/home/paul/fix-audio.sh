#!/bin/bash
# fix-audio.sh -- give the cabinet sound.
#
# Run as:  sudo /home/paul/fix-audio.sh
#
# The problem: /dev/snd/* is root:audio mode 0660 and paul was in no such
# group, so PipeWire (which runs as paul) could not open either HDMI sound
# card. It fell back to a null sink, and MAME happily played into it.
#
# Normally systemd-logind's "uaccess" ACL would cover this -- the sound cards
# are tagged uaccess and assigned to seat0 -- but logind only grants that ACL
# to the ACTIVE session on the seat. The frontend's tty1 session sits at
# Active=no (the foreground VT is tty3), so the ACL is never applied.
#
# Rather than fight the VT, use the same mechanism that already makes the
# DISPLAY work: plain group membership. paul is in "video", which is why
# /dev/dri/card* opens; "audio" is the exact counterpart for /dev/snd/*.
# It is unconditional -- no dependency on which VT happens to be foreground,
# and it works identically for arcade.service, ssh and cron.

set -euo pipefail

USER_NAME=paul

die() { echo "ERROR: $*" >&2; exit 1; }
say() { echo -e "\n=== $* ==="; }

[[ $EUID -eq 0 ]] || die "must run with sudo"
id "$USER_NAME" >/dev/null 2>&1 || die "no such user: $USER_NAME"

say "Before"
echo "groups: $(id -nG "$USER_NAME")"
ls -l /dev/snd/control* /dev/snd/pcm* 2>/dev/null || echo "(no /dev/snd nodes)"

if id -nG "$USER_NAME" | tr ' ' '\n' | grep -qx audio; then
    say "Already in the audio group -- nothing to change"
else
    say "Adding $USER_NAME to the audio group"
    usermod -aG audio "$USER_NAME"
fi

say "After"
echo "groups: $(id -nG "$USER_NAME")"

# Group membership is baked into a process at login, so the already-running
# PipeWire/WirePlumber under user@1000.service still cannot see the cards.
# A reboot is the clean way to pick it up -- and this box reboots to the
# frontend anyway, so it costs nothing.
say "NEXT STEP"
cat <<'EOF'
Reboot to pick this up:

    sudo reboot

After it comes back, check that a real sink exists:

    wpctl status | sed -n '/Sinks:/,/Sources:/p'

You want a line naming the HDMI output instead of "Dummy Output".
Then test the speakers directly:

    speaker-test -D default -c 2 -t sine -f 440 -l 1

If that beeps, MAME will have sound too -- it needs no config change,
it is already talking to PipeWire correctly.
EOF
