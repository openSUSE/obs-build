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

package Build::Repo;

use strict;

our $do_rpmmd;
our $do_deb;
our $do_arch;
our $do_archsrcinfo;
our $do_susetags;
our $do_mdk;
our $do_apk;

sub import {
  for (@_) {
    $do_rpmmd = 1 if $_ eq ':rpmmd';
    $do_deb = 1 if $_ eq ':deb';
    $do_archsrcinfo = 1 if $_ eq ':archsrcinfo';
    $do_arch = 1 if $_ eq ':arch';
    $do_susetags = 1 if $_ eq ':susetags';
    $do_mdk = 1 if $_ eq ':mdk';
    $do_apk = 1 if $_ eq ':apk';
  }
  $do_rpmmd = $do_deb = $do_arch = $do_archsrcinfo = $do_susetags = $do_mdk = $do_apk = 1 unless $do_rpmmd || $do_deb || $do_arch || $do_susetags || $do_mdk || $do_apk;
  if ($do_rpmmd) {
    require Build::Rpmmd;
  }
  if ($do_susetags) {
    require Build::Susetags;
  }
  if ($do_deb) {
    require Build::Debrepo;
  }
  if ($do_arch) {
    require Build::Archrepo;
  }
  if ($do_archsrcinfo) {
    require Build::Archrepo;
  }
  if ($do_mdk) {
    require Build::Mdkrepo;
  }
  if ($do_apk) {
    require Build::Apkrepo;
  }
}

sub parse {
  my ($type, @args) = @_;
  return Build::Rpmmd::parse(@args) if $do_rpmmd && $type eq 'rpmmd';
  return Build::Susetags::parse(@args) if $do_susetags && $type eq 'susetags';
  return Build::Debrepo::parse(@args) if $do_deb && $type eq 'deb';
  return Build::Archrepo::parse(@args) if $do_archsrcinfo && $type eq 'archsrcinfo';
  return Build::Archrepo::parse(@args) if $do_arch && $type eq 'arch';
  return Build::Mdkrepo::parse(@args) if $do_arch && $type eq 'mdk';
  return Build::Apkrepo::parse(@args) if $do_apk && $type eq 'apk';
  die("parse repo: unknown type '$type'\n");
}

1;
