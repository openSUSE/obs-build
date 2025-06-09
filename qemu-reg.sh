#!/bin/bash
# sync qemu-reg file with installed binfmnt handlers
# ./qemu-reg.sh > qemu-reg.new
binfmntdir="${1:-/usr/lib/binfmt.d}"
while read -r line; do
  if [ "${line:0:1}" != : ]; then
    echo "$line"
    continue
  fi
  set -- $line
  reg="$1"
  blacklist="${@:2}"
  IFS=: eval set -- "\$1"
  if [ -e "$binfmntdir/$2.conf" ]; then
    read -r reg < "$binfmntdir/$2.conf"
  fi
  echo "$reg $blacklist"
done < qemu-reg
