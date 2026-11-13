#!/bin/bash
#
# install.sh -- install an extracted bbctrl update package in place.
#
# Safety properties (audit findings Scripts-3, 5, 9, 11):
#   * Runs under `set -euo pipefail`: a failed step aborts the install
#     with a non-zero status.  "Install complete" is printed only
#     after every step -- including a post-restart service health
#     check -- has succeeded (Scripts-5).
#   * The controller service is always stopped before anything is
#     replaced or flashed, regardless of --no-py / --no-avr
#     combinations (Scripts-9).
#   * Before the installed Python package is touched, a backup of the
#     current package, the helper scripts in /usr/local/bin, the
#     systemd unit and the user configuration is taken.  If the new
#     package fails to install, fails its import check, or the
#     service does not come back up afterwards, the backup is
#     restored and the install fails (Scripts-3).
#   * The host package is installed and sanity-checked first; the AVR
#     is flashed last, and the flasher verifies the finished flash
#     itself (Scripts-8, 9).  A host/AVR version pairing record is
#     written on success.
#   * The installed web root keeps root-owned 755/644 permissions and
#     is located deterministically from the installed package, not
#     from an unquoted `find` result (Scripts-11).
#
# Note: there is still no A/B slot -- the "rollback" here is a file
# level restore of the previous package taken immediately before the
# upgrade, plus (outside this script) the update package that
# update-bbctrl retains until the new install verifies.

set -euo pipefail

UPDATE_AVR=true
UPDATE_PY=true
REBOOT=false

while [ $# -gt 0 ]; do
    case "$1" in
        --no-avr) UPDATE_AVR=false ;;
        --no-py) UPDATE_PY=false ;;
        *) echo "install.sh: ignoring unknown option: $1" >&2 ;;
    esac
    shift 1
done

# Run from the package root regardless of the caller's directory
cd "$(dirname "$0")/.."

BACKUP_DIR=/var/lib/bbctrl/backup/pre-upgrade
CONFIG_FILE=/var/lib/bbctrl/config.json
PAIRING_FILE=/var/lib/bbctrl/installed-versions.txt

fail() { echo "install.sh: ERROR: $*" >&2; exit 1; }
warn() { echo "install.sh: WARNING: $*" >&2; }

# Directories that may hold the installed Python package
site_packages_dirs() {
    local d
    for d in /usr/local/lib/python*/dist-packages; do
        [ -d "$d" ] && echo "$d"
    done
}

# --- Backup of the current installation (Scripts-3) -------------------
backup_current_install() {
    rm -rf "${BACKUP_DIR}.tmp"
    mkdir -p "${BACKUP_DIR}.tmp"

    local list="${BACKUP_DIR}.tmp/file-list"
    : > "$list"

    if [ -e "$CONFIG_FILE" ]; then
        echo "${CONFIG_FILE#/}" >> "$list"
    fi
    if [ -e /etc/systemd/system/bbctrl.service ]; then
        echo "etc/systemd/system/bbctrl.service" >> "$list"
    fi

    local d f
    while IFS= read -r d; do
        for f in "$d"/bbctrl "$d"/bbctrl-*.egg-info "$d"/onefinity-*.egg-info; do
            [ -e "$f" ] && echo "${f#/}" >> "$list"
        done
    done < <(site_packages_dirs)

    for f in /usr/local/bin/update-bbctrl /usr/local/bin/upgrade-bbctrl \
             /usr/local/bin/sethostname /usr/local/bin/reset-video \
             /usr/local/bin/config-wifi /usr/local/bin/config-screen \
             /usr/local/bin/edit-config /usr/local/bin/edit-boot-config \
             /usr/local/bin/browser; do
        [ -e "$f" ] && echo "${f#/}" >> "$list"
    done

    if [ -s "$list" ]; then
        tar -czf "${BACKUP_DIR}.tmp/previous-install.tar.gz" -C / -T "$list"
    fi

    # Replace the previous backup only once the new one is complete
    rm -rf "$BACKUP_DIR"
    mv "${BACKUP_DIR}.tmp" "$BACKUP_DIR"
    sync
    echo "Backed up current installation to $BACKUP_DIR"
}

# --- Restore the backup taken above (Scripts-3) -----------------------
restore_backup() {
    local archive="$BACKUP_DIR/previous-install.tar.gz"
    if [ ! -e "$archive" ]; then
        warn "no backup at $archive; cannot roll back"
        return 1
    fi

    echo "Restoring previous installation from $BACKUP_DIR" >&2

    # Remove the (broken) new package before putting the old one back
    local d
    while IFS= read -r d; do
        rm -rf "$d"/bbctrl "$d"/bbctrl-*.egg-info "$d"/onefinity-*.egg-info
    done < <(site_packages_dirs)

    tar -xzf "$archive" -C /
    systemctl daemon-reload || true
    sync
}

