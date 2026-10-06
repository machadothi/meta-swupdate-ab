#!/usr/bin/env bash
# =============================================================================
# run-tests.sh -- Tests for init-layer.sh and the on-device scripts
# =============================================================================
#
# USAGE
#   tests/run-tests.sh
#
# Needs bash, openssl and coreutils; no Yocto, no root. Every scenario runs on
# a fresh copy of the repository (tracked and untracked, non-ignored files), so
# the checkout itself is never modified. Uses shellcheck on the generated
# scripts if it is installed, and busybox sh for the slot helper if available.
# =============================================================================

set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

PASSED=0
FAILED=0
pass() { PASSED=$((PASSED + 1)); printf '  ok    %s\n' "$1"; }
fail() { FAILED=$((FAILED + 1)); printf '  FAIL  %s\n' "$1"; }
section() { printf '\n== %s\n' "$1"; }

# check <description> <command...>: passes if the command succeeds
check() {
    local desc="$1"; shift
    if "$@" > /dev/null 2>&1; then pass "$desc"; else fail "$desc"; fi
}

# check_not <description> <command...>: passes if the command fails
check_not() {
    local desc="$1"; shift
    if "$@" > /dev/null 2>&1; then fail "$desc"; else pass "$desc"; fi
}

# fresh_layer <name>: copy the repository to $WORK/<name> and print its path
fresh_layer() {
    local dst="${WORK}/$1"
    mkdir -p "$dst"
    (cd "$REPO" && git ls-files -co --exclude-standard -z | tar --null -T - -cf -) \
        | tar -xf - -C "$dst"
    # Keys are per-pair: never inherit a public key from the developer's checkout
    rm -f "$dst/keys/swupdate_public.pem"
    echo "$dst"
}

# set_config <file> <VAR> <value>: replace the line VAR=... in a config file
set_config() {
    local file="$1" var="$2" value="$3" tmp
    tmp="$(mktemp)"
    sed "s|^${var}=.*|${var}=${value}|" "$file" > "$tmp" && mv "$tmp" "$file"
}

# init <layer dir> [args...]: run init-layer.sh, log to <layer dir>/init.log
init() {
    local dir="$1"; shift
    (cd "$dir" && ./init-layer.sh "$@") > "$dir/init.log" 2>&1
}

SWU="recipes-support/swupdate"
IMG="recipes-images/images"

# -----------------------------------------------------------------------------
section "Default config (example as shipped)"
# -----------------------------------------------------------------------------
L="$(fresh_layer default)"
cp "$L/layer.config.example" "$L/layer.config"
check "init-layer.sh succeeds" init "$L" layer.config

for f in conf/layer.conf \
         "$SWU/swupdate_%.bbappend" \
         "$SWU/swupdate/defconfig" \
         "$SWU/swupdate/ab-slot.sh" \
         "$SWU/swupdate/ota-update.sh" \
         "$SWU/swupdate/mymachine/09-swupdate-args" \
         "$SWU/swupdate/mymachine/swupdate.cfg" \
         "$IMG/update-image.bb" \
         "$IMG/update-image/update-post.sh" \
         "$IMG/update-image/mymachine/sw-description" \
         recipes-core/check-update-ota/check-update-ota.bb; do
    check "generated: $f" test -f "$L/$f"
done
check_not "no update-pre.sh (it would be sourced at daemon startup)" \
    test -e "$L/$SWU/swupdate/update-pre.sh"
# (@@SWUPDATE_AB_ROOTFS_FILE@@ in sw-description is expanded by bitbake instead)
check_not "no init-layer.sh placeholders left" \
    grep -rqE '@@(EMMC_DEVICE|ROOTFS_A_PART|ROOTFS_B_PART)@@' \
    "$L/recipes-support" "$L/recipes-images" "$L/recipes-core"

