#!/usr/bin/env bash
#
# build-normal-sd.sh — Build CX-AM62x **normal-boot** U-Boot + Linux kernel and
# copy them onto the SD card in one run. (Normal boot, NOT Falcon — for Falcon
# see FALCON.md.) This board is GP, so the GP / unsigned U-Boot artifacts are used.
#
# Usage:
#   ./build-normal-sd.sh
#
# Override any variable from the environment if your layout differs, e.g.:
#   TI_SDK_PATH=/opt/ti-sdk ROOTFS=/media/$USER/rootfs BOOT=/media/$USER/boot ./build-normal-sd.sh
#
# Re-exec under bash if started with sh/dash (pipefail is a bash-only feature).
if [ -z "${BASH_VERSION:-}" ]; then exec bash "$0" "$@"; fi

set -euo pipefail

# ---------------------------------------------------------------------------
# Configuration (every value can be overridden from the environment)
# ---------------------------------------------------------------------------
: "${TI_SDK_PATH:=$HOME/ti-processor-sdk-linux-am62xx-evm-11.02.08.02}"

: "${UBOOT_DIR:=$TI_SDK_PATH/board-support/ti-u-boot-2025.01+git}"
: "${KERNEL_DIR:=$TI_SDK_PATH/board-support/ti-linux-kernel-6.12.57+git-ti}"

# Toolchains (from the SDK devkits)
: "${CROSS_COMPILE_64:=$TI_SDK_PATH/linux-devkit/sysroots/x86_64-arago-linux/usr/bin/aarch64-oe-linux/aarch64-oe-linux-}"
: "${CROSS_COMPILE_32:=$TI_SDK_PATH/k3r5-devkit/sysroots/x86_64-arago-linux/usr/bin/arm-oe-eabi/arm-oe-eabi-}"
: "${SDK_PATH_TARGET:=$TI_SDK_PATH/linux-devkit/sysroots/aarch64-oe-linux}"
: "${CC_64:=${CROSS_COMPILE_64}gcc --sysroot=$SDK_PATH_TARGET}"

# Firmware fed to U-Boot's binman (prebuilt BL31 + OP-TEE)
: "${TI_LINUX_FW_DIR:=$TI_SDK_PATH/board-support/prebuilt-images/am62xx-evm}"
: "${BL31:=$TI_LINUX_FW_DIR/bl31.bin}"
: "${TEE:=$TI_LINUX_FW_DIR/bl32.bin}"

# SD-card mount points (udisks auto-mounts use the partition labels boot / rootfs)
: "${BOOT:=/media/$USER/boot}"       # FAT boot partition (p1) — U-Boot lands here
: "${ROOTFS:=/media/$USER/rootfs}"   # ext4 rootfs (p2)       — kernel lands here

: "${JOBS:=$(nproc)}"

