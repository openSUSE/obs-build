#!/usr/bin/perl -w

################################################################
#
# Copyright (c) 1995-2014 SUSE Linux Products GmbH
#
# This program is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License version 2 or 3 as
# published by the Free Software Foundation.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program (see the file COPYING); if not, write to the
# Free Software Foundation, Inc.,
# 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301, USA
#
################################################################

use strict;
use Test::More tests => 19;

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
EOR

my $config = setuptest($repo);
my @r;

@r = expand($config, "()");
is_deeply(\@r, [undef, 'cannot parse rich dependency ()'], 'install ()');

@r = expand($config, "(n and )");
is_deeply(\@r, [undef, 'cannot parse rich dependency (n and )'], 'install (n and )');

@r = expand($config, "(n foo m)");
is_deeply(\@r, [undef, 'cannot parse rich dependency (n foo m)'], 'install (n foo m)');

@r = expand($config, "n");
is_deeply(\@r, [undef, 'nothing provides n'], 'install n');

@r = expand($config, "(n)");
is_deeply(\@r, [undef, 'nothing provides n'], 'install (n)');

@r = expand($config, "(n or o)");
is_deeply(\@r, [undef, 'nothing provides (n or o)'], 'install (n or o)');

@r = expand($config, "(n and o)");
is_deeply(\@r, [undef, 'nothing provides (n and o)'], 'install (n and o)');

@r = expand($config, "n1");
is_deeply(\@r, [undef, "nothing provides n needed by n1"], "install n1");

@r = expand($config, "(n2 and d)");
is_deeply(\@r, [undef, '(provider d is conflicted by installed n2)', "conflict for providers of (n2 and d)"], "install (n2 and d)");

@r = expand($config, "(n2 or d)");
is_deeply(\@r, [undef, "have choice for (n2 or d): d n2"], "install (n2 or d)");

@r = expand($config, "a");
is_deeply(\@r, [1, qw{a b c d}], "install a");

@r = expand($config, 'i', 'j');
is_deeply(\@r, [undef, '(provider k conflicts with installed i)', '(provider k conflicts with installed j)', "conflict for providers of k needed by j"], "install i j");

# test corner cases
@r = expand($config, "(b if b)");
is_deeply(\@r, [1], 'install (b if b)');

@r = expand($config, "(n if n)");
is_deeply(\@r, [1], 'install (n if n)');

@r = expand($config, "lr");
is_deeply(\@r, [1, 'lr'], 'install lr');

@r = expand($config, "lc1");
is_deeply(\@r, [undef, '(provider b is conflicted by installed lc1)', 'conflict for providers of (b if b) needed by lc1'], 'install lc1');

@r = expand($config, "lc2");
is_deeply(\@r, [undef, 'lc2 conflicts with everything'], 'install lc2');

@r = expand($config, "m");
is_deeply(\@r, [1, 'm'], 'install m');

# complex config from the job
@r = expand($config, 'b', 'c', 'd', '!(b and c and d)');
is_deeply(\@r, [undef, 'd is conflicted'], 'install b c d !(b and c and d)');
