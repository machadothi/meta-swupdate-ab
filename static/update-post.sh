#!/bin/sh
# =============================================================================
# update-post.sh — SWUpdate Post-Install Script
# =============================================================================
#
# WHEN IT RUNS
#   This script is called by SWUpdate AFTER the new rootfs image has been
#   written to the inactive partition. It runs before the system reboots.
#
# WHAT IT DOES
#   1. Mounts the newly updated (inactive) partition at /mnt/rootfs.
#   2. Copies network configuration files from the active system into the
#      new rootfs — so the device keeps its network settings after update.
#   3. Runs filesystem integrity check (e2fsck) on the new partition.
#   4. Runs resize2fs to expand the filesystem to fill the partition.
#      (Needed because the image is typically smaller than the partition.)
#   5. Unmounts and syncs to ensure all writes are flushed to storage.
#
# ARGUMENTS
#   $1 = "postinst"  (always, set by SWUpdate)
#
# CUSTOMIZATION
#   Add extra copy commands under the "Copy preserved files" section to
#   preserve additional configuration files across updates. Common candidates:
#   - /etc/hostname
#   - /etc/localtime
#   - Application-specific config files in /etc/ or /var/
# =============================================================================

set -e

MOUNT_POINT="/mnt/rootfs"

case "$1" in
    postinst)
        echo "[update-post] Starting post-install hook"

        # --- Find the inactive (just updated) partition ---
        CMDLINE=$(cat /proc/cmdline)
        CURRENT_ROOT=$(echo "$CMDLINE" | tr ' ' '\n' | grep '^root=' | head -1 | cut -d= -f2)

        if [ -z "$CURRENT_ROOT" ]; then
            echo "[update-post] ERROR: Could not determine active root partition"
            exit 1
        fi

        BASE_DEV=$(echo "$CURRENT_ROOT" | sed 's/p[0-9]*$//')
        CURRENT_PART=$(echo "$CURRENT_ROOT" | grep -o 'p[0-9]*$' | tr -d 'p')

        PART_A="@@ROOTFS_A_PART@@"
        PART_B="@@ROOTFS_B_PART@@"

        if [ "$CURRENT_PART" = "$PART_A" ]; then
            TARGET_PART="$PART_B"
        elif [ "$CURRENT_PART" = "$PART_B" ]; then
            TARGET_PART="$PART_A"
        else
            echo "[update-post] ERROR: Unrecognized current partition: $CURRENT_PART"
            exit 1
        fi

        TARGET_DEV="${BASE_DEV}p${TARGET_PART}"
        echo "[update-post] Newly updated partition: $TARGET_DEV"

        # --- Mount the new rootfs ---
        mkdir -p "$MOUNT_POINT"
        mount "$TARGET_DEV" "$MOUNT_POINT"
        echo "[update-post] Mounted $TARGET_DEV at $MOUNT_POINT"

        # --- Copy preserved files ---
        # Network configuration (NetworkManager)
        NM_SRC="/etc/NetworkManager/system-connections"
        NM_DST="${MOUNT_POINT}/etc/NetworkManager/system-connections"
        if [ -d "$NM_SRC" ] && [ -n "$(ls -A $NM_SRC 2>/dev/null)" ]; then
            echo "[update-post] Copying NetworkManager connections..."
            mkdir -p "$NM_DST"
            cp -r "${NM_SRC}/." "$NM_DST/"
            echo "[update-post] Network config copied"
        else
            echo "[update-post] No NetworkManager connections to copy"
        fi

        # --- Unmount before filesystem operations ---
        umount "$MOUNT_POINT"
        echo "[update-post] Unmounted $MOUNT_POINT"

        # --- Filesystem integrity check ---
        echo "[update-post] Running filesystem check on $TARGET_DEV..."
        e2fsck -a -f "$TARGET_DEV" || true
        # Note: e2fsck returns non-zero even when it fixes errors, hence '|| true'
        echo "[update-post] Filesystem check complete"

        # --- Expand filesystem to fill the partition ---
        echo "[update-post] Resizing filesystem..."
        resize2fs -f "$TARGET_DEV"
        echo "[update-post] Filesystem resized"

        # --- Final sync ---
        sync
        echo "[update-post] Post-install hook complete — ready to reboot"
        ;;
    *)
        echo "[update-post] Unknown argument: $1"
        exit 1
        ;;
esac

exit 0
