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
#   1. Mounts the newly updated (inactive) partition at /mnt/rootfs. The
#      partition comes from /usr/share/swupdate-ab/ab-slot.sh on the running
#      system, the same detection SWUpdate used to pick the write target.
#   2. Copies network configuration files from the active system into the
#      new rootfs — so the device keeps its network settings after update.
#   3. Runs filesystem integrity check (e2fsck) on the new partition.
#   4. Runs resize2fs to expand the filesystem to fill the partition.
#      (Needed because the image is typically smaller than the partition.)
#   5. Unmounts and syncs to ensure all writes are flushed to storage.
#
# ARGUMENTS
#   $1 = "preinst", "postinst" or "postfailure" (set by SWUpdate); only
#        "postinst" does any work
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

# Unmount on any error so a failed update doesn't leave the new rootfs mounted
cleanup() {
    if grep -qs " $MOUNT_POINT " /proc/mounts; then
        umount "$MOUNT_POINT" || true
    fi
}
trap cleanup EXIT

case "$1" in
    preinst|postfailure)
        # SWUpdate calls "shellscript" scripts before installing (preinst) and
        # on failure (postfailure) too. Nothing to do at those stages.
        ;;
    postinst)
        echo "[update-post] Starting post-install hook"

        # --- Find the inactive (just updated) partition ---
        # Shared slot detection from the running system's swupdate package
        . /usr/share/swupdate-ab/ab-slot.sh

        if ! TARGET_PART=$(ab_target_part); then
            echo "[update-post] ERROR: Could not determine the active root partition"
            exit 1
        fi

        TARGET_DEV=$(ab_part_dev "$TARGET_PART")
        echo "[update-post] Newly updated partition: $TARGET_DEV"

        # --- Mount the new rootfs ---
        mkdir -p "$MOUNT_POINT"
        mount "$TARGET_DEV" "$MOUNT_POINT"
        echo "[update-post] Mounted $TARGET_DEV at $MOUNT_POINT"

        # --- Copy preserved files ---
        # Network configuration (NetworkManager)
        NM_SRC="/etc/NetworkManager/system-connections"
        NM_DST="${MOUNT_POINT}/etc/NetworkManager/system-connections"
        if [ -d "$NM_SRC" ] && [ -n "$(ls -A "$NM_SRC" 2>/dev/null)" ]; then
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
        # e2fsck exit codes: 1/2 = errors corrected, >= 4 = errors left uncorrected
        # (or a usage/operational error). Only the latter must abort the update.
        FSCK_RC=0
        e2fsck -p -f "$TARGET_DEV" || FSCK_RC=$?
        if [ "$FSCK_RC" -ge 4 ]; then
            echo "[update-post] ERROR: e2fsck failed on $TARGET_DEV (exit code $FSCK_RC)"
            exit 1
        fi
        echo "[update-post] Filesystem check complete (e2fsck exit code $FSCK_RC)"

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
