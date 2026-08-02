#!/usr/bin/env bash
# Stop the arcade control panel from being able to power the machine off.
#
# WHAT WENT WRONG
#
# The Ultimarc I-PAC 2 presents several USB HID interfaces, and one of them --
# "System Control" -- carries the HID Power/Sleep/Wake usages. systemd-logind
# automatically watches any input device udev has tagged `power-switch`, and its
# default HandlePowerKey is `poweroff`. So:
#
#     07:33:14  I-PAC 2 plugged in
#     07:33:14  logind: Watching system buttons on ... (I-PAC 2 System Control)
#     07:33:26  logind: Power key pressed short.
#     07:33:26  logind: Powering off...
#
# A button on the panel shut the cabinet down mid-session. It would do the same
# mid-game. The frontend already has a deliberate shutdown entry
# (exit_command = systemctl poweroff), so the panel does not also need to be a
# power switch.
#
# THE FIX
#
# Only ONE of the panel's input devices can actually emit KEY_POWER -- the
# "System Control" interface. Checked, not assumed:
#
#     event0  pwr_button                        KEY_POWER      <- the Pi's own
#     event1  Ultimarc I-PAC 2                  (none)         <- MAME reads this
#     event2  Ultimarc I-PAC 2 System Control   KEY_POWER ...  <- the culprit
#     event3  Ultimarc I-PAC 2 Consumer Control (none)
#
# So this disarms event2 and nothing else. HandlePowerKey=ignore would have been
# one line, but it is global -- it would also disable the Pi's own power button.
#
# MECHANISM, and why it is not the obvious one:
#
# The obvious fix is to remove the `power-switch` tag that makes logind watch the
# device. That does not work. udev 259 will not remove a tag once set: both
# `TAG-="power-switch"` and `TAG=""` leave it in place, silently. Verified by
# setting a marker variable in the same rule -- the marker appeared, proving the
# rule matched, while the tag survived.
#
# So instead this runs BEFORE 70-power-switch.rules and clears the property that
# rule matches on (ENV{ID_INPUT_KEY}), so the tag is never applied in the first
# place. Hence the 65- prefix: after 60-input-id.rules sets the property, before
# 70- consumes it.
#
# It is also split across TWO rules on purpose. ATTRS{idVendor} lives on the USB
# device and ATTRS{name} lives on the input device, and udev requires every
# ATTRS{} in a single rule to match the SAME parent -- combining them matches
# nothing, silently. The first rule marks the panel, the second narrows to the
# one interface.
#
# Also caps the journal. See the note further down.
#
# Run with:  sudo bash ~/fix-panel-powerkey.sh
#            sudo bash ~/fix-panel-powerkey.sh --revert
set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
    echo "Run this with sudo:  sudo bash ~/fix-panel-powerkey.sh" >&2
    exit 1
fi

VENDOR=d209
PRODUCT=0420
CULPRIT="Ultimarc I-PAC 2 System Control"
RULE=/etc/udev/rules.d/65-arcade-panel-no-powerkey.rules
OLDRULE=/etc/udev/rules.d/90-arcade-panel-no-powerkey.rules
JCONF=/etc/systemd/journald.conf.d/90-arcade-cap.conf

# ---------------------------------------------------------------- revert ----
if [ "${1:-}" = "--revert" ]; then
    echo "== Removing the udev rule and journal cap =="
    rm -f "$RULE" "$OLDRULE" "$JCONF"
    udevadm control --reload
    udevadm trigger --subsystem-match=input --action=add
    systemctl restart systemd-journald
    echo "   done -- reboot to fully restore; the panel can power the machine off again"
    exit 0
fi

# An earlier version of this script installed a 90- rule that used TAG-=. It does
# nothing, but leaving it would be misleading to whoever reads this next.
rm -f "$OLDRULE"

echo "== Writing $RULE =="
cat > "$RULE" <<EOF
# Arcade cabinet: the Ultimarc I-PAC 2 exposes an HID "System Control" interface
# carrying Power/Sleep/Wake. Without this, systemd-logind treats the panel as a
# power button, and a stray press powers the cabinet off mid-game. That is not
# hypothetical -- it happened on 2026-08-02, twelve seconds after the panel was
# plugged in.
#
# 65- matters: this must run after 60-input-id.rules sets ID_INPUT_KEY and before
# 70-power-switch.rules reads it. Removing the tag afterwards does NOT work --
# udev will not un-set a tag.
#
# Two rules, not one: ATTRS{idVendor} is on the USB device and ATTRS{name} is on
# the input device, and all ATTRS{} in a single rule must match the same parent.
ACTION=="remove", GOTO="arcade_panel_end"
SUBSYSTEM=="input", KERNEL=="event*", ATTRS{idVendor}=="$VENDOR", ATTRS{idProduct}=="$PRODUCT", ENV{ARCADE_PANEL}="1"
SUBSYSTEM=="input", KERNEL=="event*", ENV{ARCADE_PANEL}=="1", ATTRS{name}=="$CULPRIT", ENV{ID_INPUT_KEY}="", ENV{ID_INPUT_SWITCH}=""
LABEL="arcade_panel_end"
EOF
cat "$RULE" | sed 's/^/   /'
echo

