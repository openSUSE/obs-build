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

package PBuild::Source;

use strict;
use Digest::MD5;

use PBuild::Util;

sub find_packages {
  my ($dir) = @_;
  my @pkgs;
  for my $pkg (sort(PBuild::Util::ls($dir))) {
    next if $pkg =~ /^[\._]/;
    next unless -d "$dir/$pkg";
    push @pkgs, $pkg;
  }
  return @pkgs;
}

sub gendigest {
  my ($fn) = @_;
  my $fd;
  open($fd, '<', $fn) || die("$fn: $!\n");
  my $ctx = Digest::MD5->new;
  $ctx->addfile($fd);
  close $fd;
  return $ctx->hexdigest();
}

sub genlnkdigest {
  my ($fn) = @_;
  my $lnk = readlink($fn);
  die("$fn: $!\n") unless defined $lnk;
  return Digest::MD5::md5_hex($lnk);
}

sub gendirdigest {
  my ($dir) = @_;
  my %files;
  for my $file (sort(PBuild::Util::ls($dir))) {
    my @s = lstat("$dir/$file");
    if (!@s) {
      warn("$dir: $!\n");
      next;
    }
    if (-l _) {
      $files{$file} = genlnkdigest("$dir/$file");
    } elsif (-d _) {
      $files{"$file/"} = gendirdigest("$dir/$file");
    } elsif (-f _) {
      $files{$file} = gendigest("$dir/$file");
    }
  }
  return calc_srcmd5(\%files);
}

sub get_scm_controlled {
  my ($dir) = @_;
  return {} unless -d "$dir/.git" || -d "$dir/../.git";
  my $fd;
  my @controlled;
  #open($fd, '-|', 'git', '-C', $dir, 'ls-files', '-z') || die("git: $!\n");
  open($fd, '-|', 'git', '-C', $dir, 'ls-tree', '--name-only', '-z', 'HEAD') || die("git: $!\n");
  my $d = '';
  1 while sysread($fd, $d, 8192, length($d));
  close($fd) || die("git ls-tree failed: $?\n");
  my @d = split("\0", $d);
  s/\/.*// for @d;
  return { map {$_ => 1} @d };
}

sub is_subdir_build {
  my ($dir, $files) = @_;
  my @sd = grep {$_ eq 'dist' || $_ eq 'package'} @$files;
  return 0 unless @sd;
  return 0 if grep {/\.spec$/} @$files;
  for my $sd (@sd) {
    return 1 if grep {/\.spec$/} PBuild::Util::ls("$dir/$sd");
  }
}

sub list_package {
  my ($dir) = @_;
  my %files;
  my @assets;
  my $controlled;
  my @all = sort(PBuild::Util::ls($dir));
  for my $file (@all) {
    next if $file eq '_meta' || $file eq '.git';
    next if $file =~ /\n/;
    my @s = lstat("$dir/$file");
    die("$dir/$file: $!\n") unless @s;
    my $lnk;
    if (-l _) {
      $lnk = readlink("$dir/$file");
      die("readlink $dir/$file: $!\n") unless defined $lnk;
      if ($lnk =~ /^(\/ipfs\/.+)$/s) {
	my $assetid = Digest::MD5::md5_hex($1);
	push @assets, { 'file' => $file, 'cid' => $1, 'assetid' => $assetid, 'immutable' => 1, 'type' => 'ipfs' };
	next;
      }
    }
    if (-l _ || -d _ || $file =~ /^\./) {
      if (!$controlled) {
	$controlled = get_scm_controlled($dir);
	if (!%$controlled && is_subdir_build($dir, \@all)) {
	  $controlled = { map {$_ => 1} @all };
	}
	# redo stat because get_scm_controlled changed it
	lstat("$dir/$file") || die("$dir/$file: $!\n");
      }
      if (!$controlled->{$file}) {
	next if -d _ || $file =~ /^\./;
	@s = stat("$dir/$file");
	next unless @s && -f _;		# follow links to files
	$files{$file} = gendigest("$dir/$file");
	next;
      }
    }
    if (-l _) {
      $files{"$file/"} = genlnkdigest("$dir/$file");
    } elsif (-d _) {
      $files{"$file/"} = gendirdigest("$dir/$file");
    } elsif (-f _) {
      $files{$file} = gendigest("$dir/$file");
    }
  }
  $files{"debian/control"} = gendigest("$dir/debian/control") if $files{'debian/'} && -s "$dir/debian/control";
  return \%files, \@assets;
}

sub calc_srcmd5 {
  my ($files) = @_;
  my $meta = '';
  $meta .= "$files->{$_}  $_\n" for sort keys %$files;
  return Digest::MD5::md5_hex($meta);
}

1;
