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

package PBuild::Multibuild;

use strict;

use Build::SimpleXML;
use PBuild::Verify;
use PBuild::Util;

sub find_mbname {
  my ($files) = @_;
  my $mbname = '_multibuild';
  # support service generated multibuild files, see findfile
  if ($files->{'_service'}) {
    for (sort keys %$files) {
      next unless /^_service:.*:(.*?)$/s;
      $mbname = $_ if $1 eq '_multibuild';
    }
  }
  return $mbname;
}

sub readmbxml {
  my ($xmlfile) = @_;
  my $xml = PBuild::Util::readstr($xmlfile);
  my $mb = Build::SimpleXML::parse($xml);
  PBuilder::Verify::verify_multibuild($mb);
  return $mb;
}

sub getmultibuild_fromfiles {
  my ($srcdir, $files) = @_;
  my $mbname = find_mbname($files);
  my $mb;
  if ($files->{$mbname}) {
    eval { $mb = readmbxml("$srcdir/$mbname") };
    if ($@) {
      warn("$srcdir/$mbname: $@");
      return undef;
    }
    $mb->{'_md5'} = $files->{$mbname} if $mb;
  }
  return $mb;
}

sub expand_multibuilds {
  my ($pkgs) = @_;
  for my $pkg (sort keys %$pkgs) {
    my $p = $pkgs->{$pkg};
    my $mb = getmultibuild_fromfiles($p->{'dir'}, $p->{'files'});
    next unless $mb;
    my @mbp = @{$mb->{'flavor'} || $mb->{'package'} || []};
    for my $flavor (@mbp) {
      my $mpkg = "$pkg:$flavor";
      $pkgs->{$mpkg} = { %$p, 'pkg' => $mpkg, 'flavor' => $flavor, 'originpackage' => $pkg };
    }
  }
}

1;
