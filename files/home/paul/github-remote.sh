#!/usr/bin/env bash
# Point the cabinet's config backup at a private GitHub repo and push it.
#
# Run this AFTER you have created the empty private repo on GitHub and added
# this box's deploy key to it with write access. The key is:
#
#     ~/.ssh/id_cabinet_deploy.pub
#
# No sudo needed.
#
# Usage:  bash ~/github-remote.sh <owner>/<repo>
#         bash ~/github-remote.sh plindquist/arcade-cabinet
set -uo pipefail

REPO=/home/paul/cabinet-config
TARGET="${1:-}"

if [ -z "$TARGET" ] || [[ "$TARGET" != */* ]]; then
    echo "Usage: bash ~/github-remote.sh <owner>/<repo>" >&2
    echo "e.g.   bash ~/github-remote.sh yourname/arcade-cabinet" >&2
    exit 1
fi

URL="git@github.com:${TARGET}.git"

echo "== Checking the deploy key can reach GitHub =="
# GitHub always closes this connection non-zero; the useful signal is the
# greeting it prints, which names what the key is authorised for.
OUT=$(ssh -T -o BatchMode=yes git@github.com 2>&1 || true)
echo "   $OUT"
case "$OUT" in
    *"successfully authenticated"*|*"You've successfully"*|*"appears to be a repository"*|*"$(basename "$TARGET")"*)
        ;;
    *"Permission denied"*)
        echo
        echo "GitHub rejected the key. The deploy key has not been added yet," >&2
        echo "or it was added to a different repo. Public key to add:" >&2
        echo >&2
        cat /home/paul/.ssh/id_cabinet_deploy.pub >&2
        exit 1
        ;;
esac

echo
echo "== Setting the remote =="
cd "$REPO" || exit 1
if git remote get-url origin >/dev/null 2>&1; then
    git remote set-url origin "$URL"
    echo "   updated origin -> $URL"
else
    git remote add origin "$URL"
    echo "   added origin -> $URL"
fi

echo
echo "== Pushing =="
if git push -u origin main; then
    echo
    echo "================================================================"
    echo "Done. $(git rev-list --count HEAD) snapshot(s) now live at:"
    echo "    https://github.com/${TARGET}"
    echo
    echo "The nightly cron job at 04:17 will push automatically from here"
    echo "on, and only when something actually changed."
    echo
    echo "Check it is working any time with:"
    echo "    tail ~/cabinet-backup.log"
    echo "================================================================"
else
    echo
    echo "Push failed. Most likely causes, in order:" >&2
    echo "  1. The deploy key was added WITHOUT 'Allow write access' ticked." >&2
    echo "  2. The repo name is wrong, or the repo was not created yet." >&2
    echo "  3. The repo was created with a README, so it has a commit ours" >&2
    echo "     does not share. Fix with:  git -C $REPO push -u --force origin main" >&2
    echo "     (safe here -- this repo only ever contains generated snapshots)" >&2
    exit 1
fi
