SUMMARY = "OTA Update Rollback Guard Service"
DESCRIPTION = "Systemd oneshot service that commits a successful boot after \
an OTA update, closing the U-Boot rollback window. Must run at every boot \
to prevent spurious rollbacks."
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

SRC_URI = " \
    file://check-update-ota.service \
    file://checkUpdateOTA.sh \
"

inherit systemd

SYSTEMD_SERVICE:${PN} = "check-update-ota.service"
SYSTEMD_AUTO_ENABLE:${PN} = "enable"

# libubootenv-bin provides fw_printenv and fw_setenv
# (u-boot-tools only ships mkimage and friends)
RDEPENDS:${PN} = "libubootenv-bin"

# Releases before styhead unpack into WORKDIR and have no UNPACKDIR
UNPACKDIR ??= "${WORKDIR}"

do_install() {
    # Install the systemd service unit
    install -d ${D}${systemd_system_unitdir}
    install -m 0644 ${UNPACKDIR}/check-update-ota.service ${D}${systemd_system_unitdir}/

    # Install the rollback guard script
    install -d ${D}${bindir}
    install -m 0755 ${UNPACKDIR}/checkUpdateOTA.sh ${D}${bindir}/

    # Health-check hooks: every executable here must succeed before an update
    # is committed (see checkUpdateOTA.sh)
    install -d ${D}${sysconfdir}/ota-health.d
}

FILES:${PN} = " \
    ${systemd_system_unitdir}/check-update-ota.service \
    ${bindir}/checkUpdateOTA.sh \
    ${sysconfdir}/ota-health.d \
"
