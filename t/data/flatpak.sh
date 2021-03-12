#!/bin/bash
set -ex

cd /obs-build

zypper -n install git hostname tar gzip fuse wget \
  perl perl-XML-Parser perl-libwww-perl perl-YAML-LibYAML perl-LWP-Protocol-https

export BUILD_DIR=$PWD BUILD_ROOT=/var/tmp/obs-build
cd t/data/mahjongg
wget https://download.gnome.org/sources/gnome-mahjongg/3.38/gnome-mahjongg-3.38.2.tar.xz
# We need at least flatpak-1.6.3-lp152.3.3.1.src from the update repo because
# flatpak-1.6.3-lp152.2.1.x86_64 has a packaging bug
$BUILD_DIR/build --nosignature \
  --repo http://download.opensuse.org/update/leap/15.2/oss/ \
  --repo http://download.opensuse.org/distribution/leap/15.2/repo/oss/ \
  --repo http://download.opensuse.org/repositories/OBS:/Flatpak/openSUSE_Leap_15.2/ \
  flatpak.yaml -release 23

flatpakfile="$BUILD_ROOT/usr/src/packages/OTHER/org.gnome.Mahjongg-3.38.2-23.flatpak"
if [[ -e "$flatpakfile" ]] ; then
  echo OK
else
  echo NOT OK
  exit 1
fi

zypper -n install flatpak

flatpak remote-add --if-not-exists flathub https://dl.flathub.org/repo/flathub.flatpakrepo

flatpak install --noninteractive "$flatpakfile"

flatpak list

flatpak list | grep org.gnome.Mahjongg

find / -type l -name org.gnome.Mahjongg | xargs ls -l

/var/lib/flatpak/exports/bin/org.gnome.Mahjongg --version

# It reports its version on stderr
/var/lib/flatpak/exports/bin/org.gnome.Mahjongg --version 2>&1 | grep 'gnome-mahjongg 3.38.2'