check "defconfig: signing off" grep -qx 'CONFIG_SIGNED_IMAGES=n' "$L/$SWU/swupdate/defconfig"
check "defconfig: web server off" grep -qx 'CONFIG_WEBSERVER=n' "$L/$SWU/swupdate/defconfig"
check_not "bbappend: no public key when signing is off" \
    grep -q swupdate_public.pem "$L/$SWU/swupdate_%.bbappend"
check_not "bbappend: no per-machine file:// subdirectories" \
    grep -q 'file://mymachine/' "$L/$SWU/swupdate_%.bbappend"
check "bbappend: installs ab-slot.sh outside conf.d" \
    grep -q 'datadir}/swupdate-ab/ab-slot.sh' "$L/$SWU/swupdate_%.bbappend"
check "bbappend: depends on swupdate-client" \
    grep -q 'RDEPENDS:${PN} += "${PN}-client"' "$L/$SWU/swupdate_%.bbappend"

SWD="$L/$IMG/update-image/mymachine/sw-description"
check "sw-description: slot A device" grep -q 'device = "/dev/mmcblk2p2"' "$SWD"
check "sw-description: slot B device" grep -q 'device = "/dev/mmcblk2p3"' "$SWD"
check "sw-description: image file name expanded at build time" \
    grep -q 'filename = "@@SWUPDATE_AB_ROOTFS_FILE@@"' "$SWD"
check "sw-description: image hash filled at build time" \
    grep -q 'sha256 = "$swupdate_get_sha256(@@SWUPDATE_AB_ROOTFS_FILE@@)"' "$SWD"
check "sw-description: script hash filled at build time" \
    grep -q 'sha256 = "$swupdate_get_sha256(update-post.sh)"' "$SWD"
check_not "sw-description: no empty sha256" grep -q 'sha256 = ""' "$SWD"
check_not "sw-description: no install-if-different on scripts" \
    grep -q 'install-if-different' "$SWD"

check "update-image.bb: FSTYPES as varflag with the release's link suffix" \
    grep -q 'SWUPDATE_IMAGES_FSTYPES\[core-image-minimal\] = "${SWUPDATE_AB_LINK_SUFFIX}.ext4.gz"' "$L/$IMG/update-image.bb"
check "update-image.bb: defines the file name used in sw-description" \
    grep -q '^SWUPDATE_AB_ROOTFS_FILE = "core-image-minimal-${MACHINE}${SWUPDATE_AB_LINK_SUFFIX}.ext4.gz"' "$L/$IMG/update-image.bb"
check "update-image.bb: IMAGE_DEPENDS on base image" \
    grep -q 'IMAGE_DEPENDS = "core-image-minimal"' "$L/$IMG/update-image.bb"
check "check-update-ota: depends on libubootenv-bin" \
    grep -q 'RDEPENDS:${PN} = "libubootenv-bin"' "$L/recipes-core/check-update-ota/check-update-ota.bb"
check_not "service: no ordering cycle with multi-user.target" \
    grep -q '^After=multi-user.target' "$L/recipes-core/check-update-ota/files/check-update-ota.service"

# Generated on-device scripts must at least parse
for f in "$SWU/swupdate/mymachine/09-swupdate-args" "$SWU/swupdate/ab-slot.sh" \
         "$SWU/swupdate/ota-update.sh" "$IMG/update-image/update-post.sh" \
         recipes-core/check-update-ota/files/checkUpdateOTA.sh; do
    check "sh -n $f" sh -n "$L/$f"
    if command -v shellcheck > /dev/null 2>&1; then
        check "shellcheck $f" shellcheck -S warning -s sh "$L/$f"
    fi
done

check "re-run without --force succeeds" init "$L" layer.config
check "re-run reports kept files" grep -q 'were kept unchanged' "$L/init.log"

