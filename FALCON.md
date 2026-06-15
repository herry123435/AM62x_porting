# U-Boot Falcon Mode — CX-AM62x (mango) Runbook

Complete, from-scratch procedure to build and boot U-Boot **Falcon mode** on the
CRZ CX-AM62x board, on top of TI Processor SDK 11.02.08.02.

## What Falcon mode is here

```
Normal boot:  R5 SPL -> ATF -> OP-TEE -> A53 SPL -> U-Boot -> Kernel
Falcon boot:  R5 SPL -> ATF -> OP-TEE -> Kernel          (no A53 SPL, no U-Boot)
```

The R5 SPL loads a cut-down `tifalcon.bin` (ATF+OP-TEE+DM, no A53 SPL) plus a
signed `fitImage` (kernel + dtb) and jumps straight into Linux. It saves the
U-Boot-proper init time.

## Safety model (read first)

- Falcon lives **only on an SD card**. Production **NAND/eMMC are never written**
  by this procedure.
- **Recovery = the boot-mode switch.** Set it back to NAND/eMMC (or remove the
  SD card) and power-cycle; the board boots its untouched normal image.
- There is **no in-SD U-Boot fallback** and **no `boot_os` switch**: the Falcon
  SD card has no `tispl.bin` / `u-boot.img`. The K3 platform
  (`arch/arm/mach-k3/common.c`) auto-selects Falcon whenever `tifalcon.bin` loads
  — `spl_start_uboot()` keys off the internal `tifalcon_loaded` flag. Recovery is
  the boot-mode switch. (Do **not** add a `spl_start_uboot()` to `evm.c`; the
  platform already defines it and a second one fails to link.)
- The normal build (`make u-boot`) and the normal `am62x_evm_r5_defconfig` are
  **untouched** — all Falcon work happens in separate `*-falcon` output dirs and
  in the opt-in `k3_r5_falcon.config` fragment.

## Prerequisites

1. **Device type = HS-FS** (this SDK's default; the stock `tiboot3.bin` is the
   `hs-fs` variant and the build sets `CONFIG_TI_SECURE_DEVICE=y`). Confirm from
   the serial log of a normal boot — look for `Device Type: HS-FS`. HS-FS means
   the `fitImage` **must be signed** (Section 4). If your board is actually `GP`,
   see Appendix C for the unsigned shortcut.
2. **`core-secdev-k3`** must be present (used to sign the kernel + dtb). Check:
   ```bash
   ls /home/herry123435/ti-processor-sdk-linux-am62xx-evm-11.02.08.02/board-support/core-secdev-k3/scripts/secure-binary-image.sh
   ```
   If missing:
   ```bash
   cd /home/herry123435/ti-processor-sdk-linux-am62xx-evm-11.02.08.02/board-support
   git clone https://git.ti.com/git/security-development-tools/core-secdev-k3.git
   ```

---

## Section 0 — Environment (paste once per shell)

```bash
export TI_SDK_PATH=/home/herry123435/ti-processor-sdk-linux-am62xx-evm-11.02.08.02
export CROSS_COMPILE=$TI_SDK_PATH/linux-devkit/sysroots/x86_64-arago-linux/usr/bin/aarch64-oe-linux/aarch64-oe-linux-
export CROSS_COMPILE_ARMV7=$TI_SDK_PATH/k3r5-devkit/sysroots/x86_64-arago-linux/usr/bin/arm-oe-eabi/arm-oe-eabi-
export SDK_PATH_TARGET=$TI_SDK_PATH/linux-devkit/sysroots/aarch64-oe-linux
export CC="${CROSS_COMPILE}gcc --sysroot=$SDK_PATH_TARGET"

export UBOOT=$TI_SDK_PATH/board-support/ti-u-boot-2025.01+git
export KERN=$TI_SDK_PATH/board-support/ti-linux-kernel-6.12.57+git-ti
export TFA=$TI_SDK_PATH/board-support/trusted-firmware-a-2.13+git
export FW=$TI_SDK_PATH/board-support/prebuilt-images/am62xx-evm
export SECDEV=$TI_SDK_PATH/board-support/core-secdev-k3
export DM=$FW/ti-dm/am62xx/ipc_echo_testb_mcu1_0_release_strip.xer5f

export R5O=$TI_SDK_PATH/board-support/u-boot-build/r5-falcon
export A53O=$TI_SDK_PATH/board-support/u-boot-build/a53-falcon
export BL31_FALCON=$TFA/build/k3/lite/release/bl31.bin
```

