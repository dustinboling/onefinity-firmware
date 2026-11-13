#!/bin/bash -e

export LC_ALL=C
cd /mnt/host

# Update the system
apt-get update
apt-get dist-upgrade -y

# Install packages
apt-get install -y avahi-daemon avrdude minicom python3-pip python3-smbus \
  i2c-tools python3-rpi.gpio libjpeg8 wiringpi dnsmasq hostapd \
  iptables-persistent chromium-browser xorg rpd-plym-splash samba
pip3 install --upgrade tornado sockjs-tornado pyserial

# Clean
apt-get autoclean

# Enable avahi
update-rc.d avahi-daemon defaults

# Change hostname
sed -i "s/raspberrypi/bbctrl/" /etc/hosts /etc/hostname

# Create bbmc user (Scripts-6: no hard-coded, published password).
# The password is per-device: taken from $BBMC_PASSWORD when the
# image builder provides one, otherwise generated randomly for this
# device.  It is stored hashed with SHA-512 (via chpasswd/PAM, not
# MD5-crypt), must be changed at first login, and a generated
# password is left in a root-only file for the factory operator --
# it is never a constant shared between images.
if [ -n "${BBMC_PASSWORD:-}" ]; then
    BBMC_PW="$BBMC_PASSWORD"
    BBMC_PW_GENERATED=false
else
    BBMC_PW="$(openssl rand -base64 18)"
    BBMC_PW_GENERATED=true
fi
useradd -m -s /bin/bash bbmc
printf 'bbmc:%s\n' "$BBMC_PW" | chpasswd
chage -d 0 bbmc # Force a password change on first login
if $BBMC_PW_GENERATED; then
    umask 077
    printf '%s\n' "$BBMC_PW" > /root/bbmc-initial-password.txt
    echo "Generated a per-device password for user 'bbmc'; see /root/bbmc-initial-password.txt (delete it after first login)"
fi
sed -i 's/pi$/pi,bbmc/g' /etc/group
passwd -l pi

# Disable console on serial port
sed -i 's/console=[a-zA-Z0-9]*,115200 \?//' /boot/cmdline.txt

# Disable i2c HAT ID probe
echo -n " bcm2708.vc_i2c_override=1" >> /boot/cmdline.txt

# Enable I2C
sed -i 's/#dtparam=i2c/dtparam=i2c/' /boot/config.txt
#echo 'dtparam=i2c_vc=on' >> /boot/config.txt
echo i2c-bcm2708 >> /etc/modules
echo i2c-dev >> /etc/modules

# Install bbctrl w/ init.d script
cp bbctrl.init.d /etc/init.d/bbctrl
chmod +x /etc/init.d/bbctrl
update-rc.d bbctrl defaults

# Disable Pi 3 USART BlueTooth swap
echo -e "\ndtoverlay=pi3-disable-bt" >> /boot/config.txt
rm -f /etc/systemd/system/multi-user.target.wants/hciuart.service

# Install hawkeye
dpkg -i hawkeye_0.6_armhf.deb
sed -i 's/localhost/0.0.0.0/' /etc/hawkeye/hawkeye.conf
echo 'ACTION=="add", KERNEL=="video0", RUN+="/usr/sbin/service hawkeye restart"' > /etc/udev/rules.d/50-hawkeye.rules
adduser hawkeye video

# Disable HDMI to save power and remount /boot read-only
sed -i 's/^exit 0$//' /etc/rc.local
echo "mount -o remount,ro /boot" >> /etc/rc.local
echo "gpio mode 27 alt3" >> /etc/rc.local # Enable serial CTS on pin 27

# Dynamic clock to save power
echo -e "\n# Dynamic clock\nnohz=on" >> /boot/config.txt

# Shave 2 sec off of boot time
echo -e "\n# Faster boot\ndtparam=sd_overclock=100" >> /boot/config.txt

# SSH is NOT enabled in the factory image (Scripts-6).  It used to be
# switched on here while the only account had a published password.
# To enable it on a specific device, change the account password
# first and then create the file /boot/ssh.
rm -f /boot/ssh

# Fix boot
sed -i 's/ root=[^ ]* / root=\/dev\/mmcblk0p2/' /boot/cmdline.txt
sed -i 's/^PARTUUID=.*\/boot/\/dev\/mmcblk0p1 \/boot/' /etc/fstab
sed -i 's/^PARTUUID=.*\//\/dev\/mmcblk0p2 \//' /etc/fstab

# Enable browser in xorg
sed -i 's/allowed_users=console/allowed_users=anybody/' /etc/X11/Xwrapper.config
echo "sudo -u pi startx" >> /etc/rc.local
cp /mnt/host/xinitrc /home/pi/.xinitrc
cp /mnt/host/ratpoisonrc /home/pi/.ratpoisonrc
cp /mnt/host/xorg.conf /etc/X11/

# Configure the screen to not do overscan (only necessary for TVs)
sed -i 's/^#disable_overscan/disable_overscan/' /boot/config.txt

# Boot splash
mkdir -p /usr/share/plymouth/themes/buildbotics/
cp -av /mnt/host/splash/* /usr/share/plymouth/themes/buildbotics/
echo -n " quiet splash logo.nologo plymouth.ignore-serial-consoles" >> /boot/cmdline.txt
plymouth-set-default-theme -R buildbotics

# Samba
# TODO install custom smb.conf
# Set the Samba password to the same per-device password as the OS
# account (which is forced to change at first OS login).
printf '%s\n%s\n' "$BBMC_PW" "$BBMC_PW" | smbpasswd -a -s bbmc
unset BBMC_PW BBMC_PASSWORD

# Install bbctrl -- extract the package with the same care as the
# update path (Scripts-4): validate member names first, extract with
# safe options into a fresh directory, and use the canonical package
# name (Scripts-7).
PKG_FILE="$(compgen -G '/mnt/host/onefinity-*.tar.bz2' | head -n 1 || true)"
if [ -z "$PKG_FILE" ]; then
    echo "No onefinity-*.tar.bz2 package found in /mnt/host" >&2
    exit 1
fi
tar -tjf "$PKG_FILE" | while IFS= read -r member; do
    case "$member" in
        /*|../*|*/../*|*/..|..)
            echo "Unsafe member in $PKG_FILE: $member" >&2; exit 1 ;;
    esac
done
PKG_DIR="$(basename "$PKG_FILE" .tar.bz2)"
rm -rf "/tmp/${PKG_DIR}"
mkdir -p "/tmp/${PKG_DIR}"
tar --no-same-owner --no-same-permissions --delay-directory-restore \
    -xjf "$PKG_FILE" -C /tmp
cd "/tmp/${PKG_DIR}"
./setup.py install
cd /mnt/host
rm -rf "/tmp/${PKG_DIR}"


# Shutdown is via sudo for the one account that needs it -- NOT via
# setuid-root halt/reboot/shutdown/poweroff binaries (Scripts-6).
cat > /etc/sudoers.d/bbctrl-shutdown <<'EOF'
# Allow the bbmc account to shut the controller down through sudo.
bbmc ALL=(root) NOPASSWD: /sbin/halt, /sbin/reboot, /sbin/shutdown, /sbin/poweroff
EOF
chmod 440 /etc/sudoers.d/bbctrl-shutdown
if command -v visudo >/dev/null 2>&1; then
    visudo -cf /etc/sudoers.d/bbctrl-shutdown
fi

# Clean up
apt-get autoremove -y
apt-get autoclean -y
