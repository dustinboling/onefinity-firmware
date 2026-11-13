#!/bin/bash -ex

IMG_DATE=2017-11-29
IMG_BASE=${IMG_DATE}-raspbian-stretch-lite
BASE_URL=https://downloads.raspberrypi.org/raspbian_lite/images
IMG_URL=$BASE_URL/raspbian_lite-2017-12-01/$IMG_BASE.zip
GPLAN_IMG=gplan-dev.img

# SHA-256 of the base image zip as published by the Raspberry Pi
# Foundation for raspbian_lite-2017-12-01 (audit Scripts-14).  The
# downloaded image becomes the foundation of the dev/controller
# image and is chrooted into as root, so it is verified before use
# and the build aborts on any mismatch.
IMG_SHA256=e942b70072f2e83c446b9de6f202eb8f9692c06e7d92c343361340cc016e0c9f

# Create dev image
if [ ! -e "$GPLAN_IMG" ]; then

    # Get base image
    if [ ! -e "$IMG_BASE.img" ]; then
        if [ ! -e "$IMG_BASE.zip" ]; then
            wget "$IMG_URL"
        fi

        # Verify the zip -- whether just downloaded or already on
        # disk -- against the publisher's checksum (Scripts-14)
        echo "$IMG_SHA256  $IMG_BASE.zip" | sha256sum -c -

        # Validate member names, then extract into a fresh directory
        python3 - "$IMG_BASE.zip" <<'PYEOF'
import sys, zipfile
with zipfile.ZipFile(sys.argv[1]) as z:
    for name in z.namelist():
        parts = [p for p in name.split('/') if p not in ('', '.')]
        if name.startswith('/') or '..' in parts:
            sys.exit('unsafe member in zip: %r' % name)
PYEOF
        EXTRACT_DIR="$IMG_BASE.extract"
        rm -rf "$EXTRACT_DIR"
        mkdir -p "$EXTRACT_DIR"
        unzip -o "$IMG_BASE.zip" -d "$EXTRACT_DIR"
        if [ ! -e "$EXTRACT_DIR/$IMG_BASE.img" ]; then
            echo "$IMG_BASE.zip did not contain $IMG_BASE.img" >&2
            exit 1
        fi
        mv "$EXTRACT_DIR/$IMG_BASE.img" "$IMG_BASE.img"
        rm -rf "$EXTRACT_DIR"
    fi

    # Copy base image
    cp "$IMG_BASE.img" "$GPLAN_IMG.tmp"

    # Init image
    mkdir -p rpi-share
    cp ./scripts/gplan-init-dev-img.sh rpi-share
    chmod +x ./rpi-share/gplan-init-dev-img.sh
    sudo ./scripts/rpi-chroot.sh "$GPLAN_IMG.tmp" /mnt/host/gplan-init-dev-img.sh

    # Move image
    mv "$GPLAN_IMG.tmp" "$GPLAN_IMG"
fi

mkdir -p rpi-share || true

if [ ! -e rpi-share/cbang ]; then
    mkdir -p rpi-share/cbang
    git -C rpi-share/cbang init
    git -C rpi-share/cbang remote add origin https://github.com/CauldronDevelopmentLLC/cbang
	git -C rpi-share/cbang fetch --depth 1 origin 18f1e963107ef26abe750c023355a5c40dd07853
    git -C rpi-share/cbang reset --hard FETCH_HEAD
fi

if [ ! -e rpi-share/camotics ]; then
    mkdir -p rpi-share/camotics
    git -C rpi-share/camotics init
    git -C rpi-share/camotics remote add origin https://github.com/CauldronDevelopmentLLC/camotics
	git -C rpi-share/camotics fetch --depth 1 origin ec876c80d20fc19837133087cef0c447df5a939d
    git -C rpi-share/camotics reset --hard FETCH_HEAD
fi
