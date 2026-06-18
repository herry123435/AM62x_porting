# U-Boot Falcon Mode — CX-AM62x (mango) Runbook

Complete, from-scratch procedure to build and boot U-Boot **Falcon mode** on the
CRZ CX-AM62x board, on top of TI Processor SDK 11.02.08.02.

## What Falcon mode is here

```
Normal boot:  R5 SPL -> ATF -> OP-TEE -> A53 SPL -> U-Boot -> Kernel
Falcon boot:  R5 SPL -> ATF -> OP-TEE -> Kernel          (no A53 SPL, no U-Boot)
```

The R5 SPL loads a cut-down `tifalcon.bin` (ATF+OP-TEE+DM, no A53 SPL) plus a
`fitImage` (kernel + dtb) and jumps straight into Linux. It saves the
U-Boot-proper init time.

> AM62x board is **GP** (general-purpose) silicon, so the main flow uses an
> **unsigned** `fitImage` and does not need `core-secdev-k3`.  (It is optional)
> HS-FS / HS-SE boards must sign it — see **Appendix C**.

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

## States through the procedure (what you have before / after)

The runbook has four logical stages. Each row reads "start state → end state":

| Stage (sections) | Start state | End state |
|---|---|---|
| **Build artifacts (1–4)** | Clean SDK with the AM62x_porting repo overlaid; no Falcon artifacts; the board's normal boot (NAND/eMMC) untouched | Falcon build outputs exist on the build machine: `$R5O/tiboot3.bin`, `$A53O/tifalcon.bin`, `$FITDIR/fitImage`. **No SD card written yet.** |
| **Assemble + boot (5–6)** | Artifacts from 1–4, plus a **blank** SD card | A Falcon SD card running the **TI Arago** image; boots straight into Linux, no U-Boot stage. |
| **Clone Ubuntu (7)** | A Falcon card from 5–6 **and** a separate, working **normal-boot Ubuntu** SD card | The Falcon card now runs **Ubuntu**; the normal-boot Ubuntu card is read-only-copied and left **unchanged**. |
| **In-place convert (Appendix D)** | A working **normal-boot Ubuntu** SD card, plus artifacts from 1–4 | That **same** card now Falcon-boots Ubuntu (its boot SPL is replaced; the original `tiboot3.bin` is backed up). |

**Two ways to end up Falcon-booting Ubuntu:**
- **Two cards:** do 1–6 (makes a Falcon/Arago card), then **Section 7** (clone your Ubuntu onto it). Your normal card is never modified.
- **One card:** do 1–4, then **Appendix D** (convert your Ubuntu card in place).

> **Section 7 needs an existing normal-boot Ubuntu SD card as its source.**
> Creating that card (partitioning, U-Boot, kernel, Ubuntu rootfs) is documented
> **separately** — see *‹your normal-boot Ubuntu SD-card setup guide›*. This
> runbook covers only the Falcon conversion, not the normal Ubuntu install.

## Prerequisites

1. **Device type = GP** (general-purpose — AM62x). Confirm from a normal
   boot's serial log: `Device Type: GP`, or the Falcon SPL printing
   `Skipping authentication on GP device`. On GP the kernel `fitImage` is
   **unsigned** and **`core-secdev-k3` is not required** — the main flow below is
   the GP path.
2. **HS-FS / HS-SE boards only:** the `fitImage` must be signed (needs
   `core-secdev-k3`). That is **not** part of the main flow — see **Appendix C**.

---

## Section 0 — Environment (paste once per shell)

