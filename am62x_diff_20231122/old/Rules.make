
### COMMON CONFIG ###
CFLAGS?=

#Strip modules when installing to conserve disk space
INSTALL_MOD_STRIP?=1

# Set EXEC_DIR to install example binaries.
# This will be configured with the setup.sh script.
EXEC_DIR?=__EXEC_DIR__

#root of the target file system for installing applications
DESTDIR?=__DESTDIR__

# Root of the boot partition to install boot binaries
BOOTFS?=__BOOTFS__

MAKE_JOBS?=1

### TI SDK CONFIG ###
#Points to the root of the TI SDK
export TI_SDK_PATH?=/home/hgchoe/ti-processor-sdk-linux-am62xx-evm-09.00.00.03

export LINUX_DEVKIT_PATH=$(TI_SDK_PATH)/linux-devkit
SDK_PATH_TARGET=$(LINUX_DEVKIT_PATH)/sysroots/aarch64-oe-linux
SDK_PATH_HOST=$(LINUX_DEVKIT_PATH)/sysroots/x86_64-arago-linux
export CROSS_COMPILE=$(TI_SDK_PATH)/external-toolchain-dir/arm-gnu-toolchain-11.3.rel1-x86_64-aarch64-none-linux-gnu/bin/aarch64-none-linux-gnu-
export CROSS_COMPILE_ARMV7=$(TI_SDK_PATH)/external-toolchain-dir/arm-gnu-toolchain-11.3.rel1-x86_64-arm-none-linux-gnueabihf/bin/arm-none-linux-gnueabihf-

#Default CC value to be used when cross compiling.  This is so that the
#GNU Make default of "cc" is not used to point to the host compiler
export CC=$(CROSS_COMPILE)gcc --sysroot=$(SDK_PATH_TARGET)


# The source directories for each component
ARM_BENCHMARKS_SRC_DIR=$(TI_SDK_PATH)/example-applications/*arm-benchmarks*
AM_SYSINFO_SRC_DIR=$(TI_SDK_PATH)/example-applications/*am-sysinfo*
OPROFILE_SRC_DIR=$(TI_SDK_PATH)/example-applications/*oprofile-example*
CRYPTODEV_SRC_DIR=$(TI_SDK_PATH)/board-support/extra-drivers/cryptodev*
IMG_ROGUE_SRC_DIR=$(TI_SDK_PATH)/board-support/extra-drivers/ti-img-rogue-driver*
UBOOT_SRC_DIR=$(TI_SDK_PATH)/board-support/ti-u-boot
KIG_SRC_DIR=$(TI_SDK_PATH)/board-support/k3-image-gen-*
LINUXKERNEL_INSTALL_DIR=$(TI_SDK_PATH)/board-support/ti-linux-kernel

export TI_SECURE_DEV_PKG=$(TI_SDK_PATH)/board-support/core-secdev-k3
### PLATFORM CONFIG ###
#platform
SOC=am62

#add platform for scripts
PLATFORM?=am62xx-evm

#defconfig
DEFCONFIG=tisdk_am62xx-evm_defconfig

ARCH=aarch64

# u-boot machine configs for A53 and R5
UBOOT_MACHINE=am62x_evm_a53_defconfig
UBOOT_MACHINE_R5=am62x_evm_r5_defconfig
MKIMAGE_DTB_FILE=a53/arch/arm/dts/k3-am625-sk.dtb

# Update platform, defconfig if PLATFORM=am62xx-lp-evm
ifeq ($(PLATFORM),am62xx-lp-evm)
    UBOOT_MACHINE=am62x_lpsk_a53_defconfig
    UBOOT_MACHINE_R5=am62x_lpsk_r5_defconfig
    MKIMAGE_DTB_FILE=a53/arch/arm/dts/k3-am62-lp-sk.dtb
endif

KERNEL_DEVICETREE_PREFIX=ti/k3-am625|ti/k3-am62-|ti/k3-am62x|ti/k3-am62.dtsi

TI_LINUX_FIRMWARE=$(TI_SDK_PATH)/board-support/prebuilt-images/$(PLATFORM)
UBOOT_ATF=$(TI_SDK_PATH)/board-support/prebuilt-images/$(PLATFORM)/bl31.bin
UBOOT_TEE=$(TI_SDK_PATH)/board-support/prebuilt-images/$(PLATFORM)/bl32.bin
LINUXEXTRASKERNEL_INSTALL_DIR=$(TI_SDK_PATH)/board-support/linux-extras
UBOOTEXTRAS_SRC_DIR=$(TI_SDK_PATH)/board-support/u-boot-extras

# Add configs for ti-img-rogue-driver
PVR_BUILD_DIR=am62_linux
RGX_BVNC="33.15.11.3"
WINDOW_SYSTEM=wayland

MAKE_ALL_TARGETS?= arm-benchmarks oprofile-example pru-icss matrix-gui cryptodev u-boot linux linux-dtbs ti-img-rogue-driver jailhouse linux-extras linux-extras-dtbs u-boot-extras

MAKE_JOBS=8