---

## Section 1 — Overlay the AM62x_porting repo onto the SDK

Run from wherever the repo is checked out on the build machine (adjust the first
path only). This merges the edited/added board files over the SDK; `--delete` is
intentionally absent so nothing is removed.

```bash
rsync -av --no-perms --omit-dir-times \
  --exclude ti-processor-sdk-backup --exclude ti-processor-sdk-backup.zip \
  --exclude am62x_diff_20231122 --exclude '.git' --exclude '.claude' \
  /home/herry123435/AM62x_porting/  $TI_SDK_PATH/
```

---

## Section 2 — Rebuild ATF with Falcon load addresses

`BL31` being set in the environment disables TF-A's `bl31` build rule (it
switches to "package a prebuilt" mode), so it must be unset.

```bash
cd $TFA
unset BL31 BL32 BL33 TEE
make realclean
make -j16 CROSS_COMPILE=$CROSS_COMPILE ARCH=aarch64 \
     PLAT=k3 TARGET_BOARD=lite SPD=opteed \
     PRELOADED_BL33_BASE=0x82000000 K3_HW_CONFIG_BASE=0x88000000 bl31
ls -l $BL31_FALCON          # build/k3/lite/release/bl31.bin must exist
```

---

## Section 3 — Build Falcon U-Boot

### 3a. (No env edit needed) — how the Falcon cmdline is built

There is **no `boot_os` / `bootargs` step**. The K3 platform auto-enables Falcon
when `tifalcon.bin` loads, and `k3_falcon_fdt_fixup()`
(`arch/arm/mach-k3/common.c`) builds the kernel cmdline automatically as
`console=<console> root=PARTUUID=<rootfs uuid> rootwait` from env the board
already ships. Just confirm those exist:

```bash
grep -E '^console=|^boot=|^bootpart=' $UBOOT/board/ti/am62x/am62x.env
# expected: console=ttyS2,115200n8  /  boot=mmc  /  bootpart=1:2
# (bootpart 1:2 = SD = mmc dev 1, partition 2 -> rootfs PARTUUID is derived from it)
```

### 3b. Build the R5 SPL (Falcon) -> `tiboot3.bin`

The `k3_r5_falcon.config` fragment already disables the raw-NAND stack
(`MTD_RAW_NAND`/`NAND_OMAP_GPMC`/`NAND_OMAP_ELM`) — required, because disabling
only `SPL_NAND_SUPPORT` leaves `omap_gpmc.c` compiling against the now-undefined
`CONFIG_SYS_NAND_BLOCK_SIZE`.

```bash
rm -rf $R5O && mkdir -p $R5O
make -C $UBOOT ARCH=arm O=$R5O am62x_evm_r5_defconfig
make -C $UBOOT ARCH=arm O=$R5O k3_r5_falcon.config
make -j16 -C $UBOOT ARCH=arm CROSS_COMPILE=$CROSS_COMPILE_ARMV7 BINMAN_INDIRS=$FW O=$R5O

# sanity-check the merged config:
grep -E 'CONFIG_(NAND_OMAP_GPMC|MTD_RAW_NAND|SPL_NAND_SUPPORT)' $R5O/.config   # all "is not set"
grep -E 'CONFIG_SPL_OS_BOOT=|CONFIG_SPL_OS_BOOT_SECURE=' $R5O/.config           # both =y
ls -l $R5O/tiboot3.bin
```

### 3c. Build the A53 U-Boot with the Falcon ATF -> `tifalcon.bin`

Uses the stock `am62x_evm_a53_defconfig` (no fragment) but the rebuilt Falcon
`bl31.bin`. Produces `tifalcon.bin` (and `tispl.bin`/`u-boot.img`, which the
Falcon card does not use).

```bash
rm -rf $A53O && mkdir -p $A53O
make -C $UBOOT ARCH=arm O=$A53O am62x_evm_a53_defconfig
make -j16 -C $UBOOT ARCH=arm CROSS_COMPILE=$CROSS_COMPILE CC="$CC" \
     BINMAN_INDIRS=$FW BL31=$BL31_FALCON TEE=$FW/bl32.bin TI_DM=$DM O=$A53O
ls -l $A53O/tifalcon.bin
```

---

## Section 4 — Build kernel + signed Falcon `fitImage`

### 4a. Build the kernel + device trees

