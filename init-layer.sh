#!/usr/bin/env bash
# =============================================================================
# init-layer.sh -- meta-swupdate-ab Layer Initializer
# =============================================================================
#
# USAGE
#   ./init-layer.sh [config_file] [--force]
#
# ARGUMENTS
#   config_file   Path to your layer config (default: layer.config)
#   --force       Overwrite already-generated files without prompting
#
# DESCRIPTION
#   Reads your layer.config and generates all Yocto recipe files needed for
#   A/B dual-rootfs OTA updates using SWUpdate. Run this once after cloning
#   the repository and editing your config.
#
# AFTER RUNNING
#   The directory containing this script becomes a valid Yocto layer.
#   Add it to your build's bblayers.conf and include the recipes in your image.
#
# REQUIREMENTS
#   bash >= 3.2, coreutils (mktemp, mkdir, cp, mv, find, sort), sed, openssl
# =============================================================================

set -euo pipefail

# ---------------------------------------------------------------------------
# Colour helpers — auto-disabled when output is not a terminal
# ---------------------------------------------------------------------------
if [ -t 1 ]; then
    RED='\033[0;31m'
    YELLOW='\033[1;33m'
    GREEN='\033[0;32m'
    CYAN='\033[0;36m'
    BOLD='\033[1m'
    RESET='\033[0m'
else
    RED=''
    YELLOW=''
    GREEN=''
    CYAN=''
    BOLD=''
    RESET=''
fi

info()    { printf "${CYAN}[INFO]${RESET}  %s\n" "$*"; }
success() { printf "${GREEN}[OK]${RESET}    %s\n" "$*"; }
warn()    { printf "${YELLOW}[WARN]${RESET}  %s\n" "$*"; }
error()   { printf "${RED}[ERROR]${RESET} %s\n" "$*" >&2; }
die()     { error "$*"; exit 1; }
step()    { printf "\n${BOLD}==> %s${RESET}\n" "$*"; }

# ---------------------------------------------------------------------------
# Portable in-place text substitution — no platform-specific sed -i flags
# ---------------------------------------------------------------------------
replace_in_file() {
    local file="$1"
    local from="$2"
    local to="$3"
    local tmp
    tmp=$(mktemp) || die "mktemp failed — cannot create temporary file"
    # Use | as delimiter to avoid conflicts with / in paths
    sed "s|${from}|${to}|g" "$file" > "$tmp" && mv "$tmp" "$file"
}

# ---------------------------------------------------------------------------
# Script location
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATIC_DIR="${SCRIPT_DIR}/static"
KEYS_DIR="${SCRIPT_DIR}/keys"

# ---------------------------------------------------------------------------
# Dependency check
# ---------------------------------------------------------------------------
check_dependencies() {
    local missing=()
    for cmd in bash sed mktemp mkdir cp mv find sort; do
        command -v "$cmd" > /dev/null 2>&1 || missing+=("$cmd")
    done
    if [ ${#missing[@]} -gt 0 ]; then
        die "Missing required tools: ${missing[*]}
Install them with:  sudo apt-get install coreutils sed"
    fi
    # openssl is optional (only needed for key generation)
    if ! command -v openssl > /dev/null 2>&1; then
        warn "openssl not found — RSA key generation will be unavailable"
        warn "Install with:  sudo apt-get install openssl"
    fi
}

check_dependencies

# ---------------------------------------------------------------------------
# Parse arguments
# ---------------------------------------------------------------------------
CONFIG_FILE="layer.config"
FORCE=false
SKIPPED_FILES=0

for arg in "$@"; do
    case "$arg" in
        --force)
            FORCE=true
            ;;
        --help|-h)
            # Print the header comment block, stripping leading '# '
            sed -n '/^# USAGE/,/^# =====/p' "$0" \
                | sed '$d' \
                | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        -*)
            die "Unknown argument: $arg  (use --help for usage)"
            ;;
        *)
            CONFIG_FILE="$arg"
            ;;
    esac
done

