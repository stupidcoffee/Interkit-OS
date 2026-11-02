#!/bin/sh
# Run an interkit ISO (or the installed disk) in QEMU.
#
#   scripts/run-qemu.sh interkit.iso            # boot the ISO (live system / installer) with a blank disk attached
#   scripts/run-qemu.sh -b                      # boot the installed disk only (no ISO)
#   scripts/run-qemu.sh -n interkit.iso         # just print the QEMU command
#
# The screen opens in a window (GRUB, console). The serial console is THIS terminal: the text installer and the
# serial login appear here. Quit QEMU with  Ctrl-a  then  x .
#
# Options: -d DISK  target disk image (default ./interkit-disk.qcow2, created at -S size if missing)
#          -S SIZE  disk size when creating (default 16G)     -m MEM  RAM (default 3G)      -c N  CPUs (default 2)
#          -r WxH   screen size (default 1024x640; arm64 only) -a ARCH arm64 (default) or amd64
#          -p H:G   forward host port H to guest port G (repeatable; default 2223:22 and 18080:8080)
#          -b       boot from the disk only      -n  dry run: print the command, do not start
set -eu

ARCH=arm64 DISK=./interkit-disk.qcow2 SIZE=16G MEM=3G CPUS=2 RES=1024x640 BOOTDISK=0 DRY=0 PORTS=""
while getopts "d:S:m:c:r:a:p:bnh" o; do
  case $o in
    d) DISK=$OPTARG;; S) SIZE=$OPTARG;; m) MEM=$OPTARG;; c) CPUS=$OPTARG;; r) RES=$OPTARG;; a) ARCH=$OPTARG;;
    p) PORTS="$PORTS $OPTARG";; b) BOOTDISK=1;; n) DRY=1;; h|*) sed -n '2,17p' "$0"; exit 2;;
  esac
done
shift $((OPTIND-1))
ISO="${1:-}"
[ "$BOOTDISK" = 1 ] || [ -n "$ISO" ] || { echo "give an ISO path, or -b to boot the installed disk" >&2; sed -n '2,6p' "$0"; exit 2; }
[ "$BOOTDISK" = 1 ] || [ -f "$ISO" ] || { echo "ISO not found: $ISO" >&2; exit 1; }
[ -n "$PORTS" ] || PORTS="2223:22 18080:8080"

OS=$(uname -s); HOST=$(uname -m)
case "$ARCH" in
  arm64) BIN=qemu-system-aarch64; MACHINE="virt,highmem=on"; CPU=host ;;
  amd64) BIN=qemu-system-x86_64;  MACHINE="q35";             CPU=host ;;
  *) echo "unknown arch: $ARCH" >&2; exit 2;;
esac
command -v "$BIN" >/dev/null 2>&1 || { echo "$BIN not found (macOS: brew install qemu; Debian: apt install qemu-system-arm qemu-system-x86 qemu-utils)" >&2; exit 1; }

# acceleration: only works when the guest arch matches the host
case "$OS:$ARCH:$HOST" in
  Darwin:arm64:arm64|Darwin:amd64:x86_64) ACCEL="-accel hvf" ;;
  Linux:arm64:aarch64|Linux:amd64:x86_64) if [ -w /dev/kvm ]; then ACCEL="-accel kvm"; else ACCEL="-accel tcg"; CPU=max; fi ;;
  *) ACCEL="-accel tcg"; CPU=max; echo "note: no hardware acceleration for $ARCH on $HOST; this will be slow" >&2 ;;
esac

# UEFI firmware (arm64 needs it; amd64 boots fine with SeaBIOS)
FW=""; VARS=""
if [ "$ARCH" = arm64 ]; then
  for f in /opt/homebrew/share/qemu/edk2-aarch64-code.fd /usr/local/share/qemu/edk2-aarch64-code.fd \
           /usr/share/qemu/edk2-aarch64-code.fd /usr/share/AAVMF/AAVMF_CODE.fd /usr/share/qemu-efi-aarch64/QEMU_EFI.fd; do
    [ -f "$f" ] && { FW=$f; break; }
  done
  [ -n "$FW" ] || { echo "arm64 UEFI firmware not found (install qemu / qemu-efi-aarch64)" >&2; exit 1; }
  VARS="$DISK.vars.fd"
  if [ ! -f "$VARS" ]; then   # writable UEFI variable store, one per disk
    TPL=$(dirname "$FW")/edk2-arm-vars.fd; [ -f "$TPL" ] || TPL=/usr/share/AAVMF/AAVMF_VARS.fd
    if [ -f "$TPL" ]; then [ "$DRY" = 1 ] || cp "$TPL" "$VARS"; else [ "$DRY" = 1 ] || dd if=/dev/zero of="$VARS" bs=1048576 count=64 2>/dev/null; fi
  fi
fi

if [ ! -f "$DISK" ] && [ "$DRY" != 1 ]; then command -v qemu-img >/dev/null || { echo "qemu-img not found" >&2; exit 1; }; qemu-img create -q -f qcow2 "$DISK" "$SIZE"; echo "created blank disk $DISK ($SIZE)"; fi

NET="user,id=n0"; for p in $PORTS; do NET="$NET,hostfwd=tcp:127.0.0.1:${p%%:*}-:${p##*:}"; done
set -- "$BIN" -machine "$MACHINE" $ACCEL -cpu "$CPU" -smp "$CPUS" -m "$MEM"
[ -z "$FW" ] || set -- "$@" -drive "if=pflash,format=raw,readonly=on,file=$FW" -drive "if=pflash,format=raw,file=$VARS"
set -- "$@" -device qemu-xhci -device usb-kbd
if [ "$BOOTDISK" != 1 ]; then
  set -- "$@" -drive "if=none,id=cd,media=cdrom,readonly=on,file=$ISO" -device usb-storage,drive=cd,bootindex=0
fi
set -- "$@" -drive "if=none,id=hd,format=qcow2,file=$DISK" -device virtio-blk-pci,drive=hd,bootindex=1
if [ "$ARCH" = arm64 ]; then set -- "$@" -device "virtio-gpu-pci,xres=${RES%x*},yres=${RES#*x}"; else set -- "$@" -vga virtio; fi
if [ "$OS" = Darwin ]; then set -- "$@" -display cocoa; else set -- "$@" -display gtk; fi
set -- "$@" -netdev "$NET" -device virtio-net-pci,netdev=n0 -serial mon:stdio

if [ "$DRY" = 1 ]; then echo "$*" | sed 's/ -/ \\\n  -/g'; exit 0; fi
FIRST=${PORTS%% *}
echo "interkit in QEMU: the window is the screen, this terminal is the serial console. Quit: Ctrl-a then x."
echo "forwarded ports (host:guest): $PORTS    e.g. ssh -p ${FIRST%%:*} youruser@127.0.0.1"
exec "$@"
