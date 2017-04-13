#!/usr/bin/perl -w

use strict;
use Test::More tests => 4;

require 't/testlib.pm';

my $repo = <<'EOR';
P: a = 1-1
R: x | y
P: b = 1-1
R: d | e
P: c = 1-1
R: d | f
P: d = 1-1
P: e = 1-1
P: f = 1-1
P: g = 1-1
R: x | e | d
EOR

my $config = setuptest($repo, "Binarytype: deb\nPrefer: f\n");
my @r;

@r = expand($config, 'a');
is_deeply(\@r, [undef, 'nothing provides x | y needed by a'], 'install a');

@r = expand($config, 'b');
is_deeply(\@r, [1, 'b', 'd'], 'install b');

@r = expand($config, 'c');
is_deeply(\@r, [1, 'c', 'f'], 'install c');

@r = expand($config, 'g');
is_deeply(\@r, [1, 'e', 'g'], 'install g');