# -----------------------------------------------------------------------------
section "Signing and web server enabled"
# -----------------------------------------------------------------------------
L="$(fresh_layer signing)"
cp "$L/layer.config.example" "$L/layer.config"
set_config "$L/layer.config" ENABLE_SIGNING '"yes"'
set_config "$L/layer.config" ENABLE_WEBSERVER '"yes"'
check "init-layer.sh succeeds" init "$L" layer.config
check "private key generated" test -f "$L/keys/swupdate_priv.pem"
check "private key mode is 600" test "$(stat -c %a "$L/keys/swupdate_priv.pem")" = 600
check "key pair verified" grep -q 'Key pair verified' "$L/init.log"
check "layer ships the public key from keys/" \
    cmp -s "$L/keys/swupdate_public.pem" "$L/$SWU/swupdate/swupdate_public.pem"
check "defconfig: signing compiled in" grep -qx 'CONFIG_SIGNED_IMAGES=y' "$L/$SWU/swupdate/defconfig"
check "defconfig: web server on" grep -qx 'CONFIG_WEBSERVER=y' "$L/$SWU/swupdate/defconfig"
check "swupdate.cfg: public-key-file set" \
    grep -q '^    public-key-file = "/etc/swupdate_public.pem";' "$L/$SWU/swupdate/mymachine/swupdate.cfg"
check "bbappend: installs the public key" grep -q swupdate_public.pem "$L/$SWU/swupdate_%.bbappend"
check "update-image.bb: signs with RSA" grep -q '^SWUPDATE_SIGNING = "RSA"' "$L/$IMG/update-image.bb"

KEY_HASH="$(sha256sum "$L/keys/swupdate_priv.pem")"
check "re-run with --force succeeds" init "$L" layer.config --force
check "--force keeps the private key" test "$KEY_HASH" = "$(sha256sum "$L/keys/swupdate_priv.pem")"

# A public key from another pair must be caught, not shipped
openssl genrsa -out "$WORK/other.pem" 2048 2> /dev/null
openssl rsa -in "$WORK/other.pem" -pubout -out "$L/keys/swupdate_public.pem" 2> /dev/null
check_not "mismatched public key is rejected" init "$L" layer.config --force
check "mismatch error names the public key" grep -q 'does not belong to' "$L/init.log"

# -----------------------------------------------------------------------------
section "Signing on in a clone that has a stale public key but no private key"
# -----------------------------------------------------------------------------
L="$(fresh_layer stalekey)"
cp "$L/layer.config.example" "$L/layer.config"
set_config "$L/layer.config" ENABLE_SIGNING '"yes"'
openssl rsa -in "$WORK/other.pem" -pubout -out "$L/keys/swupdate_public.pem" 2> /dev/null
check "init-layer.sh succeeds" init "$L" layer.config
check "public key re-derived from the new private key" grep -q 'Key pair verified' "$L/init.log"

# -----------------------------------------------------------------------------
section "Disk without a 'p' partition separator (/dev/sda)"
# -----------------------------------------------------------------------------
L="$(fresh_layer sda)"
cp "$L/layer.config.example" "$L/layer.config"
set_config "$L/layer.config" EMMC_DEVICE '"/dev/sda"'
check "init-layer.sh succeeds" init "$L" layer.config
SWD="$L/$IMG/update-image/mymachine/sw-description"
check "sw-description: /dev/sda2" grep -q 'device = "/dev/sda2"' "$SWD"
check "sw-description: /dev/sda3" grep -q 'device = "/dev/sda3"' "$SWD"
check "ab-slot.sh: AB_DEVICE substituted" grep -qx 'AB_DEVICE="/dev/sda"' "$L/$SWU/swupdate/ab-slot.sh"

# -----------------------------------------------------------------------------
section "Two machines"
# -----------------------------------------------------------------------------
L="$(fresh_layer multi)"
cp "$L/layer.config.example" "$L/layer.config"
set_config "$L/layer.config" MACHINES '("board-a" "board-b")'
set_config "$L/layer.config" HW_IDS '("hw-a" "hw-b")'
set_config "$L/layer.config" IDENTIFY_VALUES '("dev-a" "dev-b")'
check "init-layer.sh succeeds" init "$L" layer.config
for m in board-a board-b; do
    check "$m: 09-swupdate-args" test -f "$L/$SWU/swupdate/$m/09-swupdate-args"
    check "$m: sw-description" test -f "$L/$IMG/update-image/$m/sw-description"
    check "$m: hwrevision block" grep -q "do_install:append:$m()" "$L/$SWU/swupdate_%.bbappend"
