#!/usr/bin/perl -w

use strict;
use Test::More tests => 1;

system("./changelog2spec --selftest");
is($?, 0, "changelog2spec selftest")
