#!/usr/bin/perl -w

use strict;
use Test::More tests => 4;

require 't/testlib.pm';

my $repo = <<'EOR';
P: a = 1-1
R: p
P: b = 1-1 p
P: c = 1-1 p
P: d = 1-1
r: b
P: e = 1-1
r: c
EOR

my $config = setuptest($repo);
my @r;

@r = expand($config, 'a');
is_deeply(\@r, [undef, 'have choice for p needed by a: b c'], 'install a');

@r = expand($config, 'a', 'd');
is_deeply(\@r, [1, 'a', 'b', 'd'], 'install a d');

@r = expand($config, 'a', 'e');
is_deeply(\@r, [1, 'a', 'c', 'e'], 'install a e');

@r = expand($config, 'a', 'd', 'e');
is_deeply(\@r, [undef, 'have choice for p needed by a: b c'], 'install a d e');
