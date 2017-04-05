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
use Test::More tests => 12;

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
is_deeply(\@r, [undef, 'nothing provides n', 'nothing provides o'], 'install (n or o)');

@r = expand($config, "(n and o)");
is_deeply(\@r, [undef, 'nothing provides n', 'nothing provides o'], 'install (n and o)');

@r = expand($config, "n1");
is_deeply(\@r, [undef, "nothing provides n needed by n1"], "install n1");

@r = expand($config, "(n2 and d)");
is_deeply(\@r, [undef, '(provider d conflicts with installed n2)', "conflict for providers of (n2 and d)"], "install (n2 and d)");

@r = expand($config, "(n2 or d)");
is_deeply(\@r, [undef, "have choice for (n2 or d): d n2"], "install (n2 or d)");

@r = expand($config, "a");
is_deeply(\@r, [1, qw{a b c d}], "install a");

@r = expand($config, 'i', 'j');
is_deeply(\@r, [undef, '(provider k conflicts with installed i and j)', "conflict for providers of k needed by j"], "install i j");
