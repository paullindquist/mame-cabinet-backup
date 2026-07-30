#!/usr/bin/env python3
"""Generate MAME per-game input configs so MK titles match this cabinet's panel.

The panel is a 6-button MK3-style layout wired to the standard positional order
(top row = buttons 1/2/3, bottom row = buttons 4/5/6). MK games number their
buttons in hardware order, which does not line up with the printed labels -- MK2
for instance puts Low Kick on button 5 (the Run hole) and its redundant second
Block on button 6 (the Low Kick hole).

So we map by FUNCTION NAME to PANEL POSITION rather than by button number, which
gives the right result for every MK title without per-game guesswork:

      ( High Punch )  ( Block )  ( High Kick )      <- top row
         ( Low Punch )  ( Run )  ( Low Kick )       <- bottom row

We do NOT write the XML ourselves. Hand-authored <input> blocks get silently
discarded ("comments and unknown tags will be stripped"), so instead we drive
MAME's own Lua API -- set_input_seq on each field, then let MAME save the config
in whatever format it considers canonical. MAME also decides what to persist: a
binding that already matches the default is simply not recorded.

The game's ROMs must be present, since MAME cannot start a machine -- and so
cannot report or set its inputs -- without them.

Usage:  python3 mk-controls.py mk2 [mk3 umk3 ...]
        python3 mk-controls.py --dry-run mk2      # show what would be set
"""
import os
import subprocess
import sys
import tempfile

MAME = '/usr/games/mame'
CFG_DIR = os.path.expanduser('~/.mame/cfg')

# Panel position -> the key the I-PAC sends there, as (player 1, player 2).
# Player 1 verified against this cabinet on 2026-07-29; player 2 assumed to be
# wired to the same standard order and still unconfirmed.
POSITION_KEYS = {
    'top-left':      ('KEYCODE_LCONTROL', 'KEYCODE_A'),
    'top-middle':    ('KEYCODE_LALT',     'KEYCODE_S'),
    'top-right':     ('KEYCODE_SPACE',    'KEYCODE_Q'),
    'bottom-left':   ('KEYCODE_LSHIFT',   'KEYCODE_W'),
    'bottom-middle': ('KEYCODE_Z',        'KEYCODE_I'),
    'bottom-right':  ('KEYCODE_X',        'KEYCODE_K'),
}

# MK function (as MAME names it) -> panel position it should live on.
FUNCTION_POSITION = {
    'High Punch': 'top-left',
    'Block':      'top-middle',
    'High Kick':  'top-right',
    'Low Punch':  'bottom-left',
    'Run':        'bottom-middle',
    'Low Kick':   'bottom-right',
    # MK1/MK2 have no Run; their spare second Block sits in the Run hole where
    # it is harmless (pressing it just blocks).
    'Block 2':    'bottom-middle',
}

LUA_TEMPLATE = r'''
local WANT = {
%(entries)s
}
local inp = manager.machine.input
local seen = 0
for _, port in pairs(manager.machine.ioport.ports) do
    for fname, field in pairs(port.fields) do
        local tok = WANT[fname]
        if tok then
            local ok, err = pcall(function()
                field:set_input_seq("standard", inp:seq_from_tokens(tok))
            end)
            seen = seen + 1
            print(string.format("SET|%%s|%%s|%%s|%%s", fname, tok,
                                tostring(ok), tostring(err)))
        end
    end
end
print("COUNT|" .. seen)
manager.machine:exit()
'''


def wanted_bindings():
    """Every (MAME field name -> keycode) pair this cabinet wants."""
    want = {}
    for function, position in FUNCTION_POSITION.items():
        for player in (0, 1):
            want['P%d %s' % (player + 1, function)] = POSITION_KEYS[position][player]
    return want


def apply_to_game(game, want, dry_run=False):
    entries = "\n".join('    ["%s"] = "%s",' % (k, v) for k, v in sorted(want.items()))
    lua_src = LUA_TEMPLATE % {'entries': entries}

    with tempfile.TemporaryDirectory() as td:
        lua = os.path.join(td, 'remap.lua')
        with open(lua, 'w') as fh:
            fh.write(lua_src)

        # A dry run writes into a scratch directory so the real config is
        # untouched; otherwise MAME saves straight into ~/.mame/cfg.
        cfg_dir = os.path.join(td, 'cfg') if dry_run else CFG_DIR
        os.makedirs(cfg_dir, exist_ok=True)

        cmd = [MAME, game, '-video', 'none', '-sound', 'none',
               '-cfg_directory', cfg_dir,
               '-autoboot_script', lua, '-autoboot_delay', '1',
               '-seconds_to_run', '3']
        proc = subprocess.run(cmd, capture_output=True, text=True, timeout=180)

        applied, failed = [], []
        for line in proc.stdout.splitlines():
            if line.startswith('SET|'):
                _, fname, tok, ok, err = line.split('|')
                (applied if ok == 'true' else failed).append((fname, tok, err))

        if not applied and not failed:
            detail = (proc.stdout + proc.stderr).strip().splitlines()
            raise RuntimeError(detail[-1] if detail else 'MAME produced no output')

        written = os.path.join(cfg_dir, '%s.cfg' % game)
        body = ''
        if os.path.exists(written):
            with open(written, encoding='utf-8-sig') as fh:
                body = fh.read()

    return applied, failed, body


def main():
    games = [a for a in sys.argv[1:] if not a.startswith('-')]
    dry_run = '--dry-run' in sys.argv
    if not games:
        print(__doc__)
        return 1

    want = wanted_bindings()
    rc = 0
    for game in games:
        print("=== %s%s ===" % (game, ' (dry run)' if dry_run else ''))
        try:
            applied, failed, body = apply_to_game(game, want, dry_run=dry_run)
        except Exception as e:
            print("  SKIPPED: %s" % e)
            print("  (ROMs for %r are probably missing -- MAME must be able to "
                  "start the machine to set its inputs.)" % game)
            rc = 1
            continue

        for fname, tok, _ in sorted(applied):
            print("  set  %-16s -> %s" % (fname, tok))
        for fname, tok, err in sorted(failed):
            print("  FAIL %-16s -> %s  (%s)" % (fname, tok, err))
            rc = 1

        # MAME only persists bindings that differ from its defaults, so the
        # count here is the real measure of what changed.
        persisted = body.count('<newseq')
        print("  %d controls touched, %d persisted to config by MAME"
              % (len(applied), persisted))
        if not dry_run:
            print("  %s/%s.cfg" % (CFG_DIR, game))
        if persisted == 0:
            print("  NOTE: nothing persisted -- every binding already matched "
                  "MAME's defaults for this game.")
    return rc


if __name__ == '__main__':
    sys.exit(main())
