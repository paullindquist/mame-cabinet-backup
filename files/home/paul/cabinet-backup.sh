#!/usr/bin/env bash
# Snapshot everything needed to rebuild this arcade cabinet, into a git repo.
#
# The cabinet lives on an SD card. If that card dies, the ROMs are replaceable
# but the two weeks of configuration are not -- the per-game input maps, the
# scanline overlays, the emulator paths, the systemd unit that makes it boot to
# the frontend. All of that is small text. This keeps it in version control so
# a card failure costs an afternoon instead of a rebuild from memory.
#
# Deliberately NOT backed up:
#   roms/          large, and replaceable from wherever you got them
#   arcade/{snap,flyer,...}   re-downloadable with get-artwork.py
#   .attract/{layouts,plugins,modules,cache,scraper}   ships with Attract-Mode
#
# Needs no sudo -- every file it reads is readable as paul.
#
# Usage:  bash ~/cabinet-backup.sh            # snapshot and commit
#         bash ~/cabinet-backup.sh --dry-run  # show what would change
set -uo pipefail

REPO=/home/paul/cabinet-config
LOG=/home/paul/cabinet-backup.log
DRY_RUN=false
[ "${1:-}" = "--dry-run" ] && DRY_RUN=true

exec > >(tee -a "$LOG") 2>&1
echo "=== $(date '+%Y-%m-%d %H:%M:%S') ==="

# Paths to snapshot. Each is copied into the repo under the same layout it has
# on disk, so restoring is a plain copy back rather than a puzzle.
FILES=(
    /home/paul/.mame/mame.ini
    /home/paul/.mame/ui.ini
    /home/paul/.mame/plugin.ini
    /home/paul/arcade-boot.sh
    /home/paul/arcade-deps.sh
    /home/paul/mk-controls.py
    /home/paul/panel-test.py
    /home/paul/get-artwork.py
    /home/paul/usb-watch.py
    /home/paul/ssh-keepalive.sh
    /home/paul/cabinet-backup.sh
    /home/paul/tailscale-install.sh
    /home/paul/github-remote.sh
    # ssh client config only -- the deploy key itself is deliberately NOT here.
    # A private key in a backup is a private key in every copy of the backup.
    /home/paul/.ssh/config
    /home/paul/hide-boot-splash.sh
    /home/paul/static-ip.sh
    /home/paul/install-splash-theme.sh
    /home/paul/fix-panel-powerkey.sh
    /home/paul/mount-drive.sh
    /home/paul/grant-sudo.sh
    /home/paul/make-splash.py
    /home/paul/arcade/splash.png
    /etc/systemd/system/arcade.service
    /etc/ssh/sshd_config.d/10-keepalive.conf
    # Stops the control panel from acting as a power switch -- without this the
    # cabinet powers off on a stray button press.
    /etc/udev/rules.d/65-arcade-panel-no-powerkey.rules
    /etc/systemd/journald.conf.d/90-arcade-cap.conf
    # The external drive mount. Keyed on UUID so it survives sda/sdb renumbering.
    /etc/fstab
    # Boot config. This Pi uses the A/B tryboot layout, so the ACTIVE kernel
    # command line is the one inside current/, not the top level.
    /boot/firmware/current/cmdline.txt
    /boot/firmware/config.txt
)

DIRS=(
    /home/paul/.mame/cfg                 # per-game input maps -- the hard-won part
    /home/paul/.attract/config
    /home/paul/.attract/emulators
    /home/paul/.attract/romlists
    /home/paul/arcade/artwork            # custom scanline overlays
    /home/paul/arcade/plymouth-theme     # boot splash theme
)

mkdir -p "$REPO"
if [ ! -d "$REPO/.git" ]; then
    echo "-- initialising repo at $REPO"
    git -C "$REPO" init -q -b main
    # Repo-local identity so this never touches a global git config.
    git -C "$REPO" config user.name  "arcade cabinet"
    git -C "$REPO" config user.email "paul.lindquist@gmail.com"
fi

cat > "$REPO/.gitignore" <<'EOF'
# Never let ROMs or bulk artwork into this repo -- it is meant to stay small
# enough to push over the cabinet's wifi in a second.
*.zip
*.7z
*.chd
EOF

copy_in() {
    # Mirror an absolute path into the repo, keeping its directory structure.
    local src="$1" dest="$REPO/files$1"
    if [ ! -r "$src" ]; then
        echo "   SKIP (unreadable): $src"
        return
    fi
    mkdir -p "$(dirname "$dest")"
    cp -a "$src" "$dest"
}

echo "-- collecting files"
rm -rf "$REPO/files"
for f in "${FILES[@]}"; do copy_in "$f"; done
for d in "${DIRS[@]}"; do
    if [ ! -d "$d" ]; then echo "   SKIP (missing): $d"; continue; fi
    mkdir -p "$REPO/files$d"
    # Only real config; skip our own .bak/.orig scratch copies and any binaries.
    find "$d" -maxdepth 1 -type f \
        ! -name '*.bak' ! -name '*.orig' ! -name '*.pre-*' \
        -print0 2>/dev/null |
    while IFS= read -r -d '' f; do
        cp -a "$f" "$REPO/files$d/" 2>/dev/null
    done
