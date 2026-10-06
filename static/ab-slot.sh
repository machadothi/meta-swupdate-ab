#!/bin/sh
# =============================================================================
# ab-slot.sh — Shared A/B slot detection
# =============================================================================
#
# WHAT IT DOES
#   Works out which rootfs slot the system is running from and which one an
#   update must be written to. Sourced (not executed) by:
#     - 09-swupdate-args  (SWUpdate daemon startup)
#     - ota-update        (CLI helper)
#     - update-post.sh    (post-install script inside the .swu)
#
# HOW
#   Compares the major:minor of the device mounted at / (from
#   /proc/self/mountinfo) with those of the two rootfs partitions (from
#   /sys/class/block). Unlike parsing root= from /proc/cmdline, this also works
#   with root=PARTUUID=..., root=/dev/root and any partition naming scheme.
#
# INSTALLED AT
#   /usr/share/swupdate-ab/ab-slot.sh  (on the target device)
#
# All names are prefixed AB_/ab_ because this file is sourced into other
# scripts, including SWUpdate's own startup script.
# =============================================================================

# Substituted by init-layer.sh from layer.config
AB_DEVICE="@@EMMC_DEVICE@@"
AB_PART_A="@@ROOTFS_A_PART@@"
AB_PART_B="@@ROOTFS_B_PART@@"

# Device node of partition number $1.
# Disks whose name ends in a digit use a "p" separator (mmcblk2 -> mmcblk2p3,
# nvme0n1 -> nvme0n1p3), the others don't (sda -> sda3).
ab_part_dev() {
    case "$AB_DEVICE" in
        *[0-9]) echo "${AB_DEVICE}p$1" ;;
        *)      echo "${AB_DEVICE}$1" ;;
    esac
}

# Prints the partition number of the running rootfs (AB_PART_A or AB_PART_B).
# Returns 1, printing nothing, if / is on neither of them.
ab_active_part() {
    # The last entry for / wins: earlier ones may be the initramfs rootfs
    ab_root_majmin=$(awk '$5 == "/" { m = $3 } END { print m }' /proc/self/mountinfo)
    [ -n "$ab_root_majmin" ] || return 1

    for ab_part in "$AB_PART_A" "$AB_PART_B"; do
        ab_name=$(basename "$(ab_part_dev "$ab_part")")
        if [ "$(cat "/sys/class/block/${ab_name}/dev" 2>/dev/null)" = "$ab_root_majmin" ]; then
            echo "$ab_part"
            return 0
        fi
    done
    return 1
}

# Prints the partition number the next update must be written to (the
# inactive slot). Returns 1 if the active slot is unknown: never guess, a
# wrong guess overwrites the running rootfs.
ab_target_part() {
    ab_active=$(ab_active_part) || return 1
    if [ "$ab_active" = "$AB_PART_A" ]; then
        echo "$AB_PART_B"
    else
        echo "$AB_PART_A"
    fi
}

# Prints the sw-description selection ("<set>,<mode>" for swupdate -e) that
# writes to the inactive slot: rootfs1 = slot A, rootfs2 = slot B.
ab_selection() {
    ab_target=$(ab_target_part) || return 1
    if [ "$ab_target" = "$AB_PART_A" ]; then
        echo "stable,rootfs1"
    else
        echo "stable,rootfs2"
    fi
}