```bash
cd $TI_SDK_PATH
make linux linux-dtbs
ls -l $KERN/arch/arm64/boot/Image
ls -l $KERN/arch/arm64/boot/dts/ti/k3-am625-sk.dtb
```

### 4b. Merge the panel overlay into one dtb (Falcon can't apply dtbo at runtime)

```bash
cd $KERN/arch/arm64/boot/dts/ti
fdtoverlay -i k3-am625-sk.dtb -o /tmp/falcon.dtb k3-am625-sk-bsd101wx1-300.dtbo
ls -l /tmp/falcon.dtb
```

### 4c. Sign the kernel + dtb and build the FIT (HS-FS)

```bash
cd $SECDEV
cp $KERN/arch/arm64/boot/Image  Image
cp /tmp/falcon.dtb              falcon.dtb
./scripts/secure-binary-image.sh Image      Image.sec
./scripts/secure-binary-image.sh falcon.dtb falcon.dtb.sec

cat > fitImage.its << 'EOF'
/dts-v1/;

/ {
    description = "Kernel fitImage for falcon mode";
    #address-cells = <1>;

    images {
        kernel-1 {
            description = "Linux kernel";
            data = /incbin/("Image.sec");
            type = "kernel";
            arch = "arm64";
            os = "linux";
            compression = "none";
            load = <0x82000000>;
            entry = <0x82000000>;
        };
        falcon.dtb {
            description = "Flattened Device Tree blob";
            data = /incbin/("falcon.dtb.sec");
            type = "flat_dt";
            arch = "arm64";
            compression = "none";
            load = <0x88000000>;
            entry = <0x88000000>;
        };
    };

    configurations {
        default = "conf-falcon";
        conf-falcon {
            description = "Pre-signed Kernel and DTB";
            kernel = "kernel-1";
            fdt = "falcon.dtb";
        };
    };
};
EOF

$A53O/tools/mkimage -f fitImage.its fitImage
ls -l $SECDEV/fitImage
```

`mkimage` is built by U-Boot (here `$A53O/tools/mkimage`); it is not a system
command.

---

## Section 5 — Assemble the SD card

Falcon needs exactly **3 files**:

| File | Source | Card location | Partition |
|------|--------|---------------|-----------|
| `tiboot3.bin` | `$R5O/tiboot3.bin` | `/tiboot3.bin` | p1 boot (FAT) |
| `tifalcon.bin` | `$A53O/tifalcon.bin` | `/boot/tifalcon.bin` | p2 rootfs (ext4) |
| `fitImage` | `$SECDEV/fitImage` | `/boot/fitImage` | p2 rootfs (ext4) |

### 5a. Identify the SD card  ⚠️ DESTRUCTIVE — get this right

```bash
lsblk -o NAME,SIZE,TYPE,MOUNTPOINT,MODEL
```
Pick the card by size/model. Then set it and a partition-suffix helper:

```bash
SD=/dev/sdX                              # <-- REPLACE sdX with YOUR card; NOT your system disk
P=""; [[ "$SD" == *[0-9] ]] && P="p"     # mmcblk* needs a 'p' before the partition number
echo "About to ERASE $SD  -> ${SD}${P}1 ${SD}${P}2"; lsblk "$SD"
```

### 5b. Partition + format (TI 2-partition layout)

```bash
sudo umount ${SD}* 2>/dev/null
sudo sfdisk $SD <<'EOF'
label: dos
,128M,c,*
,,83
EOF
sudo partprobe $SD
sudo mkfs.vfat -F 32 -n boot   ${SD}${P}1
sudo mkfs.ext4 -F   -L rootfs  ${SD}${P}2
```

### 5c. Mount + copy files + rootfs + matching modules

```bash
sudo mkdir -p /mnt/fboot /mnt/froot
sudo mount ${SD}${P}1 /mnt/fboot
sudo mount ${SD}${P}2 /mnt/froot

# p1 (FAT): only the Falcon R5 SPL
sudo cp $R5O/tiboot3.bin /mnt/fboot/tiboot3.bin

# p2 (ext4): rootfs, then the two Falcon payloads under /boot
sudo tar --numeric-owner -xpf $TI_SDK_PATH/filesystem/am62xx-evm/tisdk-default-image-am62xx-evm.rootfs.tar.xz -C /mnt/froot
sudo cp $A53O/tifalcon.bin /mnt/froot/boot/tifalcon.bin
sudo cp $SECDEV/fitImage   /mnt/froot/boot/fitImage

# install YOUR kernel's modules so they match the fitImage kernel
sudo make -C $KERN ARCH=arm64 CROSS_COMPILE=$CROSS_COMPILE \
     INSTALL_MOD_PATH=/mnt/froot modules_install

sudo sync
sudo umount /mnt/fboot /mnt/froot
```

