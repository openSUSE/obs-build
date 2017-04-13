#!/usr/bin/perl -w

use strict;
use Test::More tests => 1;

require 't/testlib.pm';

my $repo = <<'EOR';
P: a = 1-1
R: b c
P: b1 = 1-1 b
C: c1
P: b2 = 1-1 b
P: c1 = 1-1 c
P: c2 = 1-1 c
EOR

my $config = setuptest($repo, 'Prefer: b1 c1');
my @r;

@r = expand($config, 'a');
is_deeply(\@r, [undef, 'b1 conflicts with c1'], 'install a');
