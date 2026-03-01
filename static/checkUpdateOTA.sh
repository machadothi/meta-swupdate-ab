#!/bin/sh
# =============================================================================
# checkUpdateOTA.sh — Boot-Time Rollback Guard
# =============================================================================
#
# WHAT IT DOES
#   This script runs ONCE at every system boot (via systemd, see the companion
#   .service file). It is the critical component of the A/B rollback mechanism.
#
# HOW ROLLBACK WORKS
#   1. An OTA update is installed to the inactive partition.
#   2. U-Boot environment variables are updated:
#        upgrade_available=1   (signals a pending update)
#        bootcount=0           (reset the boot counter)
#        bootlimit=<N>         (maximum allowed boot attempts)
#   3. The system reboots into the new partition.
#   4. THIS SCRIPT runs at startup:
#        - If upgrade_available is set: the update is brand-new.
#          Script clears the flag → "commits" the update.
#        - If upgrade_available is NOT set: normal boot, nothing to do.
#   5. If the new partition fails to boot (kernel panic, service failure, etc.),
#      U-Boot counts failed attempts. When bootcount > bootlimit, U-Boot
#      automatically switches back to the previous working partition.
#
# WHY IT MATTERS
#   Without this script, every boot would look like an "untested update" to
#   U-Boot, and the system would eventually roll back even on healthy boots.
#
# DEPENDENCIES
#   - fw_printenv / fw_setenv  (from u-boot-tools, reads/writes U-Boot env)
#   - /etc/fw_env.config       (tells fw_printenv where the U-Boot env lives)
#     You must provide fw_env.config for your specific board. See:
#     https://u-boot.readthedocs.io/en/latest/usage/environment.html
# =============================================================================

UPGRADE_AVAILABLE=$(fw_printenv -n upgrade_available 2>/dev/null || echo "")

if [ -n "$UPGRADE_AVAILABLE" ] && [ "$UPGRADE_AVAILABLE" != "0" ]; then
    echo "[checkUpdateOTA] New update detected — committing..."
    fw_setenv upgrade_available 0
    fw_setenv bootcount 0
    echo "[checkUpdateOTA] Update committed. Rollback window closed."
else
    echo "[checkUpdateOTA] No pending update. Normal boot."
fi

exit 0
