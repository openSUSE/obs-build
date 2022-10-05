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
			echo "Checking by debdiff that generated 'out/$NAME' is equaling to expected '$4/$NAME'"
		    debdiff $4/$NAME out/$NAME
		    RES=$?
		    if [ $RES != 0 ]; then
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
run 3 grandorgue.dsc 0 3-out
run 4 grandorgue.dsc 0 4-out
run 5 grandorgue.dsc 0 5-out
run 6 grandorgue.dsc 0 6-out

# check with absolute paths too
run "$(realpath 4)" grandorgue.dsc 0 "$(realpath 4-out)"
run "$(realpath 5)" grandorgue.dsc 0 "$(realpath 5-out)"
run "$(realpath 6)" grandorgue.dsc 0 "$(realpath 6-out)"
