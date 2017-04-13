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
