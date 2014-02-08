#!/bin/bash
#
# This is the generic test case for the current distribution, it
# is to be called from the spec file while building a build.rpm

. ${0%/*}/common
REPO="$1"
shift
DISTRO="$1"
shift
ARCH="$1"
shift

if [ -z "$REPO" ]; then
  echo "No local path to binary packages is given as argument"
  exit 1
fi
if [ -z "$DISTRO" ]; then
  echo "No distribution is given as argument ( eg '13.1' or 'fedora11' )"
  exit 1
fi
if [ -z "$ARCH" ]; then
  echo "No architecture is given as argument ( eg 'i386' or 'x86_64' )"
  exit 1
fi

[ "$ARCH" == "i386" ] && arch32bit

repo "$REPO"

run_build --dist "${DISTRO}-${ARCH}" \
	"$@"