# On an unexpected abort after the service was stopped, at least try
# to leave the controller running again.
SERVICE_STOPPED=false
on_exit() {
    local rc=$?
    if [ "$rc" -ne 0 ] && $SERVICE_STOPPED; then
        echo "install.sh: failed with status $rc; attempting to restart bbctrl" >&2
        systemctl start bbctrl >/dev/null 2>&1 || true
    fi
}
trap on_exit EXIT

# --- Stop the service first, always (Scripts-9) -----------------------
if $UPDATE_PY || $UPDATE_AVR; then
    systemctl stop bbctrl || true
    SERVICE_STOPPED=true
fi

if $UPDATE_PY; then
    backup_current_install

    # Update service
    rm -f /etc/init.d/bbctrl
    cp scripts/bbctrl.service /etc/systemd/system/
    systemctl daemon-reload
    systemctl enable bbctrl
fi

# --- System configuration (non-package steps) --------------------------

# Update config.txt
./scripts/edit-boot-config max_usb_current=1
./scripts/edit-boot-config config_hdmi_boost=8

# TODO Enable GPU
#./scripts/edit-boot-config dtoverlay=vc4-kms-v3d
#./scripts/edit-boot-config gpu_mem=16
#chmod ug+s /usr/lib/xorg/Xorg

# Fix camera
if ! grep -q dwc_otg.fiq_fsm_mask /boot/cmdline.txt; then
    mount -o remount,rw /boot
    sed -i 's/\(.*\)/\1 dwc_otg.fiq_fsm_mask=0x3/' /boot/cmdline.txt
    sync
    mount -o remount,ro /boot
    REBOOT=true
fi

# Enable memory cgroups
if ! grep -q cgroup_memory /boot/cmdline.txt; then
    mount -o remount,rw /boot
    sed -i 's/\(.*\)/\1 cgroup_memory=1/' /boot/cmdline.txt
    sync
    mount -o remount,ro /boot
    REBOOT=true
fi

# Remove Hawkeye
if [ -e /etc/init.d/hawkeye ]; then
    apt-get remove --purge -y hawkeye
fi

# Decrease boot delay
NETWORKING_SERVICE=/etc/systemd/system/network-online.target.wants/networking.service
if [ -e "$NETWORKING_SERVICE" ]; then
    sed -i 's/^TimeoutStartSec=.*$/TimeoutStartSec=1/' "$NETWORKING_SERVICE"
fi

# Change to US keyboard layout
if [ -e /etc/default/keyboard ]; then
    sed -i 's/^XKBLAYOUT="gb"$/XKBLAYOUT="us" # Comment stops change on upgrade/' \
        /etc/default/keyboard
fi

# Setup USB stick automount
if ! diff -q ./scripts/11-automount.rules /etc/udev/rules.d/11-automount.rules >/dev/null 2>&1; then
  cp ./scripts/11-automount.rules /etc/udev/rules.d/
  if [ -e /lib/systemd/system/systemd-udevd.service ]; then
      sed -i 's/^\(MountFlags=slave\)/#\1/' \
          /lib/systemd/system/systemd-udevd.service
  fi
  REBOOT=true
fi

# Increase swap
if [ -e /etc/dphys-swapfile ] && ! grep -q 'CONF_SWAPSIZE=1000' /etc/dphys-swapfile; then
    sed -i 's/^CONF_SWAPSIZE=.*$/CONF_SWAPSIZE=1000/' /etc/dphys-swapfile
    REBOOT=true
fi

# Install .Xresources & .xinitrc
cp scripts/Xresources ~pi/.Xresources
chown pi:pi ~pi/.Xresources
cp scripts/xinitrc ~pi/.xinitrc
chmod +x ~pi/.xinitrc
chown pi:pi ~pi/.xinitrc

#Configure the "ratpoison" window manager
if [ ! -e ~pi/.ratpoisonrc ]; then
    cp scripts/ratpoisonrc ~pi/.ratpoisonrc
    chmod 644 ~pi/.ratpoisonrc
    chown pi:pi ~pi/.ratpoisonrc
fi

# Install bbserial
MODSRC=src/bbserial/bbserial.ko
MODDST="/lib/modules/$(uname -r)/kernel/drivers/tty/serial/bbserial.ko"
if ! diff -q "$MODSRC" "$MODDST" >/dev/null 2>&1; then
    mkdir -p "$(dirname "$MODDST")"
    cp "$MODSRC" "$MODDST"
    depmod
    REBOOT=true
fi

# Install rc.local
cp scripts/rc.local /etc/

# Ensure that the watchdog python library is installed
if ! pip3 list --format=columns 2>/dev/null | grep -q watchdog; then
    pip3 install scripts/pathtools-0.1.2.tar.gz scripts/watchdog-v0.10.6.tar.gz
fi

