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

package PBuild::LocalRepo;

use strict;

use PBuild::Verify;
use PBuild::Util;
use PBuild::BuildResult;
use PBuild::ExportFilter;

my @binsufs = qw{rpm deb pkg.tar.gz pkg.tar.xz pkg.tar.zst};
my $binsufsre = join('|', map {"\Q$_\E"} @binsufs);
my $binsufsre_binlnk = join('|', map {"\Q$_\E"} (@binsufs, 'obsbinlnk'));

#
# Collect all build artifact information of the packages into a single
# global datastructure and store it in .pbuild/_bininfo
#
sub read_gbininfo {
  my ($builddir, $pkgs) = @_;

  my $old_gbininfo = PBuild::Util::retrieve("$builddir/.pbuild/_bininfo", 1);
  my $gbininfo = {};
  for my $pkg (@$pkgs) {
    next unless -d "$builddir/$pkg";
    if ($old_gbininfo->{$pkg} && $old_gbininfo->{$pkg}->{'id'}) {
      my @s = stat("$builddir/$pkg/.bininfo");
      if (@s && "$s[9]/$s[7]/$s[1]" eq $old_gbininfo->{$pkg}->{'id'}) {
	$gbininfo->{$pkg} = $old_gbininfo->{$pkg};
	next;
      }
    }
    $gbininfo->{$pkg} = PBuild::BuildResult::read_bininfo("$builddir/$pkg", 1);
  }
  PBuild::Util::mkdir_p("$builddir/.pbuild");
  PBuild::Util::store("$builddir/.pbuild/._bininfo.$$", "$builddir/.pbuild/_bininfo", $gbininfo);
  return $gbininfo;
}

#
# Update the global build artifact data with the result of a new succeeded
# build
#
sub update_gbininfo {
  my ($builddir, $pkg, $bininfo) = @_;
  my $gbininfo = PBuild::Util::retrieve("$builddir/.pbuild/_bininfo");
  if (defined($bininfo)) {
    $gbininfo->{$pkg} = $bininfo;
  } else {
    delete $gbininfo->{$pkg};
  }
  PBuild::Util::store("$builddir/.pbuild/._bininfo.$$", "$builddir/.pbuild/_bininfo", $gbininfo);
}

sub orderpackids {
  my ($pkgs) = @_;
  return sort @$pkgs;
}

sub set_suf_and_filter_exports {
  my ($arch, $bininfo, $filter) = @_;
  my %n;

  for my $rp (sort keys %$bininfo) {
    my $r = $bininfo->{$rp};
    delete $r->{'suf'};
    next unless $r->{'source'};         # no src in full tree
    next unless $r->{'name'};           # need binary name
    my $suf;
    $suf = $1 if $rp =~ /\.($binsufsre_binlnk)$/;
    next unless $suf;                   # need a valid suffix
    $r->{'suf'} = $suf;
    my $nn = $rp;
    $nn =~ s/.*\///;
    if ($filter) {
      my $skip;
      for (@$filter) {
        if ($nn =~ /$_->[0]/) {
          $skip = $_->[1];
          last;
        }
      }
      if ($skip) {
        my $myself;
        for my $exportarch (@$skip) {
          if ($exportarch eq '.' || $exportarch eq $arch) {
            $myself = 1;
            next;
          }
        }
        next unless $myself;
      }
    }
    $n{$nn} = $r;
  }
  return %n;
}

#
# Calculate the binaries that are to be used in subsequent builds from
# the global build artifact information
#
sub gbininfo2full {
  my ($gbininfo, $arch, $useforbuild, $filter) = @_;
  my @packids = orderpackids([ keys %$gbininfo ]);

  # construct new full
  my %full;
  for my $packid (@packids) {
    next unless $useforbuild->{$packid};
    my $bininfo = $gbininfo->{$packid};
    next if $bininfo->{'.nouseforbuild'};               # channels/patchinfos don't go into the full tree
    my %f = set_suf_and_filter_exports($arch, $bininfo, $filter);
    for my $fn (sort { ($f{$a}->{'imported'} || 0) <=> ($f{$b}->{'imported'} || 0) || $a cmp $b} keys %f) {
      my $r = $f{$fn};
      $r->{'packid'} = $packid;
      $r->{'filename'} = $fn;
      $r->{'location'} = "$packid/$fn";
      my $or = $full{$r->{'name'}};
      $full{$r->{'name'}} = $r if $or && $or->{'packid'} eq $packid && volatile_cmp($r, $or);
      $full{$r->{'name'}} ||= $r;               # first one wins
    }
  }
  return %full;
}

#
# get metadata of build artifacts that are to be used in subsequent builds
#
sub fetchrepo {
  my ($bconf, $arch, $builddir, $pkgsrc) = @_;
  my @pkgs = sort keys %$pkgsrc;
  my $gbininfo = read_gbininfo($builddir, \@pkgs);
  my $filter = PBuild::ExportFilter::calculate_exportfilter($bconf, $arch);
  my $useforbuild = { map {$_ => $pkgsrc->{$_}->{'useforbuildenabled'}} @pkgs };
  my %full = gbininfo2full($gbininfo, $arch, $useforbuild, $filter);
  my $bins = [ sort { $a->{'name'} cmp $b->{'name'} } values %full ];
  my $repofile = "$builddir/.pbuild/_metadata";
  PBuild::Util::store("$builddir/.pbuild/._metadata.$$", $repofile, $bins);
  return $bins;
}

1;