# Resolve config path (absolute or relative to the script directory)
case "$CONFIG_FILE" in
    /*) : ;;   # already absolute
    *)  CONFIG_FILE="${SCRIPT_DIR}/${CONFIG_FILE}" ;;
esac

# ---------------------------------------------------------------------------
# Load and validate configuration
# ---------------------------------------------------------------------------
step "Loading configuration from: $CONFIG_FILE"

[ -f "$CONFIG_FILE" ] || die "Config file not found: $CONFIG_FILE
Run:  cp layer.config.example layer.config  then edit it."

# shellcheck disable=SC1090
source "$CONFIG_FILE"

# Required scalar variables
REQUIRED_VARS=(
    PROJECT_NAME LAYER_PRIORITY YOCTO_RELEASES
    EMMC_DEVICE ROOTFS_A_PART ROOTFS_B_PART
    BASE_IMAGE IMAGE_FSTYPE SW_VERSION
    HW_VERSION HW_COMPAT_VERSIONS
    IDENTIFY_NAME ENABLE_SIGNING GENERATE_KEYS
)
for var in "${REQUIRED_VARS[@]}"; do
    [ -n "${!var:-}" ] || die "Missing required variable in config: $var
Please set it in $CONFIG_FILE"
done

# Required arrays (declare -p first: under 'set -u' an unset array aborts with an
# unhelpful "unbound variable" message instead of our own error)
for arr in MACHINES HW_IDS IDENTIFY_VALUES; do
    declare -p "$arr" > /dev/null 2>&1 || die "$arr array is missing from config"
done
[ "${#MACHINES[@]}" -gt 0 ]        || die "MACHINES array is empty"
[ "${#HW_IDS[@]}" -gt 0 ]          || die "HW_IDS array is empty"
[ "${#IDENTIFY_VALUES[@]}" -gt 0 ] || die "IDENTIFY_VALUES array is empty"

NUM_MACHINES="${#MACHINES[@]}"
[ "${#HW_IDS[@]}" -eq "$NUM_MACHINES" ] \
    || die "HW_IDS has ${#HW_IDS[@]} entries but MACHINES has $NUM_MACHINES -- must match"
[ "${#IDENTIFY_VALUES[@]}" -eq "$NUM_MACHINES" ] \
    || die "IDENTIFY_VALUES has ${#IDENTIFY_VALUES[@]} entries but MACHINES has $NUM_MACHINES -- must match"

# Validate EMMC_DEVICE looks like a block device path
case "$EMMC_DEVICE" in
    /dev/*) : ;;
    *) die "EMMC_DEVICE must start with /dev/ (got: $EMMC_DEVICE)" ;;
esac

# Validate partition numbers are positive integers and different
case "$ROOTFS_A_PART" in
    ''|*[!0-9]*) die "ROOTFS_A_PART must be a positive integer (got: $ROOTFS_A_PART)" ;;
esac
case "$ROOTFS_B_PART" in
    ''|*[!0-9]*) die "ROOTFS_B_PART must be a positive integer (got: $ROOTFS_B_PART)" ;;
esac
[ "$ROOTFS_A_PART" -ne "$ROOTFS_B_PART" ] \
    || die "ROOTFS_A_PART and ROOTFS_B_PART must be different partition numbers"

# Validate yes/no fields
case "$ENABLE_SIGNING" in
    yes|no) : ;;
    *) die "ENABLE_SIGNING must be 'yes' or 'no' (got: $ENABLE_SIGNING)" ;;
esac
case "$GENERATE_KEYS" in
    yes|no) : ;;
    *) die "GENERATE_KEYS must be 'yes' or 'no' (got: $GENERATE_KEYS)" ;;
esac
# Optional: older configs predate this setting, so default to the safe value
ENABLE_WEBSERVER="${ENABLE_WEBSERVER:-no}"
case "$ENABLE_WEBSERVER" in
    yes|no) : ;;
    *) die "ENABLE_WEBSERVER must be 'yes' or 'no' (got: $ENABLE_WEBSERVER)" ;;
esac
if [ "$ENABLE_WEBSERVER" = "yes" ] && [ "$ENABLE_SIGNING" = "no" ]; then
    warn "ENABLE_WEBSERVER=yes without signing: anyone on the network can install an update"
fi

success "Configuration validated"
printf "  Project name : %s\n"  "$PROJECT_NAME"
printf "  Machines     : %s\n"  "${MACHINES[*]}"
printf "  Base image   : %s\n"  "$BASE_IMAGE"
printf "  eMMC device  : %s (part A=%s, B=%s)\n" \
    "$EMMC_DEVICE" "$ROOTFS_A_PART" "$ROOTFS_B_PART"
printf "  Signing      : %s\n"  "$ENABLE_SIGNING"
printf "  Web server   : %s\n"  "$ENABLE_WEBSERVER"

# ---------------------------------------------------------------------------
# Derived paths
# ---------------------------------------------------------------------------
RECIPES_SUPPORT="${SCRIPT_DIR}/recipes-support/swupdate"
RECIPES_IMAGES="${SCRIPT_DIR}/recipes-images/images"
RECIPES_CORE="${SCRIPT_DIR}/recipes-core/check-update-ota"
CONF_DIR="${SCRIPT_DIR}/conf"

SWUPDATE_FILES="${RECIPES_SUPPORT}/swupdate"
UPDATE_IMAGE_FILES="${RECIPES_IMAGES}/update-image"

# ---------------------------------------------------------------------------
# Helper: safe file write (respects --force)
# ---------------------------------------------------------------------------
write_file() {
    local path="$1"
    local content="$2"
    if [ -f "$path" ] && [ "$FORCE" = false ]; then
        warn "File exists (use --force to overwrite): ${path#"${SCRIPT_DIR}/"}"
        SKIPPED_FILES=$((SKIPPED_FILES + 1))
        return
    fi
    mkdir -p "$(dirname "$path")"
    printf '%s' "$content" > "$path"
    success "Generated: ${path#"${SCRIPT_DIR}/"}"
}

# ---------------------------------------------------------------------------
# Helper: safe file copy (respects --force)
# ---------------------------------------------------------------------------
copy_file() {
    local src="$1"
    local dst="$2"
    [ -f "$src" ] || die "Static source file missing: $src"
    if [ -f "$dst" ] && [ "$FORCE" = false ]; then
        warn "File exists (use --force to overwrite): ${dst#"${SCRIPT_DIR}/"}"
        SKIPPED_FILES=$((SKIPPED_FILES + 1))
        return
    fi
    mkdir -p "$(dirname "$dst")"
    cp "$src" "$dst"
    success "Copied: ${dst#"${SCRIPT_DIR}/"}"
}

# ---------------------------------------------------------------------------
# STEP 1 -- RSA keys
# ---------------------------------------------------------------------------
step "Handling RSA keys (ENABLE_SIGNING=$ENABLE_SIGNING)"

PRIV_KEY="${KEYS_DIR}/swupdate_priv.pem"
PUB_KEY="${KEYS_DIR}/swupdate_public.pem"

if [ "$ENABLE_SIGNING" = "yes" ]; then
    if [ "$GENERATE_KEYS" = "yes" ]; then
        # Never overwrite an existing private key, not even with --force:
        # devices in the field only accept updates signed with the key whose
        # public half they carry, so replacing it locks them out of future updates.
        if [ -f "$PRIV_KEY" ]; then
            info "Private key already exists in keys/ -- keeping it"
            info "To rotate keys, move the old pair away manually first"
        else
            command -v openssl > /dev/null 2>&1 \
                || die "openssl not found.
Install it:  sudo apt-get install openssl
Or set GENERATE_KEYS=no and place your own keys in keys/"
            info "Generating RSA 4096-bit key pair..."
            # umask in a subshell so the private key is never world-readable,
            # not even between creation and a later chmod
            ( umask 077; openssl genrsa -out "$PRIV_KEY" 4096 2>/dev/null )
            success "Private key generated in keys/"
            warn "IMPORTANT: Never commit keys/swupdate_priv.pem to a public repository!"
        fi
        if [ ! -f "$PUB_KEY" ]; then
            openssl rsa -in "$PRIV_KEY" -out "$PUB_KEY" -pubout 2>/dev/null \
                || die "Could not derive keys/swupdate_public.pem from the private key"
            success "Public key derived from keys/swupdate_priv.pem"
        fi
    else
        [ -f "$PRIV_KEY" ] \
            || die "ENABLE_SIGNING=yes but keys/swupdate_priv.pem not found.
Either set GENERATE_KEYS=yes or place your private key at: $PRIV_KEY"
        [ -f "$PUB_KEY" ] \
            || die "ENABLE_SIGNING=yes but keys/swupdate_public.pem not found.
Either set GENERATE_KEYS=yes or place your public key at: $PUB_KEY"
        success "Found existing key pair in keys/"
    fi
else
    info "Signing disabled -- skipping key setup"
    info "To enable signing later, set ENABLE_SIGNING=yes and re-run this script"
fi

# ---------------------------------------------------------------------------
# STEP 2 -- Create directory skeleton
# ---------------------------------------------------------------------------
step "Creating directory structure"

mkdir -p \
    "${CONF_DIR}" \
    "${RECIPES_SUPPORT}" \
    "${SWUPDATE_FILES}" \
    "${RECIPES_IMAGES}" \
    "${UPDATE_IMAGE_FILES}" \
    "${RECIPES_CORE}/files"

for machine in "${MACHINES[@]}"; do
    mkdir -p "${SWUPDATE_FILES}/${machine}"
    mkdir -p "${UPDATE_IMAGE_FILES}/${machine}"
done

success "Directories created"

# ---------------------------------------------------------------------------
# STEP 3 -- Copy static files and substitute partition placeholders
# ---------------------------------------------------------------------------
step "Copying static files"

copy_file "${STATIC_DIR}/defconfig"                "${SWUPDATE_FILES}/defconfig"
copy_file "${STATIC_DIR}/ota-update.sh"            "${SWUPDATE_FILES}/ota-update.sh"
copy_file "${STATIC_DIR}/update-post.sh"           "${UPDATE_IMAGE_FILES}/update-post.sh"
copy_file "${STATIC_DIR}/checkUpdateOTA.sh"        "${RECIPES_CORE}/files/checkUpdateOTA.sh"
copy_file "${STATIC_DIR}/check-update-ota.service" "${RECIPES_CORE}/files/check-update-ota.service"
copy_file "${STATIC_DIR}/check-update-ota.bb"      "${RECIPES_CORE}/check-update-ota.bb"

# Substitute @@ROOTFS_X_PART@@ placeholders in the copied scripts.
# Using replace_in_file (sed + mktemp) -- works on any POSIX-compliant system.
for f in \
    "${SWUPDATE_FILES}/ota-update.sh" \
    "${UPDATE_IMAGE_FILES}/update-post.sh"; do
    replace_in_file "$f" "@@ROOTFS_A_PART@@" "${ROOTFS_A_PART}"
    replace_in_file "$f" "@@ROOTFS_B_PART@@" "${ROOTFS_B_PART}"
done
success "Partition numbers substituted in scripts"

# Feature switches in the SWUpdate defconfig always follow layer.config, even
# when the file itself was kept (no --force), so toggling them never goes stale.
# CONFIG_SIGNED_IMAGES must be compiled in: without it SWUpdate accepts unsigned
# .swu files no matter what swupdate.cfg says.
yn_to_kconfig() { [ "$1" = "yes" ] && echo y || echo n; }
SIGNED_KCONFIG="$(yn_to_kconfig "$ENABLE_SIGNING")"
WEB_KCONFIG="$(yn_to_kconfig "$ENABLE_WEBSERVER")"
replace_in_file "${SWUPDATE_FILES}/defconfig" \
    "^CONFIG_SIGNED_IMAGES=[yn]$" "CONFIG_SIGNED_IMAGES=${SIGNED_KCONFIG}"
replace_in_file "${SWUPDATE_FILES}/defconfig" \
    "^CONFIG_MONGOOSE=[yn]$" "CONFIG_MONGOOSE=${WEB_KCONFIG}"
replace_in_file "${SWUPDATE_FILES}/defconfig" \
    "^CONFIG_WEBSERVER=[yn]$" "CONFIG_WEBSERVER=${WEB_KCONFIG}"
success "defconfig: CONFIG_SIGNED_IMAGES=${SIGNED_KCONFIG}, CONFIG_WEBSERVER=${WEB_KCONFIG}"

# The public key always mirrors keys/ (no --force needed): a stale copy would
# make every correctly signed update fail verification on the device.
if [ "$ENABLE_SIGNING" = "yes" ]; then
    cp "${PUB_KEY}" "${SWUPDATE_FILES}/swupdate_public.pem"
    success "Copied: ${SWUPDATE_FILES#"${SCRIPT_DIR}/"}/swupdate_public.pem"
fi

# ---------------------------------------------------------------------------
# STEP 4 -- Generate conf/layer.conf
# ---------------------------------------------------------------------------
step "Generating conf/layer.conf"

write_file "${CONF_DIR}/layer.conf" \
"# Yocto layer configuration for meta-swupdate-ab
# Generated by init-layer.sh -- do not edit manually; re-run init-layer.sh instead.

BBPATH .= \":\${LAYERDIR}\"

BBFILES += \"\${LAYERDIR}/recipes-*/*/*.bb \${LAYERDIR}/recipes-*/*/*.bbappend\"

BBFILE_COLLECTIONS += \"${PROJECT_NAME}-swupdate\"
BBFILE_PATTERN_${PROJECT_NAME}-swupdate = \"^\${LAYERDIR}/\"
BBFILE_PRIORITY_${PROJECT_NAME}-swupdate = \"${LAYER_PRIORITY}\"

LAYERDEPENDS_${PROJECT_NAME}-swupdate = \"core swupdate\"

LAYERSERIES_COMPAT_${PROJECT_NAME}-swupdate = \"${YOCTO_RELEASES}\"
"

# ---------------------------------------------------------------------------
# STEP 5 -- Generate swupdate_%.bbappend
# ---------------------------------------------------------------------------
step "Generating swupdate_%.bbappend"

HWREV_BLOCKS=""
for i in "${!MACHINES[@]}"; do
    m="${MACHINES[$i]}"
    hwid="${HW_IDS[$i]}"
    HWREV_BLOCKS="${HWREV_BLOCKS}
do_install:append:${m}() {
    echo \"${hwid} ${HW_VERSION}\" > \${D}\${sysconfdir}/hwrevision
}
"
done

# The public key is only shipped when signing is enabled
if [ "$ENABLE_SIGNING" = "yes" ]; then
    KEY_SRC_URI="
    file://swupdate_public.pem \\"
    KEY_INSTALL="
    # RSA public key for signature verification
    install -m 0644 \${UNPACKDIR}/swupdate_public.pem \${D}\${sysconfdir}/swupdate_public.pem
"
    KEY_FILES="
    \${sysconfdir}/swupdate_public.pem \\"
else
    KEY_SRC_URI=""
    KEY_INSTALL=""
    KEY_FILES=""
fi

write_file "${RECIPES_SUPPORT}/swupdate_%.bbappend" \
"# SWUpdate recipe extension for ${PROJECT_NAME}
# Generated by init-layer.sh -- do not edit manually; re-run init-layer.sh instead.

FILESEXTRAPATHS:prepend := \"\${THISDIR}/\${PN}:\"

# Releases before styhead unpack into WORKDIR and have no UNPACKDIR
UNPACKDIR ??= \"\${WORKDIR}\"

# 09-swupdate-args and swupdate.cfg are per machine: bitbake picks them from
# swupdate/<MACHINE>/ automatically (FILESOVERRIDES), so no per-machine SRC_URI.
SRC_URI += \" \\
    file://defconfig \\
    file://ota-update.sh \\
    file://09-swupdate-args \\
    file://swupdate.cfg \\${KEY_SRC_URI}
\"

do_install:append() {
    # Startup argument script, sourced by swupdate.sh (selects the inactive slot)
    install -d \${D}\${libdir}/swupdate/conf.d
    install -m 0644 \${UNPACKDIR}/09-swupdate-args \${D}\${libdir}/swupdate/conf.d/09-swupdate-args

    # Runtime configuration
    install -d \${D}\${sysconfdir}
    install -m 0644 \${UNPACKDIR}/swupdate.cfg \${D}\${sysconfdir}/swupdate.cfg
${KEY_INSTALL}
    # CLI update helper
    install -d \${D}\${bindir}
    install -m 0755 \${UNPACKDIR}/ota-update.sh \${D}\${bindir}/ota-update
}

# /etc/hwrevision: \"<HW_ID> <HW_VERSION>\" -- read by SWUpdate for compatibility check
${HWREV_BLOCKS}

FILES:\${PN} += \" \\
    \${libdir}/swupdate/conf.d/09-swupdate-args \\
    \${sysconfdir}/swupdate.cfg \\${KEY_FILES}
    \${sysconfdir}/hwrevision \\
    \${bindir}/ota-update \\
\"
"

# ---------------------------------------------------------------------------
# STEP 6 -- Per-machine files
# ---------------------------------------------------------------------------
step "Generating per-machine files"

# Build hw-compat list in libconfig array format: "1.0 2.0" -> ["1.0", "2.0"]
COMPAT_ARRAY="["
first=true
for v in $HW_COMPAT_VERSIONS; do
    if [ "$first" = true ]; then
        COMPAT_ARRAY="${COMPAT_ARRAY}\"${v}\""
        first=false
    else
        COMPAT_ARRAY="${COMPAT_ARRAY}, \"${v}\""
    fi
done
COMPAT_ARRAY="${COMPAT_ARRAY}]"

for i in "${!MACHINES[@]}"; do
    MACHINE="${MACHINES[$i]}"
    HW_ID="${HW_IDS[$i]}"
    IDENTIFY_VALUE="${IDENTIFY_VALUES[$i]}"

    info "Processing machine: $MACHINE (hw_id=$HW_ID)"

    MACHINE_SWUPDATE_DIR="${SWUPDATE_FILES}/${MACHINE}"
    MACHINE_IMAGE_DIR="${UPDATE_IMAGE_FILES}/${MACHINE}"

    # --- 09-swupdate-args ---
    write_file "${MACHINE_SWUPDATE_DIR}/09-swupdate-args" \
"#!/bin/sh
# =============================================================================
# 09-swupdate-args -- SWUpdate Startup Arguments for machine: ${MACHINE}
# =============================================================================
# Sourced (not executed) by swupdate.sh at daemon startup.
# Detects the currently active rootfs partition, selects the opposite slot as
# the update target, and builds the SWUPDATE_ARGS variable.
# If the active slot cannot be determined, SWUpdate is NOT started: guessing
# could select the running partition as the write target.
# =============================================================================

CMDLINE=\"\$(cat /proc/cmdline)\"
CURRENT_ROOT=\"\$(echo \"\$CMDLINE\" | tr ' ' '\n' | grep '^root=' | head -1 | cut -d= -f2)\"
CURRENT_PART=\"\$(echo \"\$CURRENT_ROOT\" | grep -o 'p[0-9]*\$' | tr -d 'p')\"

PART_A=\"${ROOTFS_A_PART}\"
PART_B=\"${ROOTFS_B_PART}\"

if [ \"\$CURRENT_PART\" = \"\$PART_A\" ]; then
    selection=\"-e stable,rootfs2\"
elif [ \"\$CURRENT_PART\" = \"\$PART_B\" ]; then
    selection=\"-e stable,rootfs1\"
else
    echo \"[09-swupdate-args] ERROR: active partition '\$CURRENT_PART' is neither \$PART_A nor \$PART_B\" >&2
    echo \"[09-swupdate-args] Refusing to start SWUpdate: it could overwrite the running rootfs\" >&2
    exit 1
fi

# -H <HW_ID>:<HW_VERSION> must match /etc/hwrevision on the device
SWUPDATE_ARGS=\"-H ${HW_ID}:${HW_VERSION} \${selection} -f /etc/swupdate.cfg\"
"

    # --- swupdate.cfg ---
    if [ "$ENABLE_SIGNING" = "yes" ]; then
        SIGNING_LINE='    public-key-file = "/etc/swupdate_public.pem";'
    else
        SIGNING_LINE='    # public-key-file = "/etc/swupdate_public.pem";  # Uncomment to enable RSA signing'
    fi

    write_file "${MACHINE_SWUPDATE_DIR}/swupdate.cfg" \
"# SWUpdate Runtime Configuration for machine: ${MACHINE}
# Generated by init-layer.sh -- edit freely after generation.
# Full option reference: https://sbabic.github.io/swupdate/swupdate-client-server.html

globals:
{
    verbose = true;
    loglevel = 3;   # 0=error 1=warn 2=info 3=debug 4=trace
    syslog = true;

${SIGNING_LINE}

    # Reboot automatically after a successful update
    postupdatecmd = \"reboot\";
};

download:
{
    retries = 3;
    timeout = 1800;   # seconds (30 minutes)
};

identify:
{
    # Reported to OTA management server (e.g. Hawkbit) for device tracking
    name = \"${IDENTIFY_NAME}\"; value = \"${IDENTIFY_VALUE}\";
};

webserver:
{
    # Push-mode web interface: http://<device-ip>:8080
    document_root = \"/www\";
    userid = 0;
    groupid = 0;
};
"

    # --- sw-description ---
    IMAGE_FILE="${BASE_IMAGE}-${MACHINE}.${IMAGE_FSTYPE}.gz"
    DEVICE_A="${EMMC_DEVICE}p${ROOTFS_A_PART}"
    DEVICE_B="${EMMC_DEVICE}p${ROOTFS_B_PART}"

    write_file "${MACHINE_IMAGE_DIR}/sw-description" \
"/* =============================================================================
 * sw-description -- SWUpdate Update Manifest for machine: ${MACHINE}
 * =============================================================================
 * Format: libconfig  https://hyperrealm.github.io/libconfig/
 * Reference: https://sbabic.github.io/swupdate/sw-description.html
 * ============================================================================= */

