#!/bin/sh
# =============================================================================
# check-build.sh -- Inspect the CI build output
# =============================================================================
# USAGE
#   ci/check-build.sh <deploy dir>    e.g. build/tmp/deploy/images/qemuarm64
#
# Checks that the .swu contains what sw-description promises, that the class
# filled in every hash and file name, that the package is signed, and that the
# OTA packages made it into the base image.
# =============================================================================

set -eu

DEPLOY="$1"
fail() { echo "FAIL: $*" >&2; exit 1; }

# Link name is update-image-<machine>.swu, or .rootfs.swu on nanbield and newer
SWU="$(find "$DEPLOY" -maxdepth 1 -name 'update-image-*.swu' -type l | head -n 1)"
[ -n "$SWU" ] || fail "no update-image-*.swu link in $DEPLOY"
echo "== $SWU"

LIST="$(cpio -it --quiet < "$SWU")"
echo "$LIST"

[ "$(echo "$LIST" | head -n 1)" = "sw-description" ] \
    || fail "sw-description must be the first file in the .swu"
echo "$LIST" | grep -qx 'sw-description.sig' || fail "missing sw-description.sig (signing on)"
echo "$LIST" | grep -qx 'update-post.sh'     || fail "missing update-post.sh"
echo "$LIST" | grep -qE '^core-image-minimal-.*\.ext4\.gz$' || fail "missing rootfs image"

DESC="$(cpio -i --quiet --to-stdout sw-description < "$SWU")"
echo "== sw-description (image entries)"
echo "$DESC" | grep -E 'filename|sha256|device'

echo "$DESC" | grep -q '@@' && fail "unexpanded @@VARIABLE@@ in sw-description"
echo "$DESC" | grep -q 'swupdate_get_sha256' && fail "unexpanded \$swupdate_get_sha256 in sw-description"

# Two slots x (image + script) = four hashes
HASHES="$(echo "$DESC" | grep -cE 'sha256 = "[0-9a-f]{64}"')"
[ "$HASHES" -eq 4 ] || fail "expected 4 sha256 hashes, found $HASHES"

# Every file sw-description names must be in the archive
for f in $(echo "$DESC" | sed -n 's/.*filename = "\([^"]*\)".*/\1/p' | sort -u); do
    echo "$LIST" | grep -qxF "$f" || fail "sw-description names $f, which is not in the .swu"
done

MANIFEST="$(find "$DEPLOY" -maxdepth 1 -name 'core-image-minimal-*.manifest' | head -n 1)"
[ -n "$MANIFEST" ] || fail "no core-image-minimal manifest in $DEPLOY"
echo "== $MANIFEST"
for pkg in swupdate swupdate-client swupdate-www check-update-ota libubootenv-bin; do
    grep -q "^$pkg " "$MANIFEST" || fail "package $pkg not in the image"
    echo "  $pkg: installed"
done

echo "== build output OK"
