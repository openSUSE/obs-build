################################################################
#
# Copyright (c) 2020 SUSE LLC
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

package Build::Intrepo;

use strict;
use Build::Rpm;

# This implements reading and writing of build's internal repo format.
# 
# The format looks like this:
#
# P:bash.x86_64-1526160002/1526160023/0: bash = 4.4-lp150.7.8
#
# i.e.: type:name.arch-mtime/size/inode: dep dep dep
#
# P:provides C:conflicts R:requires O:Obsoletes
# r:recommends s:supplements
#
# There is also:
# F:...: filename
# I:...: ident  where ident == name-evr buildtime-arch
#
# The format is so weird because init_buildsystem of the old autobuild
# system used to create such repos by doing a single 'rpm --qf' call.
#

sub addpkg {
  my ($res, $pkg, $pkgid, $options) = @_;

  return unless $pkgid =~ /^(.*)\.(.*)-\d+\/\d+\/\d+$/s;
  $pkg->{'name'} = $1;
  $pkg->{'arch'} = $2 unless $pkg->{'arch'};
  # extract evr from self provides if there was no 'I' line
  if (!defined($pkg->{'version'})) {
    my @sp = grep {/^\Q$pkg->{'name'}\E\s*=\s*/} @{$pkg->{'provides'} || []};
    if (@sp) {
      my $evr = $sp[-1];
      $evr =~ s/^\Q$pkg->{'name'}\E\s*=\s*//;
      $pkg->{'epoch'} = $1 if $evr =~ s/^(\d+)://;
      $pkg->{'release'} = $1 if $evr =~ s/-([^-]*)$//;
      $pkg->{'version'} = $evr;
    }
  }
  if (ref($res) eq 'CODE') {
    $res->($pkg);
  } else {
    push @$res, $pkg;
  }
}

sub parse {
  my ($in, $res, %options) = @_;

  my $nofiledeps = $options{'nofiledeps'};
  my $testcaseformat = $options{'testcaseformat'};
  if (ref($in)) {
    *F = $in;
  } else {
    open(F, '<', $in) || die("$in: $!\n");
  }
  $res ||= [];

  my $lastpkgid;
  my $pkg = {};
  while (<F>) {
    my @s = split(' ', $_);
    my $s = shift @s;
    next unless $s && $s =~ /^([a-zA-Z]):(.+):$/s;
    my ($tag, $pkgid) = ($1, $2);
    
    if ($lastpkgid && $pkgid ne $lastpkgid) {
      addpkg($res, $pkg, $lastpkgid, \%options) if %$pkg;
      $pkg = {};
    }
    $lastpkgid = $pkgid;

    if ($tag eq 'I') {
      next unless $pkgid =~ /^(.*)\.(.*)-\d+\/\d+\/\d+:$/;
      my $name = $1;
      my $evr = $s[0];
      $pkg->{'arch'} = $1 if $s[1] && $s[1] =~ s/-(.*)$//;
      $pkg->{'buildtime'} = $s[1] if $s[1];
      if ($evr =~ s/^\Q$name\E-//) {
	$pkg->{'epoch'} = $1 if $evr =~ s/^(\d+)://;
	$pkg->{'release'} = $1 if $evr =~ s/-([^-]*)$//;
	$pkg->{'version'} = $evr;
      }
      next;
    }
    if ($tag eq 'F') {
      chomp;
      my $loc = (split(' ', $_, 2))[1];
      $pkg->{'location'} = $loc if defined $loc;
      next;
    }
    my @ss;
    while (@s) {
      if ($nofiledeps && $s[0] =~ /^\//) {
	shift @s;
	next;
      }
      if ($s[0] =~ /^rpmlib\(/) {
	splice(@s, 0, 3);
	next;
      }
      if ($s[0] =~ /^\(/) {
	push @ss, Build::Rpm::shiftrich(\@s);
	$ss[-1] = Build::Rpm::testcaseformat($ss[-1]) if $testcaseformat;
	next;
      }
      push @ss, shift @s;
      while (@s && $s[0] =~ /^[\(<=>|]/) {
	$ss[-1] .= " $s[0] $s[1]";
	$ss[-1] =~ s/ \((.*)\)/ $1/;
	$ss[-1] =~ s/(<|>){2}/$1/;
	splice(@s, 0, 2);
      }
    }
    my %ss;
    @ss = grep {!$ss{$_}++} @ss;	# unify
    $pkg->{'provides'} = \@ss if $tag eq 'P';
    $pkg->{'requires'} = \@ss if $tag eq 'R';
    $pkg->{'conflicts'} = \@ss if $tag eq 'C';
    $pkg->{'obsoletes'} = \@ss if $tag eq 'O';
    $pkg->{'recommends'} = \@ss if $tag eq 'r';
    $pkg->{'supplements'} = \@ss if $tag eq 's';
  }
  addpkg($res, $pkg, $lastpkgid, \%options) if $lastpkgid && %$pkg;
  close F unless ref($in);
  return $res;
}

sub getbuildid {
  my ($q) = @_;
  my $evr = $q->{'version'};
  $evr = "$q->{'epoch'}:$evr" if $q->{'epoch'};
  $evr .= "-$q->{'release'}" if defined $q->{'release'};
  my $buildtime = $q->{'buildtime'} || 0;
  $buildtime .= "-$q->{'arch'}" if defined $q->{'arch'};
  return "$q->{'name'}-$evr $buildtime";
}

my $writepkg_inode = 0;

sub writepkg {
  my ($fh, $pkg, $locprefix, $inode) = @_;
  return unless defined($pkg->{'name'}) && defined($pkg->{'arch'});
  return if $pkg->{'arch'} eq 'src' || $pkg->{'arch'} eq 'nosrc';
  $locprefix = '' unless defined $locprefix;
  my $id = $pkg->{'id'};
  if (!$id) {
    $inode = $writepkg_inode++ unless defined $inode;
    $id = ($pkg->{'buildtime'} || 0)."/".($pkg->{'filetime'} || 0)."/$inode";
  }
  $id = "$pkg->{'name'}.$pkg->{'arch'}-$id: ";
  print $fh "F:$id$locprefix$pkg->{'location'}\n";
  print $fh "P:$id".join(' ', @{$pkg->{'provides'} || []})."\n";
  print $fh "R:$id".join(' ', @{$pkg->{'requires'}})."\n" if $pkg->{'requires'};
  print $fh "C:$id".join(' ', @{$pkg->{'conflicts'}})."\n" if $pkg->{'conflicts'};
  print $fh "O:$id".join(' ', @{$pkg->{'obsoletes'}})."\n" if $pkg->{'obsoletes'};
  print $fh "r:$id".join(' ', @{$pkg->{'recommends'}})."\n" if $pkg->{'recommends'};
  print $fh "s:$id".join(' ', @{$pkg->{'supplements'}})."\n" if $pkg->{'supplements'};
  print $fh "I:$id".getbuildid($pkg)."\n";
}

1;
