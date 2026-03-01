#!/bin/sh
# =============================================================================
# ota-update.sh — On-Device OTA Update Helper
# =============================================================================
#
# WHAT IT DOES
#   Provides a simple command-line interface to install an OTA update package
#   (.swu file) that has been copied to the device (e.g., via USB or SCP).
#
# USAGE
#   ota-update <path-to-update.swu>
#
# EXAMPLES
#   ota-update /media/usb/update.swu
#   ota-update /home/root/my-update-1.2.0.swu
#
# AFTER SUCCESS
#   The device will automatically reboot into the new software version.
#   If the new version fails to boot (e.g., kernel panic), U-Boot will
#   automatically revert to the previous working partition.
#
# INSTALLED AT
#   /usr/bin/ota-update  (on the target device)
# =============================================================================

set -e

# --- Argument validation ---
if [ "$#" -ne 1 ]; then
    echo "Usage: ota-update <path-to-update.swu>"
    echo ""
    echo "Example: ota-update /media/usb/update.swu"
    exit 1
fi

SWU_FILE="$1"

# Check file exists
if [ ! -f "$SWU_FILE" ]; then
    echo "ERROR: File not found: $SWU_FILE"
    exit 1
fi

# Check file extension
case "$SWU_FILE" in
    *.swu) ;;
    *)
        echo "ERROR: File does not have .swu extension: $SWU_FILE"
        echo "OTA update packages must be .swu files."
        exit 1
        ;;
esac

echo "=== OTA Update Starting ==="
echo "Update file : $SWU_FILE"
echo "File size   : $(du -sh "$SWU_FILE" | cut -f1)"
echo ""

# --- Determine which partition to update ---
CMDLINE=$(cat /proc/cmdline)
CURRENT_ROOT=$(echo "$CMDLINE" | tr ' ' '\n' | grep '^root=' | head -1 | cut -d= -f2)
CURRENT_PART=$(echo "$CURRENT_ROOT" | grep -o 'p[0-9]*$' | tr -d 'p')

PART_A="@@ROOTFS_A_PART@@"
PART_B="@@ROOTFS_B_PART@@"

if [ "$CURRENT_PART" = "$PART_A" ]; then
    SELECTION="-e stable,rootfs2"
    echo "Currently booted from: partition $PART_A (rootfs slot A)"
    echo "Update will be written to: partition $PART_B (rootfs slot B)"
elif [ "$CURRENT_PART" = "$PART_B" ]; then
    SELECTION="-e stable,rootfs1"
    echo "Currently booted from: partition $PART_B (rootfs slot B)"
    echo "Update will be written to: partition $PART_A (rootfs slot A)"
else
    echo "ERROR: Cannot determine current boot partition (got: $CURRENT_PART)"
    echo "Expected partition $PART_A or $PART_B"
    exit 1
fi

echo ""
echo "Starting swupdate... (this may take several minutes)"
echo "Do NOT power off the device during update."
echo ""

# --- Run swupdate ---
swupdate $SELECTION -i "$SWU_FILE"
RESULT=$?

if [ $RESULT -eq 0 ]; then
    echo ""
    echo "=== Update Installed Successfully ==="
    echo "The device will now reboot into the new software version."
    echo "If the new version fails to start, the system will automatically"
    echo "revert to the previous working version."
else
    echo ""
    echo "=== Update FAILED (exit code: $RESULT) ==="
    echo "The device has NOT been modified. Check the logs for details:"
    echo "  journalctl -u swupdate --no-pager"
    exit $RESULT
fi
