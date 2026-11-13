#!/bin/bash -e

export LC_ALL=C
cd /mnt/host

# Update the system.  TLS peer verification stays ON (audit
# Scripts-13): this chroot builds gplan.so, which is shipped on
# controllers, so packages must come from a verified peer.  If the
# old image's CA store is too stale to verify, refresh
# ca-certificates from a trusted source -- do not disable
# verification.

apt update
# Install packages
apt install -y scons build-essential libssl-dev python3-dev