```bash
export TI_SDK_PATH=$HOME/ti-processor-sdk-linux-am62xx-evm-11.02.08.02   # adjust if your SDK lives elsewhere
export CROSS_COMPILE=$TI_SDK_PATH/linux-devkit/sysroots/x86_64-arago-linux/usr/bin/aarch64-oe-linux/aarch64-oe-linux-
export CROSS_COMPILE_ARMV7=$TI_SDK_PATH/k3r5-devkit/sysroots/x86_64-arago-linux/usr/bin/arm-oe-eabi/arm-oe-eabi-
export SDK_PATH_TARGET=$TI_SDK_PATH/linux-devkit/sysroots/aarch64-oe-linux
export CC="${CROSS_COMPILE}gcc --sysroot=$SDK_PATH_TARGET"

export UBOOT=$TI_SDK_PATH/board-support/ti-u-boot-2025.01+git
export KERN=$TI_SDK_PATH/board-support/ti-linux-kernel-6.12.57+git-ti
export TFA=$TI_SDK_PATH/board-support/trusted-firmware-a-2.13+git
export FW=$TI_SDK_PATH/board-support/prebuilt-images/am62xx-evm
export DM=$FW/ti-dm/am62xx/ipc_echo_testb_mcu1_0_release_strip.xer5f

export R5O=$TI_SDK_PATH/board-support/u-boot-build/r5-falcon
export A53O=$TI_SDK_PATH/board-support/u-boot-build/a53-falcon
export BL31_FALCON=$TFA/build/k3/lite/release/bl31.bin
export FITDIR=$TI_SDK_PATH/board-support/falcon-fit          # where the (GP, unsigned) fitImage is built
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
  <path-to>/AM62x_porting/  $TI_SDK_PATH/
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
grep -E 'CONFIG_SPL_OS_BOOT=|CONFIG_SPL_OS_BOOT_SECURE|CONFIG_SPL_FALCON_ALLOW_FALLBACK=' $R5O/.config
#   GP expects: SPL_OS_BOOT=y, SPL_OS_BOOT_SECURE "is not set", FALCON_ALLOW_FALLBACK=y
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

## Section 4 — Build kernel + Falcon `fitImage` (GP, unsigned)

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

### 4c. Build the (unsigned) FIT — GP

On GP the kernel and dtb are packaged **as-is** (no `.sec`, no `core-secdev-k3`):

```bash
mkdir -p $FITDIR && cd $FITDIR
cp $KERN/arch/arm64/boot/Image  Image
cp /tmp/falcon.dtb              falcon.dtb

cat > fitImage.its << 'EOF'
/dts-v1/;

/ {
    description = "Kernel fitImage for falcon mode";
    #address-cells = <1>;

    images {
        kernel-1 {
            description = "Linux kernel";
            data = /incbin/("Image");
            type = "kernel";
            arch = "arm64";
            os = "linux";
            compression = "none";
            load = <0x82000000>;
            entry = <0x82000000>;
        };
        falcon.dtb {
            description = "Flattened Device Tree blob";
            data = /incbin/("falcon.dtb");
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
            description = "Kernel and DTB";
            kernel = "kernel-1";
            fdt = "falcon.dtb";
        };
    };
};
EOF

$A53O/tools/mkimage -f fitImage.its fitImage
ls -l $FITDIR/fitImage
```

`mkimage` is built by U-Boot (here `$A53O/tools/mkimage`); it is not a system
command. (HS-FS/HS-SE: build a **signed** FIT instead — see Appendix C.)

---

## Section 5 — Assemble the SD card

Falcon needs exactly **3 files**:

| File | Source | Card location | Partition |
|------|--------|---------------|-----------|
| `tiboot3.bin` | `$R5O/tiboot3.bin` | `/tiboot3.bin` | p1 boot (FAT) |
| `tifalcon.bin` | `$A53O/tifalcon.bin` | `/boot/tifalcon.bin` | p2 rootfs (ext4) |
| `fitImage` | `$FITDIR/fitImage` | `/boot/fitImage` | p2 rootfs (ext4) |

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

> This installs the **TI Arago** image (`tisdk-default-image`), so the finished
> card Falcon-boots **Arago, not Ubuntu**. To Falcon-boot **Ubuntu**, run
> Sections 1–6 as-is, then do **Section 7** to clone your Ubuntu rootfs onto this
> card (or use **Appendix D** to convert an existing Ubuntu card in place).

```bash
sudo mkdir -p /mnt/fboot /mnt/froot
sudo mount ${SD}${P}1 /mnt/fboot
sudo mount ${SD}${P}2 /mnt/froot

# p1 (FAT): only the Falcon R5 SPL
sudo cp $R5O/tiboot3.bin /mnt/fboot/tiboot3.bin

