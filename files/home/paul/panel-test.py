#!/usr/bin/env python3
"""Log which key each cabinet button sends, by reading the I-PAC's evdev stream.

The I-PAC is a keyboard encoder, so every button is a keystroke. Recording the
keystroke for each physical button tells us exactly how the harness is wired.

Watches every I-PAC event node at once, since some buttons (volume, admin) can
report on the System/Consumer Control interfaces rather than the keyboard one.
"""
import glob
import os
import select
import struct
import sys
import time

LOG = '/home/paul/panel-test.log'
EVENT_FMT = 'llHHi'          # timeval (2x long), type, code, value
EVENT_SIZE = struct.calcsize(EVENT_FMT)
EV_KEY = 0x01

KEYS = {
    2: '1', 3: '2', 4: '3', 5: '4', 6: '5', 7: '6', 8: '7', 9: '8',
    16: 'Q', 17: 'W', 18: 'E', 19: 'R', 20: 'T', 21: 'Y', 22: 'U', 23: 'I',
    24: 'O', 25: 'P', 28: 'Enter', 29: 'LCtrl', 30: 'A', 31: 'S', 32: 'D',
    33: 'F', 34: 'G', 35: 'H', 36: 'J', 37: 'K', 38: 'L', 42: 'LShift',
    44: 'Z', 45: 'X', 46: 'C', 47: 'V', 48: 'B', 49: 'N', 50: 'M',
    54: 'RShift', 56: 'LAlt', 57: 'Space', 58: 'CapsLock', 97: 'RCtrl',
    100: 'RAlt', 103: 'Up', 105: 'Left', 106: 'Right', 108: 'Down',
    1: 'Esc', 15: 'Tab',
}

duration = int(sys.argv[1]) if len(sys.argv) > 1 else 600

# Every event node belonging to the I-PAC.
paths = sorted(set(
    os.path.realpath(p) for p in glob.glob('/dev/input/by-id/*I-PAC*event*')
))
if not paths:
    paths = ['/dev/input/event1']

fds = {}
for p in paths:
    try:
        fds[os.open(p, os.O_RDONLY | os.O_NONBLOCK)] = p
    except OSError as e:
        print("could not open %s: %s" % (p, e), flush=True)

print("watching: %s" % ", ".join(fds.values()), flush=True)
print("listening for %d seconds — press buttons now" % duration, flush=True)

deadline = time.time() + duration
n = 0
with open(LOG, 'w', buffering=1) as log:
    log.write("# press-order  key  (device)\n")
    while time.time() < deadline:
        ready, _, _ = select.select(list(fds), [], [], 0.5)
        for fd in ready:
            try:
                data = os.read(fd, EVENT_SIZE)
            except (BlockingIOError, OSError):
                continue
            if not data or len(data) < EVENT_SIZE:
                continue
            _, _, etype, code, value = struct.unpack(EVENT_FMT, data)
            if etype == EV_KEY and value == 1:      # key down only
                n += 1
                name = KEYS.get(code, 'code_%d' % code)
                dev = os.path.basename(fds[fd])
                log.write("%2d  %-8s (%s)\n" % (n, name, dev))
                print("%2d  %-8s (%s)" % (n, name, dev), flush=True)

for fd in fds:
    os.close(fd)
print("done, %d presses recorded" % n, flush=True)
