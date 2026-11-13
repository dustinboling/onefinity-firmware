#!/bin/bash -ex
#
# rpi-chroot.sh -- mount a Raspberry Pi image's partitions and run a
# command inside it under qemu.
#
# Partition offsets are derived from the image's own partition table
# (audit Scripts-21): the previous hard-coded byte offsets were only
# correct for one specific 2017 Raspbian layout, and fsck/mounts on
# the wrong bytes can corrupt a different image.  The command to run
# in the chroot is passed through as an argv array -- callers that
# used to rely on word-splitting of a single string should pass each
# argument separately.

ROOT="$PWD/rpi-root"

if [ $# -lt 1 ]; then
    echo "Usage: $0 <image> [command [args...]]"
    exit 1
fi

IMAGE="$1"
shift
EXEC=("$@")

# install dependecies
if [ ! -e /usr/bin/qemu-arm-static ]; then
    apt-get update
    apt-get install -y qemu qemu-user-static binfmt-support
fi

if ! command -v parted >/dev/null 2>&1; then
    echo "parted is required to read the image's partition table" >&2
    exit 1
fi

# Byte offset of 1-based partition $1 of $IMAGE, from parted
partition_offset() {
    local part="$1" offset
    offset=$(parted -m "$IMAGE" unit B print 2>/dev/null \
        | awk -F: -v n="$part" '$1 == n {gsub(/B$/, "", $2); print $2}')
    if ! [[ "$offset" =~ ^[0-9]+$ ]]; then
        echo "Could not determine offset of partition $part in $IMAGE" >&2
        return 1
    fi
    echo "$offset"
}

LOOP_BOOT=
LOOP_ROOT=

# Clean up on EXIT
function cleanup {
    umount "$ROOT"/{dev/pts,dev,sys,proc,boot,mnt/host,} 2>/dev/null || true
    if [ -n "$LOOP_BOOT" ]; then
        losetup -d "$LOOP_BOOT" 2>/dev/null || true
    fi
    if [ -n "$LOOP_ROOT" ]; then
        losetup -d "$LOOP_ROOT" 2>/dev/null || true
    fi
    rmdir "$ROOT" 2>/dev/null || true
}
trap cleanup EXIT

BOOT_OFFSET=$(partition_offset 1)
ROOT_OFFSET=$(partition_offset 2)

LOOP_BOOT=$(losetup -f)
losetup -o "$BOOT_OFFSET" "$LOOP_BOOT" "$IMAGE"

LOOP_ROOT=$(losetup -f)
losetup -o "$ROOT_OFFSET" "$LOOP_ROOT" "$IMAGE"

# check and fix filesystems
fsck -f "$LOOP_BOOT"
fsck -f "$LOOP_ROOT"

# make dir
mkdir -p "$ROOT"

# mount partition
mount -o rw "$LOOP_ROOT" -t ext4 "$ROOT"
mount -o rw "$LOOP_BOOT" "$ROOT/boot"

# mount binds
mount --bind /dev "$ROOT/dev/"
mount --bind /sys "$ROOT/sys/"
mount --bind /proc "$ROOT/proc/"
mount --bind /dev/pts "$ROOT/dev/pts"
if [ -e ./rpi-share ]; then
    mkdir -p "$ROOT/mnt/host"
    mount --bind ./rpi-share "$ROOT/mnt/host"
fi

# copy qemu binary
cp /usr/bin/qemu-arm-static "$ROOT/usr/bin/"

# chroot to raspbian
if [ "${#EXEC[@]}" -gt 0 ]; then
    chroot "$ROOT" "${EXEC[@]}"
else
    chroot "$ROOT"
fi