log() { printf '\n\033[1;32m==> %s\033[0m\n' "$*"; }
die() { printf '\033[1;31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# Pre-flight checks (fail fast, before any long build)
# ---------------------------------------------------------------------------
log "Checking paths, toolchain, and SD card"
[ -d "$UBOOT_DIR" ]             || die "UBOOT_DIR not found: $UBOOT_DIR"
[ -d "$KERNEL_DIR" ]            || die "KERNEL_DIR not found: $KERNEL_DIR"
[ -x "${CROSS_COMPILE_64}gcc" ] || die "aarch64 gcc not found: ${CROSS_COMPILE_64}gcc"
[ -x "${CROSS_COMPILE_32}gcc" ] || die "arm (R5) gcc not found: ${CROSS_COMPILE_32}gcc"
[ -d "$TI_LINUX_FW_DIR" ]       || die "TI_LINUX_FW_DIR not found: $TI_LINUX_FW_DIR"
[ -f "$BL31" ]                  || die "BL31 not found: $BL31"
[ -f "$TEE" ]                   || die "TEE not found: $TEE"
mountpoint -q "$BOOT"           || die "SD boot partition not mounted at $BOOT — insert the card or set BOOT="
mountpoint -q "$ROOTFS"         || die "SD rootfs not mounted at $ROOTFS — insert the card or set ROOTFS="

R5_OUT="$UBOOT_DIR/out/r5"
A53_OUT="$UBOOT_DIR/out/a53"

# ---------------------------------------------------------------------------
# 1. Build U-Boot — R5 SPL -> tiboot3 ; A53 -> tispl + u-boot.img
# ---------------------------------------------------------------------------
log "Building U-Boot (R5 SPL)"
cd "$UBOOT_DIR"
rm -rf "$R5_OUT" "$A53_OUT"

make ARCH=arm CROSS_COMPILE="$CROSS_COMPILE_32" \
  am62x_evm_r5_defconfig \
  O="$R5_OUT"

make ARCH=arm CROSS_COMPILE="$CROSS_COMPILE_32" \
  O="$R5_OUT" \
  BINMAN_INDIRS="$TI_LINUX_FW_DIR"

log "Building U-Boot (A53 — U-Boot proper + tispl)"
make ARCH=arm CROSS_COMPILE="$CROSS_COMPILE_64" \
  am62x_evm_a53_defconfig cx_am62x_a53_min.config \
  O="$A53_OUT"

make ARCH=arm CROSS_COMPILE="$CROSS_COMPILE_64" \
  CC="$CC_64" \
  BL31="$BL31" \
  TEE="$TEE" \
  O="$A53_OUT" \
  BINMAN_INDIRS="$TI_LINUX_FW_DIR"

# ---------------------------------------------------------------------------
# 2. Copy U-Boot onto the SD boot partition (GP / unsigned artifacts)
#    FAT is user-writable (udisks), so no sudo here.
# ---------------------------------------------------------------------------
log "Copying U-Boot (GP / unsigned) to $BOOT"
cp -v "$R5_OUT/tiboot3-am62x-gp-evm.bin" "$BOOT/tiboot3.bin"
cp -v "$A53_OUT/tispl.bin_unsigned"      "$BOOT/tispl.bin"
cp -v "$A53_OUT/u-boot.img_unsigned"     "$BOOT/u-boot.img"
sync

# ---------------------------------------------------------------------------
# 3. Build the Linux kernel — Image + dtbs + modules
# ---------------------------------------------------------------------------
log "Building Linux kernel (Image + dtbs + modules)"
cd "$KERNEL_DIR"
make ARCH=arm64 CROSS_COMPILE="$CROSS_COMPILE_64" defconfig ti_arm64_prune.config
make ARCH=arm64 CROSS_COMPILE="$CROSS_COMPILE_64" DTC_FLAGS=-@ -j"$JOBS" Image dtbs modules

# ---------------------------------------------------------------------------
# 4. Install kernel + dtbs + modules onto the SD rootfs (ext4 is root-owned -> sudo)
# ---------------------------------------------------------------------------
log "Installing kernel + dtbs + modules into $ROOTFS"
sudo mkdir -p "$ROOTFS/boot/dtb/ti"
sudo cp -v arch/arm64/boot/Image                                  "$ROOTFS/boot/Image"
sudo cp -v arch/arm64/boot/dts/ti/k3-am625-sk.dtb                 "$ROOTFS/boot/dtb/ti/"
sudo cp -v arch/arm64/boot/dts/ti/k3-am625-sk-bsd101wx1-300*.dtbo "$ROOTFS/boot/dtb/ti/"
sudo make ARCH=arm64 CROSS_COMPILE="$CROSS_COMPILE_64" \
  INSTALL_MOD_PATH="$ROOTFS" modules_install
sync

log "Done. Unmount the card before removing it, e.g.:"
echo "    udisksctl unmount -b \$(findmnt -no SOURCE \"$BOOT\")"
echo "    udisksctl unmount -b \$(findmnt -no SOURCE \"$ROOTFS\")"
