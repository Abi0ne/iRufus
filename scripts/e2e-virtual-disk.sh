#!/bin/bash
# End-to-end test on a virtual disk: builds an ISO fixture, attaches a blank
# disk image with hdiutil (no mount), writes it through the engine's raw
# device path, then lets macOS mount the result and fsck_msdos check it.
# Never touches a physical disk: the device is verified to be our image.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d -t irufus-e2e)"
trap 'hdiutil detach -force "${DEV:-/dev/null}" >/dev/null 2>&1 || true; rm -rf "$WORK"' EXIT

mkdir -p "$WORK/src/EFI/BOOT" "$WORK/src/sources"
head -c 2000000 /dev/urandom > "$WORK/src/EFI/BOOT/BOOTX64.EFI"
head -c 30000000 /dev/urandom > "$WORK/src/sources/big.bin"
echo "hello from iRufus" > "$WORK/src/readme.txt"
hdiutil makehybrid -quiet -iso -joliet -udf -o "$WORK/test.iso" "$WORK/src"

mkfile -n 256m "$WORK/disk.img"
DEV="$(hdiutil attach -nomount -imagekey diskimage-class=CRawDiskImage "$WORK/disk.img" | awk 'NR==1{print $1}')"
# Safety: the device must be the image we just attached.
hdiutil info | grep -A20 "$WORK/disk.img" | grep -q "^$DEV" || { echo "device mismatch, aborting"; exit 1; }
diskutil info "$DEV" | grep -q 'Protocol: *Disk Image' || { echo "$DEV is not a disk image"; exit 1; }
RDEV="/dev/r${DEV#/dev/}"
chmod u+w "$RDEV"   # owned by the user who attached it; no privileges needed

export PATH="$HOME/.cargo/bin:$PATH"
IRUFUS_E2E_RDISK="$RDEV" IRUFUS_E2E_ISO="$WORK/test.iso" \
    cargo test --manifest-path "$ROOT/engine/Cargo.toml" --release --test integration e2e_raw_character_device -- --nocapture 2>&1 | grep -E 'E2E:|test result|panicked'

hdiutil detach "$DEV" >/dev/null
DEV="$(hdiutil attach -imagekey diskimage-class=CRawDiskImage "$WORK/disk.img" | awk '/IRUFUS/{print $1}')"
MNT="$(diskutil info "$DEV" | sed -n 's/^ *Mount Point: *//p')"
echo "macOS mounted $DEV at $MNT"
cmp "$WORK/src/sources/big.bin" "$MNT/sources/big.bin"
cmp "$WORK/src/EFI/BOOT/BOOTX64.EFI" "$MNT/EFI/BOOT/BOOTX64.EFI"
diskutil unmount "$DEV" >/dev/null
fsck_msdos -n "/dev/r${DEV#/dev/}"
echo "E2E OK"
