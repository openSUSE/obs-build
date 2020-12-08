
This repository provides the `build` tool to build binary packages in a
a safe and reproducible way. It can be used standalone or within the
Open Build Service (OBS).

Latest packages for `obs-build` can be downloaded from
[openSUSE:Tools repositories](https://download.opensuse.org/repositories/openSUSE:/Tools/).

Supported build environments
============================
 Unsecure:
 - chroot
 - LXC

 Secure but with limited reproducibility:
 - docker
 - nspawn

 Secure and with full reproducibility:
 - KVM
 - XEN
 - ZVM (S390)

 In addition there is currently experimental support for
 - UML
 - PVM (PowerPC)
 - OpenStack
 - Amazon EC2

 For hardware emulation there are
 - qemu
   which runs a QEMU system emulator inside of KVM. This can
   be considered also secure and reproducible.
 - The "emulator" VM can be used to run builds using any other
   emulator via a wrapper script.
 - A QEMU user land emulation is also possible. This would give
   higher speed, but requires a preparation inside of the base
   distribution for this mode.

Supported build formats
=======================

 Major distribution package formats
 - spec to rpm           eg SUSE, Fedora, RedHat, CentOS, Mandriva
 - dsc to deb            eg Debian, Ubuntu
 - PKGBUILD to pkg       eg Arch Linux

 Image formats
 - Dockerfile            Docker container via docker or podman tooling)
 - kiwi appliances       This include a long list of formats supported by the kiwi tool.
                         From live USB stick images, network deployment images, VM images
                         to docker containers
                         https://documentation.suse.com/kiwi/9/html/kiwi/building-types.html
 - SUSE Product          SUSE product media builds
 - SimpleImage           chroot tar ball based on rpm spec file syntax
 - Debian Livebuild
 - Preinstallimages      for speeding up builds esp. inside of OBS

 Desktop Image formats
 - AppImage
 - FlatPak
 - Snapcraft

 Special modes and formats:
 - debbuild              building debian debs our of rpm spec file
 - debbootstrap          debian builds using debootstrap as engine
 - mock                  rpm spec file build using mock as engine
 - collax                debian package variation
 - fissile               docker images based on BOSH dev releases
 - helm                  helm charts


Use the --help option for more information.

