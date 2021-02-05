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

sub list_package {
  my ($dir) = @_;
  my %files;
  for my $file (sort(PBuild::Util::ls($dir))) {
    next if $file =~/^\./;
    next if $file eq '_meta';
    my $fd;
    my @s = lstat("$dir/$file");
    if (!@s) {
      warn("$dir/$file: $!\n");
      next;
    }
    next unless -f _ && ! -l _;
    open($fd, '<', "$dir/$file") || die("$dir/$file: $!\n");
    my $ctx = Digest::MD5->new;
    $ctx->addfile($fd);
    close $fd;
    $files{$file} = $ctx->hexdigest();
  }
  return \%files;
}

sub calc_srcmd5 {
  my ($files) = @_;
  my $meta = '';
  $meta .= "$files->{$_}  $_\n" for sort keys %$files;
  return Digest::MD5::md5_hex($meta);
}

1;
