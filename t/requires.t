#!/usr/bin/perl -w

use strict;
use Test::More tests => 16;

require 't/testlib.pm';

my $repo = <<'EOR';
P: a = 1-1
R: b
P: b = 1-1
P: c = 1-1
R: p
P: d = 1-1 p
P: e = 1-1 p
P: f = 1-1
R: n
P: ign2 = 1-1
R: ign1
P: ign3 = 1-1
R: ign4
P: ign5 = 1-1 ign4
P: ign6 = 1-1
R: ign7
P: ign8 = 1-1
R: ign7
P: g = 1-1 h
P: h = 1-1
EOR

my $config = setuptest($repo, 'Ignore: ign1 ign5 ign6:ign7');
my $config2 = setuptest($repo, 'Prefer: d');
my $config3 = setuptest($repo, 'Prefer: -d');
my @r;

@r = expand($config);
is_deeply(\@r, [1], 'install nothing');

@r = expand($config, 'n');
is_deeply(\@r, [undef, 'nothing provides n'], 'install n');

@r = expand($config, 'f');
is_deeply(\@r, [undef, 'nothing provides n needed by f'], 'install f');

@r = expand($config, "a");
is_deeply(\@r, [1, 'a', 'b'], 'install a');

@r = expand($config, "c");
is_deeply(\@r, [undef, 'have choice for p needed by c: d e'], 'install c');

@r = expand($config2, "c");
is_deeply(\@r, [1, 'c', 'd'], 'install c with prefer');

@r = expand($config3, "c");
is_deeply(\@r, [1, 'c', 'e'], 'install c with neg prefer');

@r = expand($config, "ign1");
is_deeply(\@r, [undef, 'nothing provides ign1'], 'install ign1');

@r = expand($config, "ign2");
is_deeply(\@r, [1, 'ign2'], 'install ign2');

@r = expand($config, "ign3");
is_deeply(\@r, [1, 'ign3'], 'install ign3');

@r = expand($config, "ign6");
is_deeply(\@r, [1, 'ign6'], 'install ign6');

@r = expand($config, "ign8");
is_deeply(\@r, [undef, 'nothing provides ign7 needed by ign8'], 'install ign8');

@r = expand($config, "ign2", "-ign2");
is_deeply(\@r, [1, 'ign2'], 'install ign2 -ign2');

@r = expand($config, "ign8", "-ign7");
is_deeply(\@r, [1, 'ign8'], 'install ign8 -ign7');

@r = expand($config, "h");
is_deeply(\@r, [1, 'h'], 'install h');

@r = expand($config, "--directdepsend--", "h");
is_deeply(\@r, [undef, 'have choice for h: g h'], 'install --directdepsend-- h');

