#!/bin/sh
# =============================================================================
# ota-update.sh — On-Device OTA Update Helper
# =============================================================================
#
# WHAT IT DOES
#   Provides a simple command-line interface to install an OTA update package
#   (.swu file) that has been copied to the device (e.g., via USB or SCP).
#
#   The package is handed to the running SWUpdate daemon with swupdate-client,
#   so it goes through the same configuration as every other update path:
#   the slot selection from 09-swupdate-args, the hardware check, signature
#   verification (if enabled) and the reboot from postupdatecmd in
#   /etc/swupdate.cfg.
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

# Shared slot detection (ab_active_part, ab_target_part)
. /usr/share/swupdate-ab/ab-slot.sh

# --- Argument validation ---
if [ "$#" -ne 1 ]; then
    echo "Usage: ota-update <path-to-update.swu>"
    echo ""
    echo "Example: ota-update /media/usb/update.swu"
    exit 1
fi

SWU_FILE="$1"

if [ "$(id -u)" -ne 0 ]; then
    echo "ERROR: ota-update must be run as root"
    exit 1
fi

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

# The daemon does the actual install; without it swupdate-client has nobody
# to talk to (09-swupdate-args refuses to start it if the slot is unknown)
if command -v systemctl > /dev/null 2>&1 && ! systemctl is-active --quiet swupdate; then
    echo "ERROR: the swupdate service is not running. Check:"
    echo "  journalctl -u swupdate --no-pager"
    exit 1
fi

echo "=== OTA Update Starting ==="
echo "Update file : $SWU_FILE"
echo "File size   : $(du -sh "$SWU_FILE" | cut -f1)"
echo ""

# --- Show which partition will be updated ---
if ! ACTIVE_PART=$(ab_active_part) || ! TARGET_PART=$(ab_target_part); then
    echo "ERROR: Cannot determine the current boot partition"
    echo "Expected / to be on $(ab_part_dev "$AB_PART_A") or $(ab_part_dev "$AB_PART_B")"
    exit 1
fi
echo "Currently booted from    : $(ab_part_dev "$ACTIVE_PART")"
echo "Update will be written to: $(ab_part_dev "$TARGET_PART")"

echo ""
echo "Starting update... (this may take several minutes)"
echo "Do NOT power off the device during update."
echo ""

# --- Hand the package to the daemon ---
# -p: run postupdatecmd (reboot) if the update succeeds
# -v: print progress and status messages
RESULT=0
swupdate-client -p -v "$SWU_FILE" || RESULT=$?

if [ "$RESULT" -eq 0 ]; then
    echo ""
    echo "=== Update Installed Successfully ==="
    echo "The device will now reboot into the new software version."
    echo "If the new version fails to start, the system will automatically"
    echo "revert to the previous working version."
else
    echo ""
    echo "=== Update FAILED (exit code: $RESULT) ==="
    echo "The running system has NOT been modified and will keep booting from"
    echo "$(ab_part_dev "$ACTIVE_PART"). The inactive partition may be partially"
    echo "written; the next update overwrites it. Check the logs for details:"
    echo "  journalctl -u swupdate --no-pager"
    exit "$RESULT"
fi
