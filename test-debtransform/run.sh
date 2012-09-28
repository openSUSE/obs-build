#!/bin/bash

function run
{
    rm -rf out
    mkdir out
    ERROR=0
    PATH=..:$PATH ../debtransform $1 $1/$2 out || ERROR=1
    if [ "$ERROR" != "$3" ]; then
	echo "$1: FAIL"
	exit 1
    fi
    echo "$1: OK"
}

run 1 grandorgue.dsc 0
run 2 grandorgue.dsc 0