done
check "board-b: its own hardware ID" grep -q -- '-H hw-b:1.0' "$L/$SWU/swupdate/board-b/09-swupdate-args"

# -----------------------------------------------------------------------------
section "Config path relative to the current directory"
# -----------------------------------------------------------------------------
L="$(fresh_layer relpath)"
mkdir -p "$WORK/elsewhere"
cp "$L/layer.config.example" "$WORK/elsewhere/my.config"
if (cd "$WORK" && "$L/init-layer.sh" elsewhere/my.config) > "$L/init.log" 2>&1; then
    pass "init-layer.sh elsewhere/my.config succeeds"
else
    fail "init-layer.sh elsewhere/my.config succeeds"
fi

# -----------------------------------------------------------------------------
section "Invalid configs are rejected"
# -----------------------------------------------------------------------------
L="$(fresh_layer invalid)"
# expect_reject <description> <error pattern> <VAR> <value>
expect_reject() {
    local desc="$1" pattern="$2" var="$3" value="$4"
    cp "$L/layer.config.example" "$L/bad.config"
    set_config "$L/bad.config" "$var" "$value"
    if init "$L" bad.config; then
        fail "$desc (accepted)"
    elif grep -q -- "$pattern" "$L/init.log"; then
        pass "$desc"
    else
        fail "$desc (wrong error: $(tail -1 "$L/init.log"))"
    fi
}
expect_reject "PROJECT_NAME with spaces" "PROJECT_NAME must be" PROJECT_NAME '"My Project"'
expect_reject "upper-case machine name" "Machine names must be" MACHINES '("Board")'
expect_reject "HW_ID with a colon" "must not contain spaces or colons" HW_IDS '("hw:1")'
expect_reject "array length mismatch" "HW_IDS has 2 entries" HW_IDS '("a" "b")'
expect_reject "same partition for A and B" "must be different" ROOTFS_B_PART '"2"'
expect_reject "EMMC_DEVICE outside /dev" "must start with /dev/" EMMC_DEVICE '"mmcblk2"'
expect_reject "ENABLE_WEBSERVER not yes/no" "ENABLE_WEBSERVER must be" ENABLE_WEBSERVER '"maybe"'
expect_reject "empty required variable" "Missing required variable" BASE_IMAGE '""'
cp "$L/layer.config.example" "$L/bad.config"
sed -i '/^MACHINES=/d' "$L/bad.config"
check_not "missing MACHINES array: rejected" init "$L" bad.config
check "missing MACHINES array: clear error" grep -q 'MACHINES array is missing' "$L/init.log"

# -----------------------------------------------------------------------------
section "update-post.sh stages"
# -----------------------------------------------------------------------------
POST="$REPO/static/update-post.sh"
check "preinst is a no-op" sh "$POST" preinst
check "postfailure is a no-op" sh "$POST" postfailure
check_not "unknown stage fails" sh "$POST" bogus

# -----------------------------------------------------------------------------
section "checkUpdateOTA.sh (stubbed fw_printenv/fw_setenv)"
# -----------------------------------------------------------------------------
STUB="$WORK/stub"
mkdir -p "$STUB/bin" "$STUB/health"
cat > "$STUB/bin/fw_printenv" << 'EOF'
#!/bin/sh
[ -f "$ENVF" ] || { echo "Cannot read environment" >&2; exit 1; }
if [ "$1" = "-n" ]; then sed -n "s/^$2=//p" "$ENVF"; else cat "$ENVF"; fi
EOF
cat > "$STUB/bin/fw_setenv" << 'EOF'
#!/bin/sh
[ "$1" = "-s" ] || exit 2
while IFS='=' read -r k v; do
    grep -v "^$k=" "$ENVF" > "$ENVF.t" || true
    echo "$k=$v" >> "$ENVF.t"
    mv "$ENVF.t" "$ENVF"