# p2 (ext4): rootfs, then the two Falcon payloads under /boot
sudo tar --numeric-owner -xpf $TI_SDK_PATH/filesystem/am62xx-evm/tisdk-default-image-am62xx-evm.rootfs.tar.xz -C /mnt/froot
sudo cp $A53O/tifalcon.bin /mnt/froot/boot/tifalcon.bin
sudo cp $FITDIR/fitImage   /mnt/froot/boot/fitImage

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
2. Connect serial console: `ttyS2`, 115200 8N1. (It is marked as UART0 on the board.")
3. Insert the card, power on.
4. **Success:** R5 SPL banner, then Linux boots **directly** — no
   `U-Boot 2025.01...` banner, no boot countdown. That absence proves Falcon ran.
5. **Failure / hang:** flip the boot-mode switch back to NAND/eMMC (or pull the
   card) and power-cycle. Production boot is untouched. Read the serial log to
   see the last R5 SPL stage reached.

---

## Section 7 — Reuse an existing OS: clone a normal-boot card's rootfs onto the Falcon card

Use this when you already built the Falcon artifacts (Sections 2–4) and have a
Falcon card (Section 5), but you want Falcon to boot an **existing OS** (e.g. your
production Ubuntu on its own normal-boot SD card) instead of the TI default image.

**Requires three things — all must exist before you start:**
1. The Falcon build artifacts — **Sections 1–4** (`$A53O/tifalcon.bin`, `$FITDIR/fitImage`).
2. A **Falcon card** as the *target* — **Sections 5–6** (its p1 carries the Falcon `tiboot3.bin`; this is the card identified by `/boot/tifalcon.bin` below).
3. A working **normal-boot Ubuntu SD card** as the *source*. Building that card
   (partitioning, U-Boot, kernel, Ubuntu rootfs) is **not** covered here — it is
   documented **separately**; see *‹your normal-boot Ubuntu SD-card setup guide›*.

Section 7 does **not** by itself turn a lone Ubuntu card into a Falcon card — for
that single-card path use **Appendix D** instead.

It copies the rootfs **from** your normal-boot card **onto** the Falcon card's
partition 2, keeping the Falcon boot files. Key safety points:
- The normal-boot card is mounted **read-only** and only read — it is **never
  modified**, so its normal boot keeps working.
- Only **partition 2** of the Falcon card is changed; its p1 (FAT) Falcon
  `tiboot3.bin` is left intact.
- Falcon derives `root=PARTUUID=…` at runtime from this card's p2, so the cloned
  rootfs boots regardless of its PARTUUID — no env changes needed.

Assumes one card reader, so the rootfs goes through a tarball on the build
machine. **Source the Section 0 environment first** (`$A53O`, `$FITDIR`, `$KERN`,
`$CROSS_COMPILE` come from there).

> Desktop auto-mount note: when you insert a card, the desktop usually
> **auto-mounts** it. A "find the unmounted ext4 partition" loop will then skip
> it. So below we identify the partition with `lsblk` and target it directly.

### PHASE 1 — Capture the rootfs off the normal-boot card (read-only)

**7.1 Insert the normal-boot SD card. Identify it:**
```bash
lsblk -o NAME,SIZE,FSTYPE,LABEL,MOUNTPOINT,MODEL
```
Find the SD card by size/model. Note its **ext4 rootfs partition** (usually
partition 2, e.g. `/dev/sda2` or `/dev/mmcblk0p2`).

**7.2 Mount it READ-ONLY and confirm it is the right OS:**
```bash
SRC=/dev/sda2                       # <-- the rootfs partition you identified
sudo umount "$SRC" 2>/dev/null      # drop any desktop auto-mount
sudo mkdir -p /mnt/src
sudo mount -o ro "$SRC" /mnt/src
head -2 /mnt/src/etc/os-release ; cat /mnt/src/etc/hostname ; ls /mnt/src
```
You should see your expected distro (e.g. `Ubuntu 20.04`), the hostname, and a
normal rootfs (`bin etc home lib usr var …`). It is mounted read-only — safe.

**7.3 Tar the whole rootfs to the build machine:**
```bash
df -h $HOME                         # make sure several GB are free
sudo tar -C /mnt/src --numeric-owner --xattrs --acls -cpzf $HOME/rootfs.tar.gz .
sudo umount /mnt/src
```
Now **remove the normal-boot card** (it was only read).

### PHASE 2 — Write that rootfs onto the Falcon card

**7.4 Insert the Falcon card. Identify and confirm it (has `/boot/tifalcon.bin`):**
```bash
lsblk -o NAME,SIZE,FSTYPE,MOUNTPOINT,MODEL
DST=/dev/sda2                       # <-- the Falcon card's ext4 partition (from lsblk)
sudo umount "$DST" 2>/dev/null
sudo mkdir -p /mnt/dst
sudo mount -o ro "$DST" /mnt/dst
ls -l /mnt/dst/boot/tifalcon.bin    # MUST list -> this is the Falcon card
sudo umount /mnt/dst
```
If `tifalcon.bin` is **not** there, `$DST` is the wrong partition — recheck `lsblk`.

**7.5 Replace the rootfs (guarded so it only wipes the confirmed Falcon card):**
```bash
sudo mount "$DST" /mnt/dst
if [ -f /mnt/dst/boot/tifalcon.bin ]; then
  sudo find /mnt/dst -mindepth 1 -maxdepth 1 -exec rm -rf {} +
  sudo tar -C /mnt/dst --numeric-owner --xattrs --acls -xpzf $HOME/rootfs.tar.gz
  echo "rootfs written"
else
  echo "ABORT: $DST is not the Falcon card (no tifalcon.bin)"; sudo umount /mnt/dst
fi
```

**7.6 Re-add the Falcon payloads (wiped with the old rootfs) and matching modules:**
```bash
sudo mkdir -p /mnt/dst/boot
sudo cp $A53O/tifalcon.bin /mnt/dst/boot/tifalcon.bin
sudo cp $FITDIR/fitImage   /mnt/dst/boot/fitImage
sudo make -C $KERN ARCH=arm64 CROSS_COMPILE=$CROSS_COMPILE \
     INSTALL_MOD_PATH=/mnt/dst modules_install
sudo sync
sudo umount /mnt/dst
```

**7.7 Boot** as in Section 6 — Falcon now lands in your cloned OS.

⚠️ Before the `find … rm -rf` in 7.5, eyeball the `lsblk` size to be sure `$DST`
is the SD card, not another disk. The `tifalcon.bin` guard only wipes a partition
that actually carries the Falcon file, but confirm the device first.

### Section 7 troubleshooting

- **`lsblk: : not a block device` / a `SRC=`/`DST=` variable came out empty:** the
  lookup found nothing — usually the **wrong card is inserted** (e.g. the Arago
  default-image card instead of your OS card), or the desktop **auto-mounted** the
  card so an "unmounted ext4" scan skipped it. Fix: run `lsblk`, read the real
  device, and set `SRC`/`DST` to that partition directly (as in 7.2 / 7.4).
- **Card not listed at all in `lsblk`:** the reader didn't enumerate it — reseat
  it or try another reader; confirm a ~tens-of-GB SD device appears.
- **`tar: … Cannot write: No space left on device` in 7.5:** the Falcon card's p2
  is smaller than the rootfs contents. Use a larger card, or shrink the source.

---

## Appendix A — Gotchas already hit (and their fixes)

- **`make ... bl31` says "Nothing to be done for 'bl31'":** `BL31` is exported in
  the shell, so TF-A skips building it. Fix: `unset BL31 BL32 BL33 TEE` before
  Section 2 (already in the commands).
- **`mkimage: command not found`:** it is built by U-Boot, not the OS. Use
  `$A53O/tools/mkimage` (or `$R5O/tools/mkimage`), as in Section 4c.
- **`core-secdev-k3 missing`:** only needed for HS-FS/HS-SE signing — clone it
  per Appendix C. GP (AM62x) doesn't need it.
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

## Appendix C — HS-FS / HS-SE boards: signed `fitImage` (replaces the GP steps)

The main flow targets **GP** (AM62x). On **HS-FS / HS-SE** silicon (a normal
boot's log shows `Device Type: HS-FS` or `HS-SE`) TIFS authenticates the kernel
payload, so the `fitImage` **must be signed** with the `core-secdev-k3` package.
Apply these three deltas on top of the main flow.

> Note: this board is GP, where signed images **also** boot
> (`Skipping authentication on GP device`), so signing is optional here — it was
> used during initial bring-up. The GP/unsigned main flow is the simpler route.

**C.0 — Extra env var for this appendix** (the GP main flow does not define it):
```bash
export SECDEV=$TI_SDK_PATH/board-support/core-secdev-k3
```

**C.1 — Get `core-secdev-k3`** (the signing package; not shipped in the SDK):
```bash
ls $SECDEV/scripts/secure-binary-image.sh 2>/dev/null || \
  git clone https://git.ti.com/git/security-development-tools/core-secdev-k3.git $SECDEV
```

**C.2 — Re-enable secure OS-boot in the fragment, then rebuild R5 (Section 3b):**
```bash
sed -i 's/^# CONFIG_SPL_OS_BOOT_SECURE is not set/CONFIG_SPL_OS_BOOT_SECURE=y/' $UBOOT/configs/k3_r5_falcon.config
sed -i '/^CONFIG_SPL_FALCON_ALLOW_FALLBACK=y/d'                                  $UBOOT/configs/k3_r5_falcon.config
# then re-run Section 3b
```

**C.3 — Replace Section 4c with a signed FIT** (sign, then package the `.sec`
files; finally copy into `$FITDIR` so Sections 5/7/D are unchanged):
```bash
cd $SECDEV
cp $KERN/arch/arm64/boot/Image  Image
cp /tmp/falcon.dtb              falcon.dtb
./scripts/secure-binary-image.sh Image      Image.sec
./scripts/secure-binary-image.sh falcon.dtb falcon.dtb.sec
# Use the Section 4c fitImage.its but change the two data lines to the signed names:
#   data = /incbin/("Image.sec");        (kernel-1)
#   data = /incbin/("falcon.dtb.sec");   (falcon.dtb)
$A53O/tools/mkimage -f fitImage.its fitImage
mkdir -p $FITDIR && cp $SECDEV/fitImage $FITDIR/fitImage
```

## Appendix D — In-place convert a single Ubuntu card to Falcon (one card, no cloning)

Use this when you have **one** working normal-boot Ubuntu SD card and want *that
card itself* to Falcon-boot — no second card, no rootfs copying. It needs the
Falcon artifacts built first (**Sections 1–4**). It **modifies** the card
(replaces the boot-partition SPL) but backs up the original so you can revert.

- **Start state:** a working normal-boot Ubuntu SD card + built artifacts (1–4).
- **End state:** that same card Falcon-boots Ubuntu (normal-boot SPL backed up).

**D.1 — Insert the Ubuntu card; identify and mount both partitions**
(the desktop auto-mount note from Section 7 applies — target devices directly):
```bash
lsblk -o NAME,SIZE,FSTYPE,LABEL,MOUNTPOINT,MODEL
BOOTP=/dev/sda1      # <-- FAT boot partition (from lsblk)
ROOTP=/dev/sda2      # <-- ext4 Ubuntu rootfs partition (from lsblk)
sudo umount "$BOOTP" "$ROOTP" 2>/dev/null
sudo mkdir -p /mnt/fb /mnt/fr
sudo mount "$BOOTP" /mnt/fb
sudo mount "$ROOTP" /mnt/fr
head -2 /mnt/fr/etc/os-release ; ls -l /mnt/fb/tiboot3.bin   # confirm Ubuntu rootfs + existing SPL
```

**D.2 — Back up the normal SPL, install the Falcon SPL on p1:**
```bash
sudo cp -a /mnt/fb/tiboot3.bin /mnt/fb/tiboot3.bin.normal.bak
sudo cp $R5O/tiboot3.bin /mnt/fb/tiboot3.bin
```

**D.3 — Add the Falcon payloads to p2 /boot + install matching modules:**
```bash
sudo cp $A53O/tifalcon.bin /mnt/fr/boot/tifalcon.bin
sudo cp $FITDIR/fitImage   /mnt/fr/boot/fitImage
sudo make -C $KERN ARCH=arm64 CROSS_COMPILE=$CROSS_COMPILE \
     INSTALL_MOD_PATH=/mnt/fr modules_install
sudo sync
sudo umount /mnt/fb /mnt/fr
```

**D.4 — Boot** as in Section 6 → Falcon → Ubuntu.

**Revert this card to normal boot:**
```bash
sudo mount "$BOOTP" /mnt/fb
sudo cp -a /mnt/fb/tiboot3.bin.normal.bak /mnt/fb/tiboot3.bin
sudo umount /mnt/fb
```

## Memory map reference (1 GB DDR4, fits TI's SK map)

```
0x80000000  ATF (BL31)            CONFIG_K3_ATF_LOAD_ADDR
0x82000000  Kernel (fitImage)     PRELOADED_BL33_BASE / SPL_LOAD_FIT_ADDRESS
0x88000000  Kernel DTB            K3_HW_CONFIG_BASE / SPL_PAYLOAD_ARGS_ADDR
0x89000000  Device Manager (DM)
0x9e800000  OP-TEE (BL32)         CONFIG_K3_OPTEE_LOAD_ADDR
```
