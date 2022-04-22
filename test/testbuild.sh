#!/bin/bash
#
# This is the generic test case for the current distribution, it
# is to be called from the spec file while building a build.rpm

. ${0%/*}/common
REPO="$1"
shift

if [ -z "$REPO" ]; then
  echo "No local path to binary packages is given as argument"
  exit 1
fi

[ "$ARCH" == "i386" ] && arch32bit

repo "$REPO"

run_build --dist default "$@"