done < "$2"
EOF
chmod +x "$STUB/bin/fw_printenv" "$STUB/bin/fw_setenv"
sed "s|^HEALTH_DIR=.*|HEALTH_DIR=\"$STUB/health\"|" "$REPO/static/checkUpdateOTA.sh" > "$STUB/check.sh"
guard() { PATH="$STUB/bin:$PATH" ENVF="$STUB/env" sh "$STUB/check.sh"; }
env_is() { [ "$(tr '\n' ' ' < "$STUB/env")" = "$1" ]; }

rm -f "$STUB/env"
check_not "unreadable environment fails" guard

printf 'bootcount=2\n' > "$STUB/env"
check "no pending update: success" guard
check "no pending update: env untouched" env_is "bootcount=2 "

printf 'upgrade_available=1\nbootcount=1\n' > "$STUB/env"
printf '#!/bin/sh\nexit 1\n' > "$STUB/health/10-check"
chmod +x "$STUB/health/10-check"
check_not "failing health check: not committed" guard
check "failing health check: env untouched" env_is "upgrade_available=1 bootcount=1 "

printf '#!/bin/sh\nexit 0\n' > "$STUB/health/10-check"
check "passing health check: committed" guard
check "passing health check: flags cleared" env_is "upgrade_available=0 bootcount=0 "

# -----------------------------------------------------------------------------
section "ab-slot.sh against this machine's root partition"
# -----------------------------------------------------------------------------
# Find the partition mounted at / and its disk from sysfs (works for /dev/root)
ROOT_MAJMIN="$(awk '$5 == "/" { m = $3 } END { print m }' /proc/self/mountinfo)"
ROOT_SYS="$(readlink -f "/sys/dev/block/${ROOT_MAJMIN}" 2> /dev/null || true)"
if [ -n "$ROOT_SYS" ] && [ -f "$ROOT_SYS/partition" ]; then
    ROOT_PART="$(cat "$ROOT_SYS/partition")"
    ROOT_DISK="/dev/$(basename "$(dirname "$ROOT_SYS")")"
    OTHER=$((ROOT_PART + 10))
    echo "  (root is partition $ROOT_PART of $ROOT_DISK)"

    SHELLS="sh"
    command -v busybox > /dev/null 2>&1 && SHELLS="sh busybox"
    for shell in $SHELLS; do
        SH_CMD=(sh)
        [ "$shell" = busybox ] && SH_CMD=(busybox sh)
        # slot <A> <B>: print "<active> <target> <selection>"; the fields stay
        # empty where detection fails
        slot() {
            sed "s|@@EMMC_DEVICE@@|$ROOT_DISK|; s|@@ROOTFS_A_PART@@|$1|; s|@@ROOTFS_B_PART@@|$2|" \
                "$REPO/static/ab-slot.sh" > "$WORK/ab-slot.sh"
            # shellcheck disable=SC2016 # expanded by the inner shell
            "${SH_CMD[@]}" -c '. "$1"; echo "$(ab_active_part) $(ab_target_part) $(ab_selection)"' \
                _ "$WORK/ab-slot.sh" 2> /dev/null
        }
        check "[$shell] running from A" test "$(slot "$ROOT_PART" "$OTHER")" = "$ROOT_PART $OTHER stable,rootfs2"
        check "[$shell] running from B" test "$(slot "$OTHER" "$ROOT_PART")" = "$ROOT_PART $OTHER stable,rootfs1"
        check "[$shell] root on neither slot fails closed" test "$(slot "$OTHER" "$((OTHER + 1))")" = "  "
    done
else
    echo "  skipped: / is not on a disk partition here (container, LVM, ...)"
fi

# -----------------------------------------------------------------------------
printf '\n%d passed, %d failed\n' "$PASSED" "$FAILED"
[ "$FAILED" -eq 0 ]
