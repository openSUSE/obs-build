#!/bin/bash -e

failed=0
num=0

cleanup_and_exit() {
	shift
	echo "not ok $num - $s: $*"
	exit 1
}

. ${0%/*}/../build-recipe-spec

_assert() {
	local s="$1"
	spec_setup_stages "$s"
	shift
	if test "$#" != "${#rpmstages[@]}"; then
		echo "not ok $num - $s: '$*' != '${rpmstages[*]}'"
		((++failed))
		return
	fi
	local i=0
	while test -n "$1"; do
		if test "$1" != "${rpmstages[i]}"; then
			echo "not ok $num - $s: '$1' != '${rpmstages[i]}'"
			((++failed))
			return
		fi
		shift
		((++i))
	done
	echo "ok $num - $s => ${rpmstages[*]}"
}

assert() {
	((++num))
	(_assert "$@") || { ((++failed)); }
}

echo 1..20

assert a -ba
assert a= -bs
assert a+ -bs
assert b -bb
assert b= "-bb --short-circuit"
assert b+ "-bb --short-circuit" "-bs"
assert i -bi
assert i= "-bi --short-circuit"
assert i+ "-bi --short-circuit" "-bb --short-circuit" "-bs"
assert c -bc
assert c= "-bc --short-circuit"
assert c+ "-bc --short-circuit" "-bi --short-circuit" "-bb --short-circuit" "-bs"
assert p -bp
assert p= -bp
assert p+ -ba

assert l -bl
assert r -br
assert s -bs
assert s= -bs
assert s+ -bs

exit 0

# vim: syntax=bash
