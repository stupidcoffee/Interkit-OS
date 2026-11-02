#!/usr/bin/env bash
# Build the interkit live/installable ISO.
# Usage: sudo ARCH=amd64 ./build.sh     (ARCH defaults to host arch)
set -euo pipefail

NAME="${NAME:-interkit}"
SUITE="${SUITE:-trixie}"
ARCH="${ARCH:-$(dpkg --print-architecture)}"
SRC="$(cd "$(dirname "$0")" && pwd)"
# NOT /tmp: it is often a small nodev tmpfs, which breaks chroot device nodes
WORK="${WORK:-/var/tmp/${NAME}-build-${ARCH}}"
OUT="${OUT:-$SRC/out}"
# FIRMWARE=0 skips non-free firmware (much smaller/faster; fine for VMs, not for real hardware)
FIRMWARE="${FIRMWARE:-1}"
[[ $FIRMWARE == 1 ]] && FW=true || FW=false

[[ $EUID -eq 0 ]] || { echo "run as root (sudo)"; exit 1; }

apt-get update
DEBIAN_FRONTEND=noninteractive apt-get install -y live-build debootstrap \
  xorriso squashfs-tools mtools dosfstools grub-efi-"$ARCH"-bin grub-common \
  $([[ $ARCH == amd64 ]] && echo "syslinux syslinux-utils isolinux grub-pc-bin")

# keep live-build's download/bootstrap cache across runs: a failed build (flaky network) then resumes
# instead of downloading everything again.  CLEAN=1 wipes it.
if [[ -d "$WORK/cache" && "${CLEAN:-0}" != 1 ]]; then rm -rf "$WORK.cache"; mv "$WORK/cache" "$WORK.cache"; fi
rm -rf "$WORK"; mkdir -p "$WORK" "$OUT"
if [[ -d "$WORK.cache" ]]; then mv "$WORK.cache" "$WORK/cache"; echo "reusing cached downloads: $(du -sh "$WORK/cache" | cut -f1)"; fi
cp -a "$SRC/config" "$WORK/config"
cd "$WORK"

case "$ARCH" in
  amd64) BOOT="syslinux,grub-efi"; SERIAL="ttyS0,115200" ;;
  arm64) BOOT="grub-efi";          SERIAL="ttyAMA0,115200" ;;
  *)     echo "unsupported ARCH=$ARCH (add a case in build.sh)"; exit 1 ;;
esac
# Headless server: the TEXT installer (the graphical one needs X and shows nothing on many VMs/consoles).
# Screen console only by default.  Any console=ttyS* makes the Debian installer draw on the serial port instead of
# the screen (whatever the order), so on real hardware without a serial cable you only see a blinking "_".
# SERIAL_CONSOLE=1 adds the serial port (for headless boxes / QEMU -nographic) -- then the installer is serial-only.
CONSOLES="console=tty0"
[[ "${SERIAL_CONSOLE:-0}" == 1 ]] && CONSOLES="console=tty0 console=$SERIAL"
# Linux console colours = the text installer's look: white (f) on blue (1)
CONSOLES="$CONSOLES vt.color=0x1f"

lb config \
  --distribution "$SUITE" \
  --architectures "$ARCH" \
  --binary-images iso-hybrid \
  --bootloaders "$BOOT" \
  --debian-installer live \
  --archive-areas "main contrib non-free-firmware" \
  --firmware-chroot "$FW" --firmware-binary "$FW" \
  --debootstrap-options "--include=ca-certificates" \
  --iso-application "$NAME" \
  --iso-volume "${NAME}-${ARCH}" \
  --image-name "$NAME" \
  --debian-installer-gui false \
  --bootappend-install "$CONSOLES" \
  --bootappend-live "boot=live components quiet $CONSOLES"

# the installed system keeps only kernel parameters placed after '---', so pass the console settings to it explicitly
echo "d-i debian-installer/add-kernel-opts string $CONSOLES" >> config/includes.installer/preseed.cfg

lb build

shopt -s nullglob
for f in *.iso; do mv "$f" "$OUT/${NAME}-${SUITE}-${ARCH}.iso"; done
(cd "$OUT" && sha256sum ./*"${ARCH}.iso" > "${NAME}-${ARCH}.sha256")
echo "Done: $OUT"
