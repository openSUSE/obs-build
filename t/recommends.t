#!/usr/bin/perl -w

use strict;
use Test::More tests => 5;

require 't/testlib.pm';

my $repo = <<'EOR';
P: a = 1-1
r: b
P: a1 = 1-1
r: p
P: a2 = 1-1
r: (b or c)
P: a3 = 1-1
r: (b if c)
P: b = 1-1 p
P: c = 1-1 p
EOR

my $config = setuptest($repo, "Expandflags: dorecommends");
my @r;

@r = expand($config, 'a');
is_deeply(\@r, [1, 'a', 'b'], 'install a');

@r = expand($config, 'a1');
is_deeply(\@r, [undef, 'have choice for p needed by a1: b c'], 'install a1');

@r = expand($config, 'a2');
is_deeply(\@r, [undef, 'have choice for (b or c) needed by a2: b c'], 'install a2');

@r = expand($config, 'a3');
is_deeply(\@r, [1, 'a3'], 'install a3');

@r = expand($config, 'a3', 'c');
is_deeply(\@r, [1, 'a3', 'b', 'c'], 'install a3 c');
