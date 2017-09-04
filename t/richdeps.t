#!/usr/bin/perl -w

use strict;
use Test::More tests => 37;

require 't/testlib.pm';

my $repo = <<'EOR';
P: a = 1-1
R: (b if c) d
P: b = 1-1
P: c = 1-1
P: d = 1-1
R: c
P: n1 = 1-1
R: n
P: n2 = 1-1
C: d
P: i = 1-1
P: j = 1-1
R: k
P: k = 1-1
C: (i and j)
P: lr = 1-1
R: (b if b)
P: lc1 = 1-1
C: (b if b)
P: lc2 = 1-1
C: (n if n)
P: m = 1-1
C: (b and (n if b))
P: cx = 1-1
C: (b and cx and d)
P: ign1 = 1-1
R: (ign and b)
P: ign2 = 1-1
R: (ign or b)
P: ign3 = 1-1
R: (b if ign)
P: ign4 = 1-1
R: (ign if b)
P: bad1 = 1-1
R: (n foo m)
P: bad2 = 1-1
C: (n foo m)
P: sc = 1-1
C: (a or sc) (n or sc)
P: ifelse = 1-1
R: (b if i else c)
P: unless = 1-1
C: (b unless i)
P: unlesselse = 1-1
C: (b unless i else c)
EOR

my $config = setuptest($repo, 'Ignore: ign');
my @r;

@r = expand($config, "()");
is_deeply(\@r, [undef, 'cannot parse dependency ()'], 'install ()');

@r = expand($config, "(n and )");
is_deeply(\@r, [undef, 'cannot parse dependency (n and )'], 'install (n and )');

@r = expand($config, "(n foo m)");
is_deeply(\@r, [undef, 'cannot parse dependency (n foo m)'], 'install (n foo m)');

@r = expand($config, "n");
is_deeply(\@r, [undef, 'nothing provides n'], 'install n');

@r = expand($config, "(n or o)");
is_deeply(\@r, [undef, 'nothing provides (n or o)'], 'install (n or o)');

@r = expand($config, "(n and o)");
is_deeply(\@r, [undef, 'nothing provides (n and o)'], 'install (n and o)');

@r = expand($config, "n1");
is_deeply(\@r, [undef, "nothing provides n needed by n1"], "install n1");

@r = expand($config, "(n2 and d)");
is_deeply(\@r, [undef, 'n2 conflicts with d'], "install (n2 and d)");

@r = expand($config, "(n2 or d)");
is_deeply(\@r, [undef, "have choice for (n2 or d): d n2"], "install (n2 or d)");

@r = expand($config, "a");
is_deeply(\@r, [1, qw{a b c d}], "install a");

@r = expand($config, 'i', 'j');
is_deeply(\@r, [undef, '(provider k conflicts with i)', '(provider k conflicts with j)', "conflict for providers of k needed by j"], "install i j");

# test corner cases
@r = expand($config, "(b if b)");
is_deeply(\@r, [1], 'install (b if b)');

@r = expand($config, "(n if n)");
is_deeply(\@r, [1], 'install (n if n)');

@r = expand($config, "lr");
is_deeply(\@r, [1, 'lr'], 'install lr');

@r = expand($config, "lc1");
is_deeply(\@r, [undef, '(provider b is in conflict with lc1)', 'conflict for providers of (b if b) needed by lc1'], 'install lc1');

@r = expand($config, "lc2");
is_deeply(\@r, [undef, 'lc2 conflicts with always true (n if n)'], 'install lc2');

@r = expand($config, "m");
is_deeply(\@r, [1, 'm'], 'install m');

# complex config from the job
@r = expand($config, 'b', 'c', 'd', '!(b and c and d)');
is_deeply(\@r, [undef, 'conflicts with b', 'conflicts with c', 'conflicts with d'], 'install b c d !(b and c and d)');

@r = expand($config, '!(n if n)');
is_deeply(\@r, [undef, 'conflict with always true (n if n)'], 'install !(n if n)');

@r = expand($config, 'b', 'cx', 'd');
is_deeply(\@r, [undef, 'cx conflicts with b', 'cx conflicts with d'], 'install b cx d');

@r = expand($config, 'ign');
is_deeply(\@r, [undef, 'nothing provides ign'], 'install ign');

@r = expand($config, 'ign1');
is_deeply(\@r, [1, 'b', 'ign1'], 'install ign1');

@r = expand($config, 'ign2');
is_deeply(\@r, [1, 'ign2'], 'install ign2');

@r = expand($config, 'ign3');
is_deeply(\@r, [1, 'ign3'], 'install ign3');

@r = expand($config, 'b', 'ign4');
is_deeply(\@r, [1, 'b', 'ign4'], 'install b ign4');

@r = expand($config, '(ign and b)');
is_deeply(\@r, [undef, 'nothing provides (ign and b)'], 'install b');

@r = expand($config, 'bad1');
is_deeply(\@r, [undef, 'cannot parse dependency (n foo m) from bad1'], 'install bad1');

@r = expand($config, 'bad2');
is_deeply(\@r, [undef, 'cannot parse dependency (n foo m) from bad2'], 'install bad2');

@r = expand($config, 'sc', 'b');
is_deeply(\@r, [1, 'b', 'sc'], 'install sc b');

@r = expand($config, 'ifelse');
is_deeply(\@r, [undef, 'have choice for (b if i else c) needed by ifelse: c i'], 'install ifelse');

@r = expand($config, 'ifelse', 'i');
is_deeply(\@r, [1, 'b', 'i', 'ifelse'], 'install ifelse i');

@r = expand($config, 'ifelse', 'c');
is_deeply(\@r, [1, 'c', 'ifelse'], 'install ifelse c');

@r = expand($config, 'unless', 'b');
is_deeply(\@r, [1, 'b', 'i', 'unless'], 'install unless b');

@r = expand($config, 'unless', 'b', '!i');
is_deeply(\@r, [undef, '(provider i is in conflict)', 'conflict for providers of (b unless i) needed by unless'], 'install unless b !i');

@r = expand($config, 'unlesselse', 'b', 'c');
is_deeply(\@r, [undef, '(provider i is in conflict with unlesselse)', 'conflict for providers of (b unless i else c) needed by unlesselse'], 'install unlesselse b c');

@r = expand($config, 'unlesselse', 'b');
is_deeply(\@r, [1, 'b', 'i', 'unlesselse'], 'install unlesselse b');

@r = expand($config, 'unlesselse', 'c');
is_deeply(\@r, [1, 'c', 'unlesselse'], 'install unlesselse c');
