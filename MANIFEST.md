# Arcade cabinet manifest

Host: paul

## System
```
model:      Raspberry Pi 5 Model B Rev 1.0
os:         Ubuntu 26.04 LTS
kernel:     7.0.0-1015-raspi
default:    multi-user.target
arcade svc: enabled / active
```

## Emulator
```
mame:       MAME v0.285 (unknown)
attractplus:Attract-Mode Plus v3.2.3 (Linux, SFML 3.0.1 +7z +Curl)
```

## ROM sets present
```
cclimber.zip
cclimbr2.zip
mk.zip
mk2.zip
swimmer.zip
```

## Incomplete ROM sets (parked outside the rompath)
```
cclimber.zip
mslug6.zip
```

## Hand-installed packages relevant to the build
```
mame 0.285+dfsg1-1
mame-data 0.285+dfsg1-1
attractplus (not from dpkg)
tailscale (not from dpkg)
```

## Nightly backup job (paul's user crontab, not systemd)
```
# Nightly snapshot of the arcade cabinet's configuration into ~/cabinet-config.
# Runs as paul -- no sudo needed. Log: ~/cabinet-backup.log
PATH=/usr/local/bin:/usr/bin:/bin
17 4 * * * bash /home/paul/cabinet-backup.sh >/dev/null 2>&1
```

## Restoring

Files here mirror their absolute paths under `files/`. To restore:

```
sudo cp -a files/etc/. /etc/
cp -a files/home/paul/. /home/paul/
sudo systemctl daemon-reload && sudo systemctl enable arcade
sudo systemctl set-default multi-user.target
```

ROMs are not in this repo. Drop them in `~/roms`, then:

```
attractplus --build-romlist mame -o mame   # the -o matters
python3 ~/get-artwork.py
python3 ~/mk-controls.py mk mk2            # per-game input maps
```

The backup deploy key is not in here. On a fresh card, regenerate it
and re-add it to the repo as a write-enabled deploy key:

```
ssh-keygen -t ed25519 -N '' -C arcade-cabinet-deploy \
    -f ~/.ssh/id_cabinet_deploy
ssh-keyscan -t ed25519 github.com >> ~/.ssh/known_hosts   # verify the
    # fingerprint against docs.github.com before trusting it
bash ~/github-remote.sh <owner>/<repo>
crontab -e    # restore the 04:17 line shown above
```
