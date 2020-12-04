
This repository provides the `build` tool to build binary packages in a
a safe and reproducible way. It can be used standalone or within the
Open Build Service (OBS).

Supported build environments
============================

 Unsecure:
 - chroot
 - LXC

 secure but with limited reproducibility:
 - docker
 - nspawn

 secure and with full reproducibility:
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
   which runs a qemu system emulator inside of KVM. This can
   be considered also secure and reproducibility.
 - The "emulator" VM can be used to run builds using any other
   emulator via a wrapper script.
 - A qemu user land emulation is also possible. This would give
   higher speed, but requieres a preparation inside of the base
   distribution for this mode.

Support build formats
=====================

 Major package formats
 - spec to rpm      (eg SUSE, Fedora, Mandriva)
 - dsc to deb       (eg Debian, Ubuntu)
 - PKGBUILD to pkg  (eg Arch Linux)

 Image formats
 - Dockerfile       (Docker container via docker or podman tooling)
 - kiwi appliances  (this include a long list of formats support by the kiwi tool.
                     From live isos, network deployment images, VM images to docker containers)
 - AppImage
 - FlatPak
 - Snapcraft
 - SimpleImage      (chroot tar ball based on rpm spec file syntax)
 - Debian Livebuild
 - Preinstallimages (for speeding up builds esp. inside of OBS)

 Special modes and formats:
 - debbuild         (building debian debs our of rpm spec file)
 - debbootstrap     (debian builds using debootstrap as engine)
 - mock             (rpm spec file build using mock as engine)
 - collax           (debian package variation)
 - fissile          (docker images based on BOSH dev releases)
 - helm             (helm charts)


Use the --help option for more information.

