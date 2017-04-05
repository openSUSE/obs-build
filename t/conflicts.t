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
use Test::More tests => 7;

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
EOR

my $config = setuptest($repo);
my @r;

@r = expand($config, 'a');
is_deeply(\@r, [undef, 'have choice for p needed by a: b c'], 'install a');

@r = expand($config, 'a', 'd');
is_deeply(\@r, [1, 'a', 'c', 'd'], 'install a d');

@r = expand($config, 'a', 'e');
is_deeply(\@r, [1, 'a', 'b', 'e'], 'install a e');

@r = expand($config, 'a', 'd', 'e');
is_deeply(\@r, [undef, '(provider b is conflicted by installed d)', '(provider c is conflicted by installed e)', 'conflict for providers of p needed by a'], 'install a d e');

@r = expand($config, 'a', 'f');
is_deeply(\@r, [undef, '(provider b is conflicted by installed f)', '(provider c is conflicted by installed f)', 'conflict for providers of p needed by a'], 'install a f');

@r = expand($config, 'b', 'f');
is_deeply(\@r, [undef, '(provider f conflicts with installed b)', 'conflict for package f'], 'install b f');

@r = expand($config, 'b', 'h');
is_deeply(\@r, [undef, '(provider f conflicts with installed b)', 'conflict for providers of f needed by h'], 'install b h');