echo "== Reloading udev =="
udevadm control --reload
# --action=add, not change: the properties this rule clears are set during add
# processing, and a change event will not re-evaluate them the same way.
udevadm trigger --subsystem-match=input --action=add
udevadm settle
echo

# The journal grew to 2.2G because attractplus logged "Error: No such device"
# 7.8 MILLION times in one boot, after this same panel was unplugged while the
# frontend held its file descriptor open. That is gigabytes of writes onto an SD
# card, which is the one component here with a limited write life. Neither a
# size cap nor rate limiting stops the spam, but together they bound the damage.
echo "== Capping the journal =="
install -d -m 755 /etc/systemd/journald.conf.d
cat > "$JCONF" <<'EOF'
# Arcade cabinet: bound journal writes to protect the SD card.
#
# A single runaway process (attractplus, when an input device vanishes out from
# under it) wrote 7.8 million lines and 2.2G in one boot. The rate limit throttles
# a flood like that; the size cap stops the card filling if one gets through.
[Journal]
SystemMaxUse=400M
RateLimitIntervalSec=30s
RateLimitBurst=2000
EOF
cat "$JCONF" | sed 's/^/   /'
systemctl restart systemd-journald
echo

echo "== Reclaiming the space already used =="
before=$(journalctl --disk-usage 2>/dev/null | grep -oE '[0-9.]+[KMGT]' | tail -1)
journalctl --vacuum-size=400M 2>&1 | tail -3 | sed 's/^/   /'
echo "   was: ${before:-?}   now: $(journalctl --disk-usage 2>/dev/null | grep -oE '[0-9.]+[KMGT]' | tail -1)"
echo

echo "== Verifying =="
# Verified with `udevadm test`, which re-evaluates the rules from scratch, rather
# than by reading the live udev database. The database still holds the tag that
# was applied before this rule existed, and udev cannot un-set it -- that stale
# entry only clears when the device is re-added at the next boot. Reading the db
# here would report a failure that is really just history.
ok=true

# Locate the culprit by CAPABILITY rather than by device number: event numbers are
# assigned in enumeration order and move when things are re-plugged.
CULPRIT_SYS=$(for d in /sys/class/input/event*; do
    [ -r "$d/device/name" ] || continue
    [ "$(cat "$d/device/name")" = "$CULPRIT" ] && echo "$d" && break
done)

if [ -z "$CULPRIT_SYS" ]; then
    echo "   [warn] '$CULPRIT' not present -- is the panel plugged in?"
    echo "          the rule is installed and will apply when it is"
else
    out=$(udevadm test --action=add "$CULPRIT_SYS" 2>&1)

    if printf '%s\n' "$out" | grep -q 'CURRENT_TAGS=.*power-switch'; then
        echo "   [FAIL] the System Control device would still be tagged power-switch"
        ok=false
    else
        echo "   [ok]   the System Control device is no longer tagged power-switch"
    fi

    # No ^ anchor: udevadm test indents its property lines.
    if printf '%s\n' "$out" | grep -q 'ARCADE_PANEL=1'; then
        echo "   [ok]   the rule matched the panel"
    else
        echo "   [FAIL] the rule did not match -- vendor/product or name changed?"
        ok=false
    fi
fi

# The Pi's own power button must still be armed. This is the whole reason for
# doing it this way instead of HandlePowerKey=ignore.
if udevadm test --action=add /sys/class/input/event0 2>&1 |
        grep -q 'CURRENT_TAGS=.*power-switch'; then
    echo "   [ok]   the Pi's own power button is untouched"
else
    echo "   [warn] the Pi's own power button lost its tag -- not intended"
fi
echo

if [ "$ok" != true ]; then
    echo "The rule did not evaluate as expected. Nothing is worse than before," >&2
    echo "but the panel can still power the machine off. Do not rely on it yet." >&2
    exit 1
fi

cat <<'EOF'
================================================================
The panel will no longer power the cabinet off -- from the next
boot. The tag applied before this rule existed is still in udev's
database and cannot be removed; it clears when the device is
re-added at boot.

Until then, the panel can still shut the machine down.

Deliberate shutdown is unaffected, both ways:
    - the frontend's exit entry  (systemctl poweroff)
    - the Pi's own power button

To undo:  sudo bash ~/fix-panel-powerkey.sh --revert
================================================================
EOF