---

## Section 6 — Boot and verify

1. Set the board boot-mode switch to **SD boot** (same SW1/SW2 setting used for
   normal SD boot, schematic sheet 3).
2. Connect serial console: `ttyS2`, 115200 8N1.
3. Insert the card, power on.
4. **Success:** R5 SPL banner, then Linux boots **directly** — no
   `U-Boot 2025.01...` banner, no boot countdown. That absence proves Falcon ran.
5. **Failure / hang:** flip the boot-mode switch back to NAND/eMMC (or pull the
   card) and power-cycle. Production boot is untouched. Read the serial log to
   see the last R5 SPL stage reached.

---

## Appendix A — Gotchas already hit (and their fixes)

- **`make ... bl31` says "Nothing to be done for 'bl31'":** `BL31` is exported in
  the shell, so TF-A skips building it. Fix: `unset BL31 BL32 BL33 TEE` before
  Section 2 (already in the commands).
- **`mkimage: command not found`:** it is built by U-Boot, not the OS. Use
  `$A53O/tools/mkimage` (or `$R5O/tools/mkimage`), as in Section 4c.
- **`core-secdev-k3 missing`:** clone it (Prerequisites #2).
- **`CONFIG_SYS_NAND_BLOCK_SIZE undeclared` during the R5 build:** the board's
  R5 defconfig enables the GPMC NAND driver, which `select`s `SPL_NAND_INIT`;
  disabling only `SPL_NAND_SUPPORT` drops `SYS_NAND_BLOCK_SIZE` while
  `omap_gpmc.c` still compiles. Fix: `k3_r5_falcon.config` disables
  `MTD_RAW_NAND` / `NAND_OMAP_GPMC` / `NAND_OMAP_ELM` (already applied). If the
  A53 build (3c) ever throws the same error, add those three `# ... is not set`
  lines to that build's `.config` too.
- **`multiple definition of 'spl_start_uboot'` at link:** the K3 platform
  (`arch/arm/mach-k3/common.c:584`) already defines a non-weak `spl_start_uboot()`
  (Falcon when `tifalcon.bin` loaded). Do **not** add one in `board/ti/am62x/evm.c`
  — that was an early mistake, now removed. Falcon selection and the kernel
  cmdline are entirely platform-provided.

## Appendix B — Revert to normal (disable Falcon)

- Just boot the normal image: boot-mode switch to NAND/eMMC, or remove the SD
  card. Nothing else needed.
- To rebuild a normal SD card, use the standard `make u-boot` output
  (`u-boot-build/r5/tiboot3.bin`, `u-boot-build/a53/tispl.bin`, `u-boot.img`).

## Appendix C — GP devices only (unsigned, no core-secdev-k3)

If `Device Type: GP` (not HS-FS):

```bash
# 1) drop secure-os-boot in the fragment, allow fallback
sed -i 's/^CONFIG_SPL_OS_BOOT_SECURE=y/# CONFIG_SPL_OS_BOOT_SECURE is not set/' $UBOOT/configs/k3_r5_falcon.config
printf 'CONFIG_SPL_FALCON_ALLOW_FALLBACK=y\n' >> $UBOOT/configs/k3_r5_falcon.config
# 2) rebuild R5 (Section 3b)
# 3) build an UNSIGNED fitImage: in fitImage.its use data = /incbin/("Image") and
#    data = /incbin/("falcon.dtb")  (no .sec), then:
cd $SECDEV && cp $KERN/arch/arm64/boot/Image Image && cp /tmp/falcon.dtb falcon.dtb
$A53O/tools/mkimage -f fitImage.its fitImage
```

## Memory map reference (1 GB DDR4, fits TI's SK map)

```
0x80000000  ATF (BL31)            CONFIG_K3_ATF_LOAD_ADDR
0x82000000  Kernel (Image.sec)    PRELOADED_BL33_BASE / SPL_LOAD_FIT_ADDRESS
0x88000000  Kernel DTB            K3_HW_CONFIG_BASE / SPL_PAYLOAD_ARGS_ADDR
0x89000000  Device Manager (DM)
0x9e800000  OP-TEE (BL32)         CONFIG_K3_OPTEE_LOAD_ADDR
```
