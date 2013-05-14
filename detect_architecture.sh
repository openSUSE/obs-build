#!/bin/bash

arch=`uname -m`

case "$arch" in
	i686) arch="i586";;
esac

echo $arch

