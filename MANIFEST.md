# Arcade cabinet manifest

Generated 2026-07-30 14:34:32 on paul

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
mk.zip
mk2.zip
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
