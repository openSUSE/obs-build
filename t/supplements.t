#!/usr/bin/perl -w

use strict;
use Test::More tests => 6;

require 't/testlib.pm';

my $repo = <<'EOR';
P: a = 1-1
P: a1 = 1-1
P: b = 1-1 p
s: a a1
P: c = 1-1 p
C: b
s: a1
P: d = 1-1
C: c
P: e = 1-1
P: x = 1-1
R: y
P: y1 = 1-1 y
P: y2 = 1-1 y
s: e
P: f = 1-1
s: (a and d)
EOR

my $config = setuptest($repo, "Expandflags: dosupplements");
my @r;

@r = expand($config, 'a');
is_deeply(\@r, [1, 'a', 'b'], 'install a');

@r = expand($config, 'a1');
is_deeply(\@r, [undef, 'c conflicts with b'], 'install a1');

@r = expand($config, 'a1', 'd');
is_deeply(\@r, [1, 'a1', 'b', 'd'], 'install a1 d');

@r = expand($config, 'x');
is_deeply(\@r, [undef, 'have choice for y needed by x: y1 y2'], 'install x');

@r = expand($config, 'x', 'e');
is_deeply(\@r, [1, 'e', 'x', 'y2'], 'install x e');

@r = expand($config, 'a', 'd');
is_deeply(\@r, [1, 'a', 'b', 'd', 'f'], 'install a d');
