#!/usr/bin/perl -w

use strict;
use Test::More tests => 15;

require 't/testlib.pm';

my $repo = <<'EOR';
P: a = 1-1
R: p
P: b = 1-1 p
P: c = 1-1 p
P: d = 1-1
C: b
P: e = 1-1
C: c
P: f = 1-1
C: p
P: g = 1-1
C: b c
P: h = 1-1
R: f
P: i = 1-1
P: j = 1-1
P: k = 1-1
R: j
P: l = 1-1
R: b d
P: m = 1-1
C: m
P: x = 1-1
P: y = 1-1
R: x
EOR

my $config = setuptest($repo, "Conflict: i:j\nConflict: x");
my @r;

# test that conflicts can fix choices
@r = expand($config, 'a');
is_deeply(\@r, [undef, 'have choice for p needed by a: b c'], 'install a');

@r = expand($config, 'a', 'd');
is_deeply(\@r, [1, 'a', 'c', 'd'], 'install a d');

@r = expand($config, 'a', 'e');
is_deeply(\@r, [1, 'a', 'b', 'e'], 'install a e');

# test test conflicting all providers works
@r = expand($config, 'a', 'd', 'e');
is_deeply(\@r, [undef, '(provider b is in conflict with d)', '(provider c is in conflict with e)', 'conflict for providers of p needed by a'], 'install a d e');

@r = expand($config, 'a', 'f');
is_deeply(\@r, [undef, '(provider b is in conflict with f)', '(provider c is in conflict with f)', 'conflict for providers of p needed by a'], 'install a f');

# test that conflicting jobs work
@r = expand($config, 'b', 'f');
is_deeply(\@r, [undef, 'f conflicts with b'], 'install b f');

@r = expand($config, 'b', 'h');
is_deeply(\@r, [undef, '(provider f conflicts with b)', 'conflict for providers of f needed by h'], 'install b h');

# test conflicts specified in the job
@r = expand($config, 'i', '!i');
is_deeply(\@r, [undef, 'i is in conflict'], 'install i !i');

@r = expand($config, 'k', '!j');
is_deeply(\@r, [undef, '(provider j is in conflict)', 'conflict for providers of j needed by k'], 'install k !j');

# test conflicts from project config
@r = expand($config, 'i', 'j');
is_deeply(\@r, [undef, 'i conflicts with j', 'j conflicts with i'], 'install i j');

@r = expand($config, 'i', 'k');
is_deeply(\@r, [undef, '(provider j is in conflict with i)', 'conflict for providers of j needed by k'], 'install i k');

@r = expand($config, 'l');
is_deeply(\@r, [undef, 'd conflicts with b'], 'install l');

@r = expand($config, 'm');
is_deeply(\@r, [1, 'm'], 'install m');

@r = expand($config, 'x');
is_deeply(\@r, [undef, 'x is in conflict'], 'install x');

@r = expand($config, 'y');
is_deeply(\@r, [undef, '(provider x is in conflict)', 'conflict for providers of x needed by y'], 'install y');
