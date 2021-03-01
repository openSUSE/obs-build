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

package PBuild::RemoteAssets;

use PBuild::Source;
use PBuild::Util;
use PBuild::Download;

use Digest::MD5 ();

use strict;

# Fedora FedPkg

sub fedpkg_parse {
  my ($p) = @_;
  my $files = $p->{'files'};
  return unless $files->{'sources'};
  my $fd;
  open ($fd, '<', "$p->{'dir'}/sources") || die("$p->{'dir'}/sources: $!\n");
  my %asset_files;
  while (<$fd>) {
    chomp;
    if (/^(\S+) \(.*\) = ([0-9a-fA-F]{32,})$/s) {
      $asset_files{$2} = lc("$1:$3");
    } elsif (/^([0-9a-fA-F]{32})  (.*)$/) {
      $asset_files{$2} = lc("md5:$1");
    } else {
      warn("unparsable line in 'sources' file: $_\n");
    }
  }
  close $fd;
  return unless %asset_files;
  $p->{'asset_files'} = \%asset_files;
  $p->{'asset_url'} = 'http://pkgs.fedoraproject.org/repo/pkgs';
  my %updated_files = %$files;
  for (sort keys %asset_files) {
    $updated_files{$_} = substr($asset_files{$_}, 0, 32);
  }
  $p->{'srcmd5'} = PBuild::Source::calc_srcmd5(\%updated_files);
}

# http://pkgs.fedoraproject.org/repo/pkgs/<name>/<file>/<hashtype>/<hash>/<file>
sub fedpkg_fetch {
  my ($p, $assetdir) = @_;
  my %tofetch;
  my $asset_files = $p->{'asset_files'};
  for my $file (sort keys %{$asset_files || {}}) {
    my $asset = Digest::MD5::md5_hex("$asset_files->{$file}  $file");
    my $adir = "$assetdir/".substr($asset, 0, 2);
    next if -e "$adir/$asset";
    $tofetch{$asset} = [ $file, $asset_files->{$file} ] ;
  }
  return unless %tofetch;
  die("need a parsed name to download fedpkg assets\n") unless $p->{'name'};
  my $url = $p->{'asset_url'};
  die("need an asset url to download fedpkg assets\n") unless $url;
  my $ntofetch = keys %tofetch;
  print "fetching $ntofetch assets from $url\n";
  for my $asset (sort keys %tofetch) {
    my $file = $tofetch{$asset}->[0];
    my $chksum = $tofetch{$asset}->[1];
    die("need a checksum do download fedpkg assets\n") unless $chksum;
    my $adir = "$assetdir/".substr($asset, 0, 2);
    PBuild::Util::mkdir_p($adir);
    my $fedpkg_url = $url;
    $fedpkg_url =~ s/\/?$/\//;
    my $chksum_path = $chksum;
    $chksum_path =~ s/:/\//;
    $fedpkg_url .= "$p->{'name'}/$file/$chksum_path/$file";
    PBuild::Download::download($fedpkg_url, "$adir/.$asset.$$", "$adir/$asset", 'retry' => 3, 'digest' => $chksum);
  }
}

1;
