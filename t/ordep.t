#!/usr/bin/perl -w

################################################################
#
# Copyright (c) 2017 SUSE Linux Products GmbH
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