# --- Install the host package, then check it (Scripts-3, 9, 11) -------
if $UPDATE_PY; then
    # Remove the previous distribution metadata (both the historical
    # "bbctrl" name and the canonical "onefinity" name, Scripts-7);
    # the package directory itself is replaced by the install below
    # and the full previous tree is in the backup.
    while IFS= read -r d; do
        rm -rf "$d"/bbctrl-*.egg-info "$d"/onefinity-*.egg-info
    done < <(site_packages_dirs)

    if ! ./setup.py install --force; then
        restore_backup || true
        fail "host package installation failed; previous installation restored"
    fi

    # Sanity-check the new package before anything depends on it
    if ! python3 -c 'import bbctrl' 2>/dev/null; then
        restore_backup || true
        fail "newly installed bbctrl package does not import; previous installation restored"
    fi

    # Web root: locate it deterministically from the installed
    # package and keep it root-owned and non-world-writable
    # (Scripts-11).
    HTTP_DIR="$(python3 -c 'import os, bbctrl; print(os.path.join(os.path.dirname(bbctrl.__file__), "http"))')"
    [ -n "$HTTP_DIR" ] \
        || fail "installed bbctrl http directory not found (got: $HTTP_DIR)"
    [ -d "$HTTP_DIR" ] \
        || fail "installed bbctrl http directory not found (got: $HTTP_DIR)"
    chown -R root:root "$HTTP_DIR"
    find "$HTTP_DIR" -type d -exec chmod 755 {} +
    find "$HTTP_DIR" -type f -exec chmod 644 {} +
fi

# Expand the file system if necessary
chmod +x ./scripts/resize_root_fs.sh
if ./scripts/resize_root_fs.sh; then
    REBOOT=true
fi

# Install our logrotate config
cp ./scripts/bbctrl-logrotate /etc/logrotate.d/bbctrl
chown root:root /etc/logrotate.d/bbctrl

# Ensure logrotate runs on every boot (for systems with no network, thus bad clock)
if [ ! -e /etc/cron.d/reboot ]; then
    cp ./scripts/cron_d_reboot /etc/cron.d/reboot
    mkdir -p /etc/cron.reboot
    cp ./scripts/cron_reboot_logrotate /etc/cron.reboot/logrotate
fi

# Delete some cookies that were left behind in older images
chmod +x ./scripts/delete-cookies.py
./scripts/delete-cookies.py || warn "delete-cookies.py failed (continuing)"
pkill -HUP chromium || true # Force Chromium to restart, to see the cookie changes

# Get rid of some old files that were left behind in older images
rm -rf /home/pi/hostinfo.txt
rm -rf /home/pi/ssidinfo.txt
rm -rf /home/Downloads/bbctrl-20200415.json
rm -rf /home/bbmc/bbctrl-1.0.0.tar.bz2
rm -rf /home/bbmc/hostinfo.sh
rm -rf /home/bbmc/index.html
rm -rf /home/bbmc/favicon.ico

# Force a logrotate to get everything into a good state
logrotate -f /etc/logrotate.conf

# --- Flash the AVR last (Scripts-9) -----------------------------------
# Only once the host package is installed and verified does the
# motion board get new firmware.  The flasher validates the hex file
# and verifies the finished flash against the bootloader CRC
# (Scripts-8).  If flashing fails the host package is rolled back so
# host and AVR firmware are not left at mismatched versions.
if $UPDATE_AVR; then
    chmod +x ./scripts/avr109-flash.py
    if ! ./scripts/avr109-flash.py src/avr/bbctrl-avr-firmware.hex; then
        if $UPDATE_PY; then
            restore_backup || true
        fi
        fail "AVR firmware flash failed; see above for details"
    fi
fi

# --- Restart and verify (Scripts-3, 5) --------------------------------
if $UPDATE_PY || $UPDATE_AVR; then
    systemctl restart bbctrl

    SERVICE_OK=false
    for _ in $(seq 1 30); do
        if systemctl is-active --quiet bbctrl; then
            SERVICE_OK=true
            break
        fi
        sleep 1
    done

    if ! $SERVICE_OK; then
        if $UPDATE_PY; then
            restore_backup || true
            systemctl restart bbctrl || true
        fi
        fail "bbctrl service did not come up after install"
    fi
    SERVICE_STOPPED=false

    # Record the host/AVR pairing that is now running (Scripts-9)
    {
        echo "host-version: $(python3 -c 'import json; print(json.load(open("package.json"))["version"])' 2>/dev/null || echo unknown)"
        if [ -e src/avr/bbctrl-avr-firmware.hex ]; then
            echo "avr-hex-sha256: $(sha256sum src/avr/bbctrl-avr-firmware.hex | awk '{print $1}')"
        fi
        echo "installed: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    } > "${PAIRING_FILE}.tmp"
    mv "${PAIRING_FILE}.tmp" "$PAIRING_FILE"
fi

sync

echo "Install complete"

if $REBOOT; then
    echo "Rebooting"
    reboot
fi