software:
{
    version = \"${SW_VERSION}\";
    description = \"OTA Update for ${MACHINE}\";

    /* SWUpdate refuses to install if /etc/hwrevision on the device does not
     * contain one of these version strings.  Add new strings as hardware evolves. */
    hardware-compatibility: ${COMPAT_ARRAY};

    /* -------------------------------------------------------------------------
     * stable -- normal production update group.
     * rootfs1 / rootfs2 map to slot A / slot B.
     * The correct group is selected at runtime by 09-swupdate-args.
     * ------------------------------------------------------------------------- */
    stable:
    {
        /* Slot A: write to partition ${ROOTFS_A_PART} when slot B is active */
        rootfs1:
        {
            images: (
                {
                    filename = \"${IMAGE_FILE}\";
                    type = \"raw\";
                    device = \"${DEVICE_A}\";
                    compressed = \"zlib\";       /* image is gzip-compressed */
                    installed-directly = true; /* stream to device (conserves RAM) */
                    /* filled in by the swupdate class at build time */
                    sha256 = \"\$swupdate_get_sha256(${IMAGE_FILE})\";
                }
            );

            scripts: (
                {
                    /* shellscript runs with preinst, postinst and on failure
                     * with postfailure; update-post.sh only acts on postinst */
                    filename = \"update-post.sh\";
                    type = \"shellscript\";
                    sha256 = \"\$swupdate_get_sha256(update-post.sh)\";
                }
            );

            /* Tell U-Boot to boot from slot A on next reboot */
            uboot: (
                { name = \"rootfspart\";       value = \"${ROOTFS_A_PART}\"; },
                { name = \"mmcroot\";          value = \"${DEVICE_A} rootwait rw\"; },
                { name = \"mmcautodetect\";    value = \"no\"; },
                /* upgrade_available=1 opens the rollback window.
                 * checkUpdateOTA.sh clears it once the new system boots OK. */
                { name = \"upgrade_available\"; value = \"1\"; },
                { name = \"bootcount\";        value = \"0\"; }
            );
        };

        /* Slot B: write to partition ${ROOTFS_B_PART} when slot A is active */
        rootfs2:
        {
            images: (
                {
                    filename = \"${IMAGE_FILE}\";
                    type = \"raw\";
                    device = \"${DEVICE_B}\";
                    compressed = \"zlib\";
                    installed-directly = true;
                    /* filled in by the swupdate class at build time */
                    sha256 = \"\$swupdate_get_sha256(${IMAGE_FILE})\";
                }
            );

            scripts: (
                {
                    /* shellscript runs with preinst, postinst and on failure
                     * with postfailure; update-post.sh only acts on postinst */
                    filename = \"update-post.sh\";
                    type = \"shellscript\";
                    sha256 = \"\$swupdate_get_sha256(update-post.sh)\";
                }
            );

            /* Tell U-Boot to boot from slot B on next reboot */
            uboot: (
                { name = \"rootfspart\";       value = \"${ROOTFS_B_PART}\"; },
                { name = \"mmcroot\";          value = \"${DEVICE_B} rootwait rw\"; },
                { name = \"mmcautodetect\";    value = \"no\"; },
                { name = \"upgrade_available\"; value = \"1\"; },
                { name = \"bootcount\";        value = \"0\"; }
            );
        };
    };
}
"

    success "Machine $MACHINE complete"
done

# ---------------------------------------------------------------------------
# STEP 7 -- Generate update-image.bb
# ---------------------------------------------------------------------------
step "Generating recipes-images/images/update-image.bb"

if [ "$ENABLE_SIGNING" = "yes" ]; then
    SIGNING_BLOCK="# RSA signing enabled -- .swu is signed with the private key at build time
SWUPDATE_SIGNING = \"RSA\"
SWUPDATE_PRIVATE_KEY = \"\${THISDIR}/\${PN}/../../../keys/swupdate_priv.pem\"
# Uncomment the next line if your private key is passphrase-protected:
# SWUPDATE_PASSWORD_FILE = \"\${THISDIR}/\${PN}/../../../keys/pass_phrase\""
else
    SIGNING_BLOCK="# RSA signing is disabled.
# To enable: set ENABLE_SIGNING=yes in layer.config and re-run init-layer.sh.
# Or uncomment manually:
# SWUPDATE_SIGNING = \"RSA\"
# SWUPDATE_PRIVATE_KEY = \"\${THISDIR}/\${PN}/../../../keys/swupdate_priv.pem\""
fi

write_file "${RECIPES_IMAGES}/update-image.bb" \
"# update-image.bb -- OTA Update Package Recipe
# Generated by init-layer.sh -- edit freely after generation.
#
# Build with:  bitbake update-image
# Output:      <build-dir>/tmp/deploy/images/<machine>/update-image-<machine>.swu

SUMMARY = \"OTA update package for ${PROJECT_NAME}\"
DESCRIPTION = \"SWUpdate A/B dual-rootfs update package containing the root \
filesystem image, update scripts, and manifest.\"
LICENSE = \"MIT\"
LIC_FILES_CHKSUM = \"file://\${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302\"

inherit swupdate

# Base image whose rootfs is packaged into the .swu file. IMAGE_DEPENDS makes
# bitbake build it first; without it a stale or missing image gets packed.
IMAGE_DEPENDS = \"${BASE_IMAGE}\"
SWUPDATE_IMAGES = \"${BASE_IMAGE}\"

# Filesystem type, as a varflag keyed by image name (must match IMAGE_FSTYPES)
SWUPDATE_IMAGES_FSTYPES[${BASE_IMAGE}] = \".${IMAGE_FSTYPE}.gz\"

# sw-description is picked from update-image/<MACHINE>/ (FILESOVERRIDES)
SRC_URI = \" \\
    file://sw-description \\
    file://update-post.sh \\
\"

${SIGNING_BLOCK}
"

# ---------------------------------------------------------------------------
# STEP 8 -- Summary
# ---------------------------------------------------------------------------
printf "\n${BOLD}${GREEN}============================================================${RESET}\n"
printf "${BOLD}${GREEN}  meta-swupdate-ab initialized successfully!${RESET}\n"
printf "${BOLD}${GREEN}============================================================${RESET}\n\n"

printf "${BOLD}Generated files:${RESET}\n"
find "${SCRIPT_DIR}" \
    -not -path '*/.git/*' \
    -not -path '*/static/*' \
    -not -path '*/keys/*' \
    -not -name 'init-layer.sh' \
    -not -name 'layer.config*' \
    -not -name 'README.md' \
    -not -name '.gitignore' \
    -newer "${CONFIG_FILE}" \
    -type f \
    | sort \
    | sed "s|${SCRIPT_DIR}/||" \
    | while IFS= read -r f; do printf "  + %s\n" "$f"; done

printf "\n${BOLD}Next steps:${RESET}\n\n"
printf "  1. Add this layer to your Yocto build's bblayers.conf:\n"
printf "       \${TOPDIR}/../meta-swupdate-ab \\\\\n\n"
printf "  2. Add packages to your image recipe:\n"
printf "       IMAGE_INSTALL:append = \" swupdate check-update-ota\"\n\n"
printf "  3. Ensure the upstream meta-swupdate layer is present:\n"
printf "       git clone https://github.com/sbabic/meta-swupdate.git\n"
printf "       (add it to bblayers.conf too)\n\n"
printf "  4. Configure U-Boot for A/B boot and rollback on your board.\n"
printf "       See README.md -- Section: U-Boot Configuration\n\n"
printf "  5. Build the update package:\n"
printf "       bitbake update-image\n\n"
printf "  6. Deploy the .swu file from:\n"
printf "       <build>/tmp/deploy/images/<machine>/update-image-<machine>.swu\n\n"
printf "  Full guide: ${CYAN}README.md${RESET}\n\n"

if [ "$ENABLE_SIGNING" = "yes" ]; then
    printf "  ${YELLOW}SECURITY REMINDER:${RESET} Never commit keys/swupdate_priv.pem to a public repo!\n\n"
fi

if [ "$SKIPPED_FILES" -gt 0 ]; then
    printf "  ${YELLOW}NOTE:${RESET} %s existing file(s) were kept unchanged. If you changed\n" "$SKIPPED_FILES"
    printf "  layer.config since the last run, re-run with --force so all generated files\n"
    printf "  match it (keys in keys/ are never overwritten).\n\n"
fi
