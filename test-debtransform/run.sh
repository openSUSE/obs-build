#!/bin/bash

function fail
{
    echo "$1: FAIL"
    exit 1
}
function run
{
    rm -rf out
    mkdir out
    ERROR=0
    PATH=..:$PATH ../debtransform $1 $1/$2 out || ERROR=1
    if [ "$ERROR" != "$3" ]; then
	fail $1
    fi
    echo "$1: OK"
    if [ "$ERROR" = 0 ]; then
	for a in out/*
	do
	    NAME="`basename "$a"`"
	    case $NAME in
		*.dsc)
		    debdiff $4/$NAME out/$NAME
		    RES=$?
		    if (( $RES != 0 )); then
			    fail $RES
		    fi
		    ;;
	    esac
	done
    fi
}

export SOURCE_DATE_EPOCH=1591490034

run 1 grandorgue.dsc 0 1-out
run 2 grandorgue.dsc 0 2-out
