# Brainux CM762 Wi-Fi add-on

This repository provides optional UGREEN AX900 / CM762 (AIC8800D80) Wi-Fi
support as a Buildroot external tree. It is intentionally maintained separately
from the general Brainux build: owners of other adapters do not need this tree,
its driver, or its provisioning utility.

The Buildroot option defaults to `y` **when this external tree is included**.
Without it in `BR2_EXTERNAL`, the CM762 package is not part of the build. Other
optional packages can be combined by listing their external trees in the same
colon-separated `BR2_EXTERNAL` value.

## Contents

- `external.desc`, `Config.in`, and `external.mk`: standard Buildroot external
  tree metadata.
- `package/cm762-wifi/`: driver package, firmware installation, USB mode
  switching, and Wi-Fi auto-connect services.
- `tools/configure_cm762_wifi.sh`: safely provision a card's unmounted ext4 root
  partition on macOS.
- `Dockerfile`: adds the ARM EABI cross-compiler needed by this out-of-tree
  kernel module without adding it to the core Buildroot build image.

## Build an image without modifying the Brainux checkout

Use a Brainux checkout as the build host. The commands below leave its tracked
files unchanged; the temporary Buildroot output/rootfs and resulting SD image
are generated artifacts. On macOS, Docker Desktop must be running.

Set paths to the two independent checkouts:

```sh
BRAINUX=/path/to/buildbrain
CM762_ADDON=/path/to/brainux-cm762
```

The add-on builds modules against the checkout's already-built `linux-brain`.
If that kernel has not been built, build it using the normal Brainux kernel
workflow first. Do not rebuild or clean a kernel that has local work you need
to preserve.

Build the ordinary Buildroot container and this add-on's small extension to it:

```sh
make -C "$BRAINUX" docker-buildroot-build
docker build --platform linux/amd64 \
  -t brainux-cm762-build:local \
  -f "$CM762_ADDON/Dockerfile" "$CM762_ADDON"
```

The current top-level `docker-buildroot-full` target does not forward external
trees into its container. To keep the Brainux checkout unchanged, invoke its
existing `buildroot_rootfs` target inside the container with `BR2_EXTERNAL` set,
then use the existing image builder. The external tree is mounted at
`/work/os-buildroot/cm762-addon` so the package can locate the checkout's
`linux-brain` at `/work/linux-brain`; this is only a container mount point and
does not add files to the Brainux checkout.

```sh
BUILD_TMP=$(mktemp -d)
ADDON_MOUNT="$BRAINUX/os-buildroot/cm762-addon"
mkdir -p "$BUILD_TMP/output" "$BUILD_TMP/rootfs"
mkdir -p "$ADDON_MOUNT"

docker run --rm --platform linux/amd64 --privileged \
  -v "$BRAINUX":/work \
  -v "$CM762_ADDON":/work/os-buildroot/cm762-addon:ro \
  -v "$BUILD_TMP/output":/work/buildroot_output \
  -v "$BUILD_TMP/rootfs":/work/buildroot_rootfs \
  -w /work brainux-cm762-build:local \
  bash -lc 'make BR2_EXTERNAL=/work/os-buildroot/cm762-addon buildroot_rootfs'

rmdir "$ADDON_MOUNT"
```

Then assemble an SD image using the existing Brainux image builder. The 256 MiB
size leaves a 64 MiB boot partition and about 191 MiB for the root filesystem.
The separate filename avoids replacing the ordinary `sd_buildroot.img`:

```sh
docker run --rm --platform linux/amd64 --privileged \
  -v "$BRAINUX":/work \
  -v "$BUILD_TMP/rootfs":/work/buildroot_rootfs:ro \
  -w /work buildbrain-builder:local \
  bash -lc 'make -C nkbin_maker clean all && \
    ./image/build_image.sh buildroot_rootfs sd_buildroot_cm762.img 256'
```

The image is written to `"$BRAINUX/image/sd_buildroot_cm762.img"`. Remove the
temporary build directory when finished:

```sh
rm -rf "$BUILD_TMP"
```

For a quick configuration-only check, run Buildroot's `defconfig` target with
`BR2_EXTERNAL` set to the mounted tree and confirm
`BR2_PACKAGE_CM762_WIFI=y` in the generated `.config`.

## Provision Wi-Fi credentials

On macOS, install `e2fsprogs` if needed:

```sh
brew install e2fsprogs
```

With the SD card inserted, run the helper from this repository:

```sh
"$CM762_ADDON/tools/configure_cm762_wifi.sh" /dev/rdiskN
```

It prompts for the SSID and a hidden passphrase, derives the WPA key, safely
checks the unmounted ext4 root partition, writes the configuration and network
service, verifies both files, then ejects the card. The configuration contains
the derived key rather than the plaintext password. Never commit real Wi-Fi
credentials. The default device is `/dev/rdisk7` if no argument is supplied.

Some adapters first appear as AIC's virtual CD-ROM (`a69c:5723`); the `S40`
service switches that mode and loads the driver. After boot, inspect `dmesg`,
`ip link`, and `iw dev`. Actual USB enumeration, radio operation, and network
connectivity require testing with a physical CM762 adapter.

## Kernel and licensing notes

The two `.ko` modules must match the selected, already-built `linux-brain`
kernel (`.config`, `Module.symvers`, and `System.map`). The driver and firmware
are fetched from the upstream community driver repository at the pinned commit
and verified using the package hash. Review that upstream project's license and
terms before redistribution. This add-on does not validate other Wi-Fi adapters
or Brain audio hardware.
