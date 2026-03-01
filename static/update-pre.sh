#!/bin/sh
# =============================================================================
# update-pre.sh — SWUpdate Pre-Install Script
# =============================================================================
#
# WHEN IT RUNS
#   This script is called by SWUpdate BEFORE writing the new rootfs image to
#   the target partition. It runs on the currently active (running) system.
#
# WHAT IT DOES
#   1. Reads /proc/cmdline to find which partition the system is currently
#      booted from (the "active" partition).
#   2. Determines the "inactive" partition (the one that will receive the update).
#   3. Creates a convenience symlink: /dev/update -> <inactive partition>
#      This lets the sw-description manifest refer to the target as /dev/update
#      without knowing in advance which physical partition it is.
#
# ARGUMENTS
#   $1 = "preinst"  (always, set by SWUpdate)
#
# NOTE
#   This script assumes a standard A/B layout where:
#   - Rootfs A is partition number ROOTFS_A_PART on EMMC_DEVICE
#   - Rootfs B is partition number ROOTFS_B_PART on EMMC_DEVICE
#   These values come from your layer.config and are baked into sw-description.
#   If you change the partition layout after init, update sw-description too.
# =============================================================================

set -e

case "$1" in
    preinst)
        echo "[update-pre] Starting pre-install hook"

        # --- Find the currently booted partition ---
        # /proc/cmdline contains the kernel command line, which includes the
        # root= parameter pointing to the active rootfs device.
        CMDLINE=$(cat /proc/cmdline)
        echo "[update-pre] Kernel cmdline: $CMDLINE"

        # Extract the root= device path
        CURRENT_ROOT=$(echo "$CMDLINE" | tr ' ' '\n' | grep '^root=' | head -1 | cut -d= -f2)
        echo "[update-pre] Active root device: $CURRENT_ROOT"

        if [ -z "$CURRENT_ROOT" ]; then
            echo "[update-pre] ERROR: Could not determine active root partition from /proc/cmdline"
            exit 1
        fi

        # --- Determine the inactive (target) partition ---
        # Strip the device path down to the base device (e.g., /dev/mmcblk2)
        # and the partition number.
        BASE_DEV=$(echo "$CURRENT_ROOT" | sed 's/p[0-9]*$//')
        CURRENT_PART=$(echo "$CURRENT_ROOT" | grep -o 'p[0-9]*$' | tr -d 'p')

        # The two rootfs partitions are ROOTFS_A_PART and ROOTFS_B_PART.
        # These are substituted by init-layer.sh:
        PART_A="@@ROOTFS_A_PART@@"
        PART_B="@@ROOTFS_B_PART@@"

        if [ "$CURRENT_PART" = "$PART_A" ]; then
            TARGET_PART="$PART_B"
        elif [ "$CURRENT_PART" = "$PART_B" ]; then
            TARGET_PART="$PART_A"
        else
            echo "[update-pre] ERROR: Current partition $CURRENT_PART is not $PART_A or $PART_B"
            echo "[update-pre] Check your EMMC_DEVICE, ROOTFS_A_PART, ROOTFS_B_PART settings"
            exit 1
        fi

        TARGET_DEV="${BASE_DEV}p${TARGET_PART}"
        echo "[update-pre] Target partition for update: $TARGET_DEV"

        # --- Create the /dev/update symlink ---
        if [ -e /dev/update ]; then
            rm -f /dev/update
        fi
        ln -sf "$TARGET_DEV" /dev/update
        echo "[update-pre] Created symlink: /dev/update -> $TARGET_DEV"

        echo "[update-pre] Pre-install hook complete"
        ;;
    *)
        echo "[update-pre] Unknown argument: $1"
        exit 1
        ;;
esac

exit 0
