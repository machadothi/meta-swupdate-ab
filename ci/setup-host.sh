#!/bin/sh
# =============================================================================
# setup-host.sh -- Prepare an Ubuntu 24.04 GitHub runner for a Yocto build
# =============================================================================
# Installs the Yocto host packages and kas, and allows the unprivileged user
# namespaces bitbake uses for task isolation (Ubuntu 24.04 blocks them through
# AppArmor by default).
# =============================================================================

set -eu

sudo apt-get update
sudo apt-get install -y --no-install-recommends \
    build-essential chrpath cpio debianutils diffstat file gawk gcc git \
    iputils-ping libacl1 locales lz4 python3 python3-git python3-jinja2 \
    python3-pexpect python3-pip python3-subunit socat texinfo unzip wget \
    xz-utils zstd

sudo sysctl -w kernel.apparmor_restrict_unprivileged_userns=0

pipx install kas
kas --version
