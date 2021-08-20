
This repository provides the `build` tool to build binary packages in a
a safe and reproducible way. It can be used standalone or within the
[Open Build Service](http://openbuildservice.org) (OBS).

Latest packages for `obs-build` are available from
[openSUSE:Tools downloads](https://software.opensuse.org/download/package?package=obs-build&project=openSUSE%3ATools).

Supported build environments
============================
Unsecure
---
- `chroot`
- `LXC`

 Secure but with limited reproducibility
 ---
 - `docker`
 - `nspawn`

 Secure and with full reproducibility
 ---
 - `KVM`
 - `XEN`
 - `ZVM` (**S390**)

 Experimental support
 ---
In addition, there is currently experimental support for

 - `UML`
 - `PVM` (**PowerPC**)
 - [OpenStack](http://openstack.org)
 - [Amazon EC2](http://ec2.amazon.com)

 For hardware emulation there are
 ---
 - `qemu`,
   which runs a `QEMU` system emulator inside of `KVM`. This can
   be considered also secure and reproducible.
 - The "emulator" VM can be used to run builds using any other
   emulator via a wrapper script.
 - A `QEMU` user land emulation is also possible. This would give
   higher speed, but requires a preparation inside of the base
   distribution for this mode.

Supported build formats
=======================

 Major distribution package formats
 ---
 - `spec` to `rpm`,           e.g. [SUSE](http://suse.com), [Fedora](http://getfedora.org), [RedHat](http://redhat.com),
 [CentOS](http://centos.org), [Mandriva](http://mageia.org)
 - `dsc` to `deb`,            e.g. [Debian](http://debian.org), [Ubuntu](http://ubuntu.com)
 - `PKGBUILD` to `pkg`,       e.g. [Arch Linux](http://archlinux.org)

 Image formats
 ---
 - `Dockerfile`&mdash;[Docker](http://docker.com) container via `docker` or `podman` tooling)
 - kiwi appliances&mdash;This includes a [long list of formats](http://documentation.suse.com/kiwi/9/html/kiwi/image-types.html)
 supported by the kiwi tool
                         From live USB stick images, network deployment images, VM images
                         to docker containers
 - SUSE Product&mdash;[SUSE](http://suse.com) product media builds
 - *SimpleImage*&mdash;`chroot` `tar` ball based on `rpm` spec file syntax
 - [Debian](http://debian.org) *Livebuild*
 - *Preinstallimages*&mdash;for speeding up builds esp. inside of [OBS](http://openbuildservice.org/)

 Desktop Image formats
 ---
 - *AppImage*
 - *FlatPak*
 - *Snapcraft*

 Special modes and formats
 ---
 - `debbuild`─building [debian](http://debian.org) `deb`s our of `rpm` spec file
 - `debbootstrap`─[debian](http://debian.org) builds using `debootstrap` as engine
 - `mock`─`rpm` spec file build using `mock` as engine
 - `collax`─[debian](http://debian.org)package variation
 - `fissile`─`docker` images based on `BOSH` dev releases
 - `helm`─`helm` charts


Use the `--help` option for more information.