done

# A snapshot of the surrounding system state, so the configs above are
# interpretable a year from now on a fresh card.
echo "-- writing manifest"
{
    echo "# Arcade cabinet manifest"
    echo
    # No timestamp here on purpose -- git records when each snapshot was taken,
    # and a date in the file would make every nightly run look like a change,
    # so the "nothing changed" check below would never fire.
    echo "Host: $(hostname)"
    echo
    echo '## System'
    echo '```'
    echo "model:      $(tr -d '\0' < /proc/device-tree/model 2>/dev/null)"
    echo "os:         $(lsb_release -ds 2>/dev/null)"
    echo "kernel:     $(uname -r)"
    echo "default:    $(systemctl get-default)"
    echo "arcade svc: $(systemctl is-enabled arcade 2>&1) / $(systemctl is-active arcade 2>&1)"
    echo '```'
    echo
    echo '## Emulator'
    echo '```'
    echo "mame:       $(/usr/games/mame -help 2>/dev/null | head -1)"
    echo "attractplus:$(attractplus --version 2>/dev/null | head -1)"
    echo '```'
    echo
    echo '## ROM sets present'
    echo '```'
    ls -1 /home/paul/roms 2>/dev/null || echo '(none)'
    echo '```'
    echo
    echo '## Incomplete ROM sets (parked outside the rompath)'
    echo '```'
    ls -1 /home/paul/roms-incomplete 2>/dev/null || echo '(none)'
    echo '```'
    echo
    echo '## Hand-installed packages relevant to the build'
    echo '```'
    for p in mame mame-data attractplus tailscale; do
        v=$(dpkg-query -W -f='${Version}' "$p" 2>/dev/null) &&
            echo "$p $v" || echo "$p (not from dpkg)"
    done
    echo '```'
    echo
    echo '## Nightly backup job (paul'"'"'s user crontab, not systemd)'
    echo '```'
    crontab -l 2>/dev/null || echo '(no crontab)'
    echo '```'
    echo
    echo '## Restoring'
    echo
    echo 'Files here mirror their absolute paths under `files/`. To restore:'
    echo
    echo '```'
    echo 'sudo cp -a files/etc/. /etc/'
    echo 'cp -a files/home/paul/. /home/paul/'
    echo 'sudo systemctl daemon-reload && sudo systemctl enable arcade'
    echo 'sudo systemctl set-default multi-user.target'
    echo '```'
    echo
    echo 'ROMs are not in this repo. Drop them in `~/roms`, then:'
    echo
    echo '```'
    echo 'attractplus --build-romlist mame -o mame   # the -o matters'
    echo 'python3 ~/get-artwork.py'
    echo 'python3 ~/mk-controls.py mk mk2            # per-game input maps'
    echo '```'
    echo
    echo 'The backup deploy key is not in here. On a fresh card, regenerate it'
    echo 'and re-add it to the repo as a write-enabled deploy key:'
    echo
    echo '```'
    echo "ssh-keygen -t ed25519 -N '' -C arcade-cabinet-deploy \\"
    echo '    -f ~/.ssh/id_cabinet_deploy'
    echo 'ssh-keyscan -t ed25519 github.com >> ~/.ssh/known_hosts   # verify the'
    echo '    # fingerprint against docs.github.com before trusting it'
    echo 'bash ~/github-remote.sh <owner>/<repo>'
    echo 'crontab -e    # restore the 04:17 line shown above'
    echo '```'
} > "$REPO/MANIFEST.md"

cd "$REPO" || exit 1

if $DRY_RUN; then
    echo "-- dry run, changes that would be committed:"
    git add -A -n
    git status --short
    exit 0
fi

git add -A
if git diff --cached --quiet; then
    echo "-- no changes since last snapshot"
else
    git commit -q -m "cabinet snapshot $(date '+%Y-%m-%d %H:%M')"
    echo "-- committed: $(git log -1 --oneline)"
fi

# Push only if a remote has actually been configured. Until then this is a
# local repo, which protects against a bad edit but NOT against the SD card
# failing -- that needs an off-box remote.
if git remote get-url origin >/dev/null 2>&1; then
    if git push -q origin main 2>&1; then
        echo "-- pushed to $(git remote get-url origin)"
    else
        echo "-- PUSH FAILED (repo is still committed locally)"
    fi
else
    echo "-- no 'origin' remote set; snapshot is LOCAL ONLY"
    echo "   (an SD card failure would still lose it -- add a remote)"
fi

echo "-- $(git rev-list --count HEAD) snapshot(s), $(du -sh "$REPO" | cut -f1) on disk"
