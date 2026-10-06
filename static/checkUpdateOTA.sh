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
#        - If upgrade_available is set: the update is brand-new. The script
#          runs the health checks and, if they all pass, clears the flag
#          → "commits" the update.
#        - If upgrade_available is NOT set: normal boot, nothing to do.
#   5. If the new partition fails to boot (kernel panic, service failure, etc.),
#      U-Boot counts failed attempts. When bootcount > bootlimit, U-Boot
#      automatically switches back to the previous working partition.
#
# HEALTH CHECKS
#   Every executable file in /etc/ota-health.d/ is run (in name order) before
#   committing. If any of them exits non-zero, the update is NOT committed and
#   U-Boot rolls back after bootlimit further boots. Example check:
#
#       #!/bin/sh
#       systemctl is-active --quiet my-critical-service
#
#   If the rollback should happen right away instead of on the next reboots,
#   add a reboot to the failure branch below.
#
# WHY IT MATTERS
#   Without this script, every boot would look like an "untested update" to
#   U-Boot, and the system would eventually roll back even on healthy boots.
#
# DEPENDENCIES
#   - fw_printenv / fw_setenv  (from libubootenv-bin, reads/writes U-Boot env)
#   - /etc/fw_env.config       (tells fw_printenv where the U-Boot env lives)
#     You must provide fw_env.config for your specific board. See:
#     https://u-boot.readthedocs.io/en/latest/usage/environment.html
# =============================================================================

TAG="[checkUpdateOTA]"
HEALTH_DIR="/etc/ota-health.d"

# Fail loudly if the environment can't be read at all. Treating that as
# "no pending update" would hide a broken fw_env.config, and every update
# would then silently roll back.
if ! fw_printenv > /dev/null; then
    echo "$TAG ERROR: cannot read the U-Boot environment (check fw_printenv and /etc/fw_env.config)" >&2
    exit 1
fi

# An undefined variable prints as empty
UPGRADE_AVAILABLE=$(fw_printenv -n upgrade_available 2>/dev/null)

if [ -z "$UPGRADE_AVAILABLE" ] || [ "$UPGRADE_AVAILABLE" = "0" ]; then
    echo "$TAG No pending update. Normal boot."
    exit 0
fi

echo "$TAG New update detected — running health checks..."
if [ -d "$HEALTH_DIR" ]; then
    for check in "$HEALTH_DIR"/*; do
        [ -f "$check" ] && [ -x "$check" ] || continue
        if ! "$check"; then
            echo "$TAG Health check failed: $check — NOT committing the update" >&2
            echo "$TAG U-Boot will roll back after bootlimit failed boots" >&2
            exit 1
        fi
        echo "$TAG Health check passed: $check"
    done
fi

# Clear both variables in a single environment write
SCRIPT=$(mktemp) || { echo "$TAG ERROR: mktemp failed" >&2; exit 1; }
printf 'upgrade_available=0\nbootcount=0\n' > "$SCRIPT"
fw_setenv -s "$SCRIPT"
RC=$?
rm -f "$SCRIPT"

# fw_setenv's exit code alone isn't enough: read the flag back
if [ "$RC" -ne 0 ] || [ "$(fw_printenv -n upgrade_available 2>/dev/null)" != "0" ]; then
    echo "$TAG ERROR: failed to commit the update (fw_setenv exit code $RC)" >&2
    exit 1
fi

echo "$TAG Update committed. Rollback window closed."
exit 0
