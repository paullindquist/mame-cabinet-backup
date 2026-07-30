#!/usr/bin/env python3
"""Watch for USB devices appearing or disappearing.

Reads /sys/bus/usb/devices directly rather than shelling out to lsusb, which is
AppArmor-confined here and floods the kernel log with denials.

Usage:  python3 usb-watch.py [seconds]
"""
import os
import sys
import time

ROOT = '/sys/bus/usb/devices'


def read(path):
    try:
        with open(path) as fh:
            return fh.read().strip()
    except OSError:
        return ''


def snapshot():
    devs = {}
    for name in os.listdir(ROOT):
        base = os.path.join(ROOT, name)
        vid, pid = read(base + '/idVendor'), read(base + '/idProduct')
        if not vid or not pid:
            continue                      # interfaces and root hubs
        devs[name] = {
            'id': '%s:%s' % (vid, pid),
            'product': read(base + '/product') or '(no product string)',
            'manufacturer': read(base + '/manufacturer') or '(no manufacturer)',
            'maxpower': read(base + '/bMaxPower') or '?',
            'speed': read(base + '/speed') or '?',
        }
    return devs


def describe(port, d):
    return ("%s  %s  %s / %s  (draws %s, %s Mbps)"
            % (port, d['id'], d['manufacturer'], d['product'],
               d['maxpower'], d['speed']))


def main():
    duration = int(sys.argv[1]) if len(sys.argv) > 1 else 300
    prev = snapshot()

    print("=== currently attached ===")
    for port, d in sorted(prev.items()):
        print("  " + describe(port, d))
    print("\nwatching for %d seconds -- plug/unplug now\n" % duration, flush=True)

    deadline = time.time() + duration
    events = 0
    while time.time() < deadline:
        time.sleep(0.4)
        cur = snapshot()
        for port in sorted(set(cur) - set(prev)):
            events += 1
            print("[%s] PLUGGED IN   %s" % (time.strftime('%H:%M:%S'),
                                            describe(port, cur[port])), flush=True)
        for port in sorted(set(prev) - set(cur)):
            events += 1
            print("[%s] REMOVED      %s" % (time.strftime('%H:%M:%S'),
                                            describe(port, prev[port])), flush=True)
        prev = cur

    print("\ndone, %d event(s) seen" % events)
    if events == 0:
        print("Nothing enumerated. If the cord was plugged in during this "
              "window, it is not a USB data device -- it only draws power.")


if __name__ == '__main__':
    sys.exit(main())
