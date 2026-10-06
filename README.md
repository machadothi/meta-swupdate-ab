# meta-swupdate-ab

**A Yocto layer template for production-grade Over-The-Air (OTA) software updates
using [SWUpdate](https://sbabic.github.io/swupdate/) with A/B dual-rootfs partitioning.**

Supports any Yocto-based embedded Linux project. One configuration file, one init
script, and you have a fully functional OTA update infrastructure.

---

## Table of Contents

1. [What Is This?](#1-what-is-this)
2. [How A/B Updates Work](#2-how-ab-updates-work)
3. [End-to-End Process Diagram](#3-end-to-end-process-diagram)
4. [Prerequisites](#4-prerequisites)
5. [Quick Start](#5-quick-start)
6. [Configuration Reference](#6-configuration-reference)
7. [Adding to Your Yocto Build](#7-adding-to-your-yocto-build)
8. [U-Boot Configuration](#8-u-boot-configuration)
9. [Building the Update Package](#9-building-the-update-package)
10. [Deploying an Update](#10-deploying-an-update)
11. [Rollback Mechanism](#11-rollback-mechanism)
12. [RSA Signing](#12-rsa-signing)
13. [Troubleshooting](#13-troubleshooting)
14. [Advanced: Customizing Update Scripts](#14-advanced-customizing-update-scripts)
15. [Advanced: Adding More Machines](#15-advanced-adding-more-machines)
16. [File Reference](#16-file-reference)

---

## 1. What Is This?

### The Problem

Updating software on embedded devices is risky. If the update process is interrupted
(power loss, network drop) or the new software has a bug, the device can become
permanently unusable — "bricked". For field-deployed devices, this is catastrophic.

### The Solution: A/B Updates

Instead of updating the active filesystem in place, the device keeps **two complete
copies** of the operating system on separate partitions (Slot A and Slot B). Updates
are written to the **inactive** slot while the system continues running from the
active slot. Only after a successful reboot into the new version is the update
considered committed.

If anything goes wrong, the bootloader automatically reverts to the last known-good
slot. The device is never left in an unusable state.

### What SWUpdate Does

[SWUpdate](https://github.com/sbabic/swupdate) is an open-source update agent that
runs on the embedded device and handles:

- Receiving update packages (`.swu` files) via USB, HTTP, or a management server
- Verifying hardware compatibility and cryptographic signatures
- Writing the new image to the inactive partition
- Updating the bootloader configuration to switch to the new partition
- Triggering reboot

### What This Layer Provides

This Yocto layer integrates SWUpdate into your build and adds:

| Component | Purpose |
|-----------|---------|
| `swupdate_%.bbappend` | Configures the upstream SWUpdate build for your hardware |
| `update-image.bb` | Builds the `.swu` update package |
| `check-update-ota` | Systemd service that commits updates after successful boot |
| `ota-update` | Command-line tool for installing updates from files |
| Pre/post-install scripts | Handle partition detection, filesystem repair, config preservation |

---

## 2. How A/B Updates Work

```
                    STORAGE DEVICE (e.g., /dev/mmcblk2)
┌───────────────┬─────────────────────┬─────────────────────┐
│  Boot (p1)    │   Rootfs A (p2)     │   Rootfs B (p3)     │
│  Kernel + DTB │   Active system     │   (inactive/backup) │
└───────────────┴─────────────────────┴─────────────────────┘
                        ↑ Currently running

                         UPDATE SEQUENCE

Step 1: SWUpdate writes new image to Slot B (inactive)
        ┌───────────────┬─────────────────────┬─────────────────────┐
        │  Boot (p1)    │   Rootfs A (p2)     │   NEW IMAGE (p3)    │
        └───────────────┴─────────────────────┴─────────────────────┘
                                ↑ Running              ↑ Being written

Step 2: SWUpdate updates U-Boot to boot from Slot B
        U-Boot env: rootfspart=3, upgrade_available=1, bootcount=0

Step 3: System reboots
        ┌───────────────┬─────────────────────┬─────────────────────┐
        │  Boot (p1)    │   Rootfs A (p2)     │   NEW IMAGE (p3)    │
        └───────────────┴─────────────────────┴─────────────────────┘
                                                     ↑ Now running

Step 4: checkUpdateOTA.sh runs at startup
        If boot succeeded: clears upgrade_available → update committed ✓

Step 5 (if boot FAILED): U-Boot counts failures
        When bootcount > bootlimit → automatic rollback to Slot A ✓
```

**The key guarantee:** The device is ALWAYS running either the new version or the
old version. There is no intermediate broken state.

---

## 3. End-to-End Process Diagram

The full sequence — from adding this layer to your project all the way to a
committed update on the device — is documented as an interactive UML sequence
diagram in:

**[docs/process-diagram.md](docs/process-diagram.md)**

It covers all 6 phases in a single view:

| Phase | What happens |
|-------|-------------|
| **1 — Layer Setup** | Clone, configure, run `init-layer.sh`, wire into bblayers.conf |
| **2 — Key Management** | Generate or import RSA key pair; public key baked into device image |
| **3 — Build** | `bitbake update-image` packs rootfs + scripts + manifest, optionally signs |
| **4 — Distribution** | Upload to HTTP server, Hawkbit, USB, or SCP to device |
| **5 — Installation** | SWUpdate verifies, writes inactive partition, updates U-Boot env, reboots |
| **6 — Boot & Commit** | U-Boot boots new slot; `checkUpdateOTA` commits or U-Boot rolls back |

---

## 4. Prerequisites

### Build Host Requirements

| Tool | Purpose | Install (Ubuntu/Debian) |
|------|---------|------------------------|
| `bash` ≥ 4.0 | Required by `init-layer.sh` | Usually pre-installed |
| `openssl` | Generate RSA key pair | `apt install openssl` |
| Yocto build environment | Build system | See [Yocto Quick Start](https://docs.yoctoproject.org/brief-yoctoprojectqs/index.html) |

### Yocto Layer Dependencies

Your `bblayers.conf` must include these layers **before** this one:

| Layer | Source |
|-------|--------|
| `meta` | Poky (core Yocto layer) |
| `meta-swupdate` | `git clone https://github.com/sbabic/meta-swupdate.git` |

Check compatibility: `meta-swupdate` supports the same Yocto releases listed in
`YOCTO_RELEASES` in your `layer.config`.

### Target Hardware Requirements

| Requirement | Details |
|-------------|---------|
| A/B partition layout | Two rootfs partitions of equal size |
| U-Boot bootloader | With environment variable support (`fw_printenv`/`fw_setenv`) |
| `fw_env.config` | Tells U-Boot tools where the env is stored (board-specific) |
| U-Boot variables | `bootlimit`, `bootcount`, `upgrade_available` (see Section 8) |

### Supported Yocto Releases

Tested with: **kirkstone, langdale, mickledore, nanbield, scarthgap**

Likely works on older releases (honister, hardknott) but not tested.

---

## 5. Quick Start

```bash
# 1. Clone this repository
git clone https://github.com/your-org/meta-swupdate-ab.git
cd meta-swupdate-ab

# 2. Copy and edit the configuration file
cp layer.config.example layer.config
nano layer.config     # Fill in YOUR project values (see Section 6)

# 3. Run the initialization script
./init-layer.sh layer.config

# 4. Add the layer to your Yocto build (see Section 7)
# 5. Configure U-Boot for A/B boot (see Section 8)
# 6. Build your update package (see Section 9)
bitbake update-image
```

That's it. Your `.swu` file is in `<build>/tmp/deploy/images/<machine>/`.

---

## 6. Configuration Reference

All configuration lives in your `layer.config` file (copy from `layer.config.example`).

### Section 1: Project Identity

| Variable | Type | Example | Description |
|----------|------|---------|-------------|
| `PROJECT_NAME` | string | `"gateway"` | Short project identifier. No spaces, lowercase. Used in layer name and recipe paths. |
| `LAYER_PRIORITY` | integer | `"9"` | Yocto layer priority. Higher overrides lower. Default 9 is safe for most projects. |
| `YOCTO_RELEASES` | string | `"kirkstone langdale"` | Space-separated list of compatible Yocto codenames. |

### Section 2: Machines

| Variable | Type | Example | Description |
|----------|------|---------|-------------|
| `MACHINES` | array | `("board-v1" "board-v2")` | Yocto machine names. Must match `MACHINE=` in your `local.conf`. |
| `HW_IDS` | array | `("hw-v1" "hw-v2")` | Hardware identifiers. Written to `/etc/hwrevision`. Must match order of `MACHINES`. |
| `HW_VERSION` | string | `"1.0"` | Hardware version. Applied to all machines. |
| `HW_COMPAT_VERSIONS` | string | `"1.0 2.0"` | Space-separated list of hardware versions this update is compatible with. |

**How hardware compatibility works:**

SWUpdate reads `/etc/hwrevision` on the target device (e.g., `my-board 1.0`).
Before installing, it checks that the device's hardware version is in the
`HW_COMPAT_VERSIONS` list in `sw-description`. If not, it refuses to install.

This prevents accidentally installing a board-V2 image on a board-V1 device.

### Section 3: Storage Partitions

| Variable | Type | Example | Description |
|----------|------|---------|-------------|
| `EMMC_DEVICE` | string | `"/dev/mmcblk2"` | Block device for your main storage. |
| `ROOTFS_A_PART` | integer | `"2"` | Partition number for rootfs slot A. |
| `ROOTFS_B_PART` | integer | `"3"` | Partition number for rootfs slot B. |

**Finding your partition layout:**

```bash
# On a running device, check which device holds rootfs:
cat /proc/cmdline | grep -o 'root=[^ ]*'

# List all partitions:
lsblk
# or:
cat /proc/partitions
```

**Typical layouts:**

```
# Example: eMMC with 3 partitions
/dev/mmcblk2p1   Boot (kernel + DTB)
/dev/mmcblk2p2   Rootfs A  ← ROOTFS_A_PART="2"
/dev/mmcblk2p3   Rootfs B  ← ROOTFS_B_PART="3"

EMMC_DEVICE="/dev/mmcblk2"
```

### Section 4: Base Image

| Variable | Type | Example | Description |
|----------|------|---------|-------------|
| `BASE_IMAGE` | string | `"core-image-minimal"` | The Yocto image recipe you normally build. |
| `IMAGE_FSTYPE` | string | `"ext4"` | Filesystem type (must be in `IMAGE_FSTYPES` in your image). |
| `SW_VERSION` | string | `"1.0.0"` | Version string for this OTA package. |

### Section 5: Device Identification

| Variable | Type | Example | Description |
|----------|------|---------|-------------|
| `IDENTIFY_NAME` | string | `"product"` | Key for device identification in OTA server. |
| `IDENTIFY_VALUES` | array | `("gateway-v1" "gateway-v2")` | Value per machine. Must match order of `MACHINES`. |

### Section 6: RSA Signing

| Variable | Type | Example | Description |
|----------|------|---------|-------------|
| `ENABLE_SIGNING` | yes/no | `"no"` | Enable RSA signature verification. |
| `GENERATE_KEYS` | yes/no | `"yes"` | Auto-generate RSA key pair in `keys/`. |

See [Section 12: RSA Signing](#12-rsa-signing) for details.

### Section 7: Web Server

| Variable | Type | Example | Description |
|----------|------|---------|-------------|
| `ENABLE_WEBSERVER` | yes/no | `"no"` | Build SWUpdate's web server (port 8080) for push updates. It has **no authentication**: only enable it with signing on or on a trusted network. Defaults to `no` if unset. |

---

## 7. Adding to Your Yocto Build

### Step 1: Add the layer to bblayers.conf

Open `<build-dir>/conf/bblayers.conf` and add this layer and `meta-swupdate`:

```bitbake
BBLAYERS ?= " \
  /path/to/poky/meta \
  /path/to/poky/meta-poky \
  /path/to/meta-openembedded/meta-oe \
  /path/to/meta-swupdate \
  /path/to/meta-swupdate-ab \
"
```

> **Order matters.** `meta-swupdate` must appear **before** `meta-swupdate-ab`.

### Step 2: Install SWUpdate on your image

Add to your image recipe or `local.conf`:

```bitbake
# In your image .bb file:
IMAGE_INSTALL:append = " swupdate check-update-ota libubootenv-bin"

# Or in local.conf for development:
CORE_IMAGE_EXTRA_INSTALL += "swupdate check-update-ota libubootenv-bin"
```

| Package | Purpose |
|---------|---------|
| `swupdate` | The update daemon |
| `swupdate-www` | Optional: web interface files, only with `ENABLE_WEBSERVER="yes"` |
| `check-update-ota` | Rollback guard service (from this layer) |
| `libubootenv-bin` | Provides `fw_printenv`/`fw_setenv` (`u-boot-tools` does not) |

### Step 3: Configure IMAGE_FSTYPES

Your image recipe must produce a `.gz` compressed image. Add to your image:

```bitbake
IMAGE_FSTYPES:append = " ext4.gz"
```

Or in `local.conf`:

```bash
IMAGE_FSTYPES:append = " ext4.gz"
```

### Step 4: Verify the layer is recognised

```bash
bitbake-layers show-layers | grep swupdate
```

Expected output:
```
meta-swupdate          /path/to/meta-swupdate         7
meta-swupdate-ab       /path/to/meta-swupdate-ab      9
```

---

## 8. U-Boot Configuration

This is the most hardware-specific part. U-Boot must be configured to:

1. Read a `bootcount` variable and increment it on each boot attempt
2. If `bootcount` exceeds `bootlimit`, switch to the other rootfs
3. Boot from the partition specified by `rootfspart` and `mmcroot`

### Required U-Boot Environment Variables

Set these in your U-Boot default environment (`include/configs/<board>.h` or
`u-boot-<board>.bbappend` in your BSP):

```
# Maximum boot attempts before rollback
bootlimit=3

# Boot counter (reset to 0 after successful boot by checkUpdateOTA.sh)
bootcount=0

# Flag set by SWUpdate when an update is installed (1=pending, 0=committed)
upgrade_available=0

# Which partition to boot from (2=Slot A, 3=Slot B)
rootfspart=2

# Root device string passed to kernel
mmcroot=/dev/mmcblk2p2 rootwait rw
```

### U-Boot Boot Script Logic

Add to your U-Boot boot script (typically `bootcmd` or a separate script):

```
# Increment boot counter if an upgrade is pending
if test "${upgrade_available}" = "1"; then
    setexpr bootcount ${bootcount} + 1
    saveenv
fi

# Rollback check
if test ${bootcount} -gt ${bootlimit}; then
    echo "Boot failed ${bootcount} times — rolling back!"
    if test "${rootfspart}" = "2"; then
        setenv rootfspart 3
        setenv mmcroot /dev/mmcblk2p3 rootwait rw
    else
        setenv rootfspart 2
        setenv mmcroot /dev/mmcblk2p2 rootwait rw
    fi
    setenv upgrade_available 0
    setenv bootcount 0
    saveenv
fi

# Boot from the selected partition
setenv bootargs "root=${mmcroot} console=ttymxc0,115200"
# ... rest of your boot command
```

> **Prefer U-Boot's built-in boot counting** if your BSP supports it:
> `CONFIG_BOOTCOUNT_LIMIT` increments `bootcount` while `upgrade_available=1`
> and runs `altbootcmd` (where you switch slots) once `bootlimit` is exceeded.

> **Rollback needs a reboot.** A kernel panic or a hung boot only leads to a
> rollback if the device actually reboots. Add `panic=5` to `bootargs` and
> enable a hardware watchdog (U-Boot `CONFIG_WDT`, systemd `RuntimeWatchdogSec=`).

> **BSP-specific:** The exact U-Boot configuration depends on your board's BSP.
> Consult your board's documentation or ask your BSP vendor. The above is a
> simplified example for i.MX8 boards.

### fw_env.config

The `checkUpdateOTA.sh` script uses `fw_printenv`/`fw_setenv` to read and write
U-Boot environment variables. These tools need `/etc/fw_env.config` to know where
the U-Boot environment is stored.

Create `recipes-bsp/u-boot/files/fw_env.config` in your BSP layer:

```
# /etc/fw_env.config
# Columns: Device, Offset, Size, EraseSize, Number of env copies
# Example for eMMC-based boards:
/dev/mmcblk2  0x400000  0x4000
```

> The exact values depend on your U-Boot configuration. Check your board's U-Boot
> source for `CONFIG_ENV_OFFSET` and `CONFIG_ENV_SIZE`.

---

## 9. Building the Update Package

### Prerequisites

- Your base image builds successfully: `bitbake <BASE_IMAGE>`
- SWUpdate is installed in your image

### Build Command

```bash
# Set the target machine (same as normal builds)
export MACHINE=mymachine-v1

# Build the OTA update package
bitbake update-image
```

### Output

The `.swu` file is a CPIO archive (like a zip file) containing:
- `sw-description` — the update manifest
- `<BASE_IMAGE>-<MACHINE>.ext4.gz` — the compressed rootfs image
- `update-post.sh` — the post-install script

Location: `<build-dir>/tmp/deploy/images/<machine>/update-image-<machine>.swu`

### SHA256 Hashes

The generated `sw-description` uses `$swupdate_get_sha256(<file>)`, so the
`swupdate` class fills in the hash of every artifact at build time. There is
nothing to edit by hand.

---

## 10. Deploying an Update

### Method 1: USB Drive (simplest)

Copy the `.swu` file to a USB drive, plug it into the device, then:

```bash
# On the device:
ota-update /media/usb/update-image-mymachine-v1.swu
```

The device will install the update and automatically reboot.

### Method 2: Web Interface (push from browser or curl)

Requires `ENABLE_WEBSERVER="yes"` in `layer.config` (off by default: the web
server has no authentication). SWUpdate then serves port 8080. Make sure your
device is on the network, then:

```bash
# From your computer:
curl -F "image=@update-image-mymachine-v1.swu" http://<device-ip>:8080/upload

# Or open in a browser:
http://<device-ip>:8080
```

> The browser interface also needs `swupdate-www` installed on the device.

### Method 3: SCP then run locally

```bash
# Copy to device:
scp update-image-mymachine-v1.swu root@<device-ip>:/tmp/

# Install on device:
ssh root@<device-ip> 'ota-update /tmp/update-image-mymachine-v1.swu'
```

### What Happens During an Update

1. `ota-update` detects which partition is active and selects the correct slot
2. SWUpdate verifies hardware compatibility (checks `/etc/hwrevision`)
3. SWUpdate verifies signature (if signing is enabled)
4. The rootfs image is streamed and written to the inactive partition
5. `update-post.sh` copies network config, runs `e2fsck`, resizes filesystem
6. U-Boot env is updated: `rootfspart`, `mmcroot`, `upgrade_available=1`
7. System reboots into the new partition
8. `checkUpdateOTA.sh` runs the health checks in `/etc/ota-health.d/` and, if
   they pass, clears `upgrade_available` — update committed

---

## 11. Rollback Mechanism

### How It Works

The rollback system has two layers of protection:

**Layer 1 — U-Boot boot counter:**
When SWUpdate installs an update, it sets `upgrade_available=1` in U-Boot env.
U-Boot increments `bootcount` on each boot attempt. If `bootcount > bootlimit`,
U-Boot switches back to the previous partition automatically.

**Layer 2 — checkUpdateOTA.sh:**
This script runs at every boot (via systemd `check-update-ota.service`).
If `upgrade_available=1` (meaning a new update just booted), it runs the health
checks in `/etc/ota-health.d/`. If all pass, it clears the flag, "committing"
the update and closing the rollback window. If one fails, or the U-Boot
environment can't be read or written, the unit fails and nothing is committed.

### Rollback Scenarios

| Scenario | What Happens |
|----------|-------------|
| New image fails to boot (kernel panic) | U-Boot increments bootcount; reverts after bootlimit attempts |
| New image boots but key service fails to start | A health check in `/etc/ota-health.d/` fails, nothing is committed; U-Boot reverts after `bootlimit` more boots |
| New image boots fine | `checkUpdateOTA.sh` clears upgrade_available; update committed |
| Network failure during image write | SWUpdate aborts; inactive partition may be partially written but active partition is untouched |

### Checking Rollback Status on the Device

```bash
# Check if an update is pending commit:
fw_printenv upgrade_available

# Check boot counter:
fw_printenv bootcount

# Check rollback limit:
fw_printenv bootlimit

# Check the rollback guard service:
systemctl status check-update-ota
```

### Adjusting the Rollback Window

Set `bootlimit` in your U-Boot environment to the number of failed boots you
want to allow before rolling back. A value of `3` means U-Boot will try the
new partition 3 times before giving up.

```bash
# In U-Boot console:
setenv bootlimit 3
saveenv
```

---

## 12. RSA Signing

### Why Sign Updates?

Without signing, anyone who can send a `.swu` file to your device can install
arbitrary software. RSA signing ensures that only update packages created with
YOUR private key are accepted.

### How It Works

1. At build time: `bitbake update-image` signs the `.swu` with your private key
2. At install time: SWUpdate on the device verifies the signature using the
   public key stored in `/etc/swupdate_public.pem`
3. If verification fails: SWUpdate refuses to install the update

### Enabling Signing

In `layer.config`:

```bash
ENABLE_SIGNING="yes"
GENERATE_KEYS="yes"   # or "no" if you provide your own keys
```

Re-run `init-layer.sh` with `--force` to apply. This regenerates the recipes and
`swupdate.cfg`; existing keys in `keys/` are never overwritten:

```bash
./init-layer.sh layer.config --force
```

This also compiles signature verification into SWUpdate
(`CONFIG_SIGNED_IMAGES=y`). Without it, SWUpdate accepts unsigned packages
whatever `swupdate.cfg` says.

### Key Management for Production

- Generate keys on a **secure, offline machine**
- Store the private key in a **hardware security module (HSM)** or secrets vault
- The public key can be committed to git (it's not secret)
- **Rotate keys** periodically and update `/etc/swupdate_public.pem` on devices
  via a signed update before the old key expires

### Manual Key Generation

```bash
# Generate a 4096-bit private key (use a passphrase for production!)
openssl genrsa -aes256 -out keys/swupdate_priv.pem 4096

# Extract the public key
openssl rsa -in keys/swupdate_priv.pem -pubout -out keys/swupdate_public.pem
```

---

## 13. Troubleshooting

### init-layer.sh fails with "Missing required variable"

Check that all variables in `layer.config` are set and not empty. The error
message names the missing variable.

### bitbake: "Layer 'meta-swupdate-ab' depends on 'swupdate' layer"

The `meta-swupdate` layer is missing from `bblayers.conf`:

```bash
git clone https://github.com/sbabic/meta-swupdate.git
# Add to bblayers.conf
```

### SWUpdate says "HW mismatch"

The hardware ID on the device doesn't match the manifest. Check:

```bash
# On device:
cat /etc/hwrevision
# Should print: <HW_ID> <HW_VERSION>
# e.g.: my-board 1.0

# In sw-description:
# hardware-compatibility: ["1.0", "2.0"]
# The device version must be in this list
```

If they don't match, update `HW_IDS`, `HW_VERSION`, or `HW_COMPAT_VERSIONS`
in `layer.config` and re-run `init-layer.sh`, then rebuild.

### SWUpdate says "Signature verification failed"

Either:
1. The update wasn't signed but the device expects a signature → build the
   update with the same `ENABLE_SIGNING` setting as the device image
2. The keys don't match → rebuild with the correct key pair

### fw_printenv: "Warning: Bad CRC" or environment not found

`/etc/fw_env.config` is incorrect or missing. The offset and size values must
match your U-Boot build configuration (`CONFIG_ENV_OFFSET`, `CONFIG_ENV_SIZE`).
Consult your BSP documentation.

### After update, device doesn't reboot

The `postupdatecmd = "reboot"` in `swupdate.cfg` should trigger automatic reboot.
If it doesn't:
1. Check swupdate logs: `journalctl -u swupdate --no-pager`
2. Reboot manually: `reboot`

### Device keeps rolling back (won't commit update)

`checkUpdateOTA.sh` isn't running or failing. Check:

```bash
systemctl status check-update-ota
journalctl -u check-update-ota --no-pager

# Is fw_setenv working?
fw_setenv test_var test_value
fw_printenv test_var
```

If `fw_setenv` fails, fix `/etc/fw_env.config`.

### SWUpdate logs

```bash
# Real-time logs:
journalctl -u swupdate -f

# All logs since boot:
journalctl -u swupdate --no-pager

# Or check syslog:
tail -f /var/log/messages | grep swupdate
```

---

## 14. Advanced: Customizing Update Scripts

### update-post.sh — Post-install hook

Located at: `recipes-images/images/update-image/update-post.sh`

This runs after the image is written but before reboot. The default copies
network configuration and checks filesystem integrity.

**To preserve additional configuration files**, add copy commands:

```bash
# Example: Preserve SSH host keys across updates
SSH_DST="${MOUNT_POINT}/etc/ssh"
if [ -d /etc/ssh ]; then
    mkdir -p "$SSH_DST"
    cp /etc/ssh/ssh_host_*_key* "$SSH_DST/" 2>/dev/null || true
fi
```

### checkUpdateOTA.sh — Rollback guard

Located at: `recipes-core/check-update-ota/files/checkUpdateOTA.sh`

**To add custom validation before committing an update**, drop an executable
into `/etc/ota-health.d/` (for example from your image recipe). Every check
there must exit 0, or the update is not committed and U-Boot rolls back after
`bootlimit` boots:

```bash
#!/bin/sh
# /etc/ota-health.d/10-my-service
systemctl is-active --quiet my-critical-service
```

Also order `check-update-ota.service` after the services your checks look at
(`After=` in the unit), so they have started by the time the checks run.

---

## 15. Advanced: Adding More Machines

To add a machine variant after initial setup:

1. Add the machine to `layer.config`:

```bash
MACHINES=("mymachine-v1" "mymachine-v2" "mymachine-v3")
HW_IDS=("my-hw-v1" "my-hw-v2" "my-hw-v3")
IDENTIFY_VALUES=("device-v1" "device-v2" "device-v3")
```

2. Re-run `init-layer.sh` with `--force`:

```bash
./init-layer.sh layer.config --force
```

3. Review the regenerated `swupdate_%.bbappend` and per-machine files.

> `--force` overwrites all generated files. If you have manual edits in the
> generated files, back them up first or apply them again after re-running.
> Keys in `keys/` are never overwritten, so devices in the field keep accepting
> your updates.

---

## 16. File Reference

### Files You Edit (after cloning)

| File | When to Edit |
|------|-------------|
| `layer.config` | Always — your project configuration |
| `static/defconfig` | To change SWUpdate build features |
| Generated `sw-description` | To add extra artifacts |
| Generated `swupdate.cfg` | To tune runtime settings per machine |
| Generated update scripts | To add custom pre/post-install logic |

### Files Generated by init-layer.sh (do not hand-edit)

Re-run `init-layer.sh --force` to regenerate if you change `layer.config`.

| File | Description |
|------|-------------|
| `conf/layer.conf` | Yocto layer registration |
| `recipes-support/swupdate/swupdate_%.bbappend` | SWUpdate recipe extension |
| `recipes-support/swupdate/swupdate/<MACHINE>/09-swupdate-args` | Startup argument script |
| `recipes-support/swupdate/swupdate/<MACHINE>/swupdate.cfg` | Runtime config |
| `recipes-images/images/update-image.bb` | OTA package recipe |
| `recipes-images/images/update-image/<MACHINE>/sw-description` | Update manifest |
| `recipes-core/check-update-ota/check-update-ota.bb` | Rollback guard recipe |

### Static Files (in `static/`, never auto-modified)

| File | Installed at (on device) | Description |
|------|--------------------------|-------------|
| `defconfig` | (build-time only) | SWUpdate kconfig options |
| `update-post.sh` | (runs inside .swu package) | Post-install hook |
| `ota-update.sh` | `/usr/bin/ota-update` | CLI update helper |
| `checkUpdateOTA.sh` | `/usr/bin/checkUpdateOTA.sh` | Rollback guard script (runs `/etc/ota-health.d/*`) |
| `check-update-ota.service` | `${systemd_system_unitdir}/check-update-ota.service` | Systemd unit |
| `check-update-ota.bb` | (build-time only) | Bitbake recipe |

---

## License

MIT — see [SPDX](https://spdx.org/licenses/MIT.html).

SWUpdate is licensed under GPL-2.0. See [sbabic/swupdate](https://github.com/sbabic/swupdate).

---

## Contributing

Issues and pull requests welcome. Please test against at least one real Yocto build
before submitting.

---

*Generated with [meta-swupdate-ab](https://github.com/your-org/meta-swupdate-ab)*
