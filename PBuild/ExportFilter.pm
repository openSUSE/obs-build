################################################################
#
# Copyright (c) 2021 SUSE LLC
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

package PBuild::ExportFilter;

use strict;

use PBuild::Verify;

my %default_exportfilters = (
  'i586' => {
    '\.x86_64\.rpm$'   => [ 'x86_64' ],
    '\.ia64\.rpm$'     => [ 'ia64' ],
    '-debuginfo-.*\.rpm$' => [],
    '-debugsource-.*\.rpm$' => [],
  },
  'x86_64' => {
    '-debuginfo-.*\.rpm$' => [],
    '-debugsource-.*\.rpm$' => [],
  },
  'ppc' => {
    '\.ppc64\.rpm$'   => [ 'ppc64' ],
    '-debuginfo-.*\.rpm$' => [],
    '-debugsource-.*\.rpm$' => [],
  },
  'ppc64' => {
    '\.ppc\.rpm$'   => [ 'ppc' ],
    '-debuginfo-.*\.rpm$' => [],
    '-debugsource-.*\.rpm$' => [],
  },
  'sparc' => {
    # discard is intended - sparcv9 target is better suited for 64-bit baselibs
    '\.sparc64\.rpm$' => [],
    '-debuginfo-.*\.rpm$' => [],
    '-debugsource-.*\.rpm$' => [],
  },
  'sparcv8' => {
    # discard is intended - sparcv9 target is better suited for 64-bit baselibs
    '\.sparc64\.rpm$' => [],
    '-debuginfo-.*\.rpm$' => [],
    '-debugsource-.*\.rpm$' => [],
  },
  'sparcv9' => {
    '\.sparc64\.rpm$' => [ 'sparc64' ],
    '-debuginfo-.*\.rpm$' => [],
    '-debugsource-.*\.rpm$' => [],
  },
  'sparcv9v' => {
    '\.sparc64v\.rpm$' => [ 'sparc64v' ],
    '-debuginfo-.*\.rpm$' => [],
    '-debugsource-.*\.rpm$' => [],
  },
  'sparc64' => {
    '\.sparcv9\.rpm$' => [ 'sparcv9' ],
    '-debuginfo-.*\.rpm$' => [],
    '-debugsource-.*\.rpm$' => [],
  },
  'sparc64v' => {
    '\.sparcv9v\.rpm$' => [ 'sparcv9v' ],
    '-debuginfo-.*\.rpm$' => [],
    '-debugsource-.*\.rpm$' => [],
  },
);

sub compile_exportfilter {
  my ($filter) = @_;
  return undef unless $filter;
  my @res;
  for my $f (@$filter) {
    eval {
      $_ eq '.' || PBuild::Verify::verify_arch($_) for @{$f->[1] || []};
      push @res, [ qr/$f->[0]/, $f->[1] ];
    };
  }
  return \@res;
}

sub calculate_exportfilter {
  my ($bconf, $arch) = @_;
  my $filter = $bconf->{'exportfilter'};
  undef $filter if $filter && !%$filter;
  $arch = 'i586' if $arch eq 'i686';
  $filter ||= $default_exportfilters{$arch};
  $filter = [ map {[$_, $filter->{$_}]} reverse sort keys %$filter ] if $filter;
  return compile_exportfilter($filter);
}

1;
