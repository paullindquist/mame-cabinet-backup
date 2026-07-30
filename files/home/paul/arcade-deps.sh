#!/bin/bash
# Attract-Mode Plus + MAME build dependencies for Ubuntu 26.04 arm64 (Pi 5)
# Run with:  sudo bash ~/arcade-deps.sh
set -e

echo "== Installing build dependencies =="
apt install -y \
  build-essential pkg-config cmake \
  libavformat-dev libavcodec-dev libavutil-dev libswscale-dev libswresample-dev \
  libopenal-dev libvorbis-dev libflac-dev libogg-dev libudev-dev \
  libgl1-mesa-dev libglu1-mesa-dev libdrm-dev libgbm-dev libegl-dev \
  libfreetype-dev libfontconfig1-dev libjpeg-dev zlib1g-dev libexpat1-dev \
  libarchive-dev libcurl4-openssl-dev libxrandr-dev libxinerama-dev \
  mame mame-tools

echo
echo "== Adding paul to video/render/input groups (needed for DRM/KMS + I-PAC) =="
usermod -aG video,render,input paul

echo
echo "== Done =="
echo "Installed: $(dpkg -l | grep -c '^ii') packages total"
