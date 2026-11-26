#!/usr/bin/env bash
set -euo pipefail

echo "=== Disk usage BEFORE cleanup ==="
df -h

# Remove large preinstalled toolchains unused by Android ROM porting
REMOVE_PATHS=(
  /usr/local/lib/android
  /usr/share/dotnet
  /opt/ghc
  /usr/local/.ghcup
  /opt/hostedtoolcache/CodeQL
  /usr/local/share/boost
  /usr/local/share/powershell
)

for p in "${REMOVE_PATHS[@]}"; do
  if [ -e "$p" ]; then
    echo "Removing $p ..."
    sudo rm -rf "$p" || true
  fi
done

if command -v docker >/dev/null 2>&1; then
  sudo docker image prune --all --force >/dev/null 2>&1 || true
fi

sudo apt-get clean >/dev/null 2>&1 || true

echo "=== Disk usage AFTER cleanup ==="
df -h

# Pick workspace root with the largest available space between / and /mnt
ROOT_AVAIL=$(df -BG --output=avail / | tail -n 1 | tr -dc '0-9')
MNT_AVAIL=0
if [ -d /mnt ]; then
  MNT_AVAIL=$(df -BG --output=avail /mnt | tail -n 1 | tr -dc '0-9')
fi

if [ "${MNT_AVAIL:-0}" -gt "${ROOT_AVAIL:-0}" ]; then
  WORK_ROOT="/mnt/rom_work"
else
  WORK_ROOT="/tmp/rom_work"
fi

sudo mkdir -p "$WORK_ROOT"
sudo chown -R "$(id -u):$(id -g)" "$WORK_ROOT"
echo "Selected WORK_ROOT=$WORK_ROOT (root=${ROOT_AVAIL}G, mnt=${MNT_AVAIL}G)"

if [ -n "${GITHUB_ENV:-}" ]; then
  echo "WORK_ROOT=$WORK_ROOT" >> "$GITHUB_ENV"
fi
