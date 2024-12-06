################################################################
#
# Copyright (c) 2024 SUSE Linux LLC
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

package Build::Apkrepo;

use strict;

use Build::Apk;

use Digest::MD5;
eval { require Archive::Tar; };
*Archive::Tar::new = sub {die("Archive::Tar is not available\n")} unless defined &Archive::Tar::new;
eval { require MIME::Base64; };

sub addpkg {
  my ($res, $data, $options) = @_;
  if ($options->{'addselfprovides'}) {
    my $selfprovides = $data->{'name'};
    $selfprovides .= "=$data->{'version'}" if defined $data->{'version'};
    push @{$data->{'provides'}}, $selfprovides unless @{$data->{'provides'} || []} && $data->{'provides'}->[-1] eq $selfprovides;
  }
  if ($options->{'normalizedeps'}) {
    # our normalized dependencies have spaces around the op
    for my $dep (qw {provides requires conflicts obsoletes supplements install_if}) {
      next unless $data->{$dep};
      for (@{$data->{$dep}}) {
        s/^([a-zA-Z0-9\._+-]+)~/$1=~/;
        s/ ?([<=>]+) ?/ $1 /;
      }
    }
  }
  my $install_if = delete $data->{'install_if'};
  $data->{'supplements'} = [ join(' & ', @$install_if) ] if @{$install_if || []};

  $data->{'location'} = "$data->{'name'}-$data->{'version'}.apk";
  $data->{'release'} = $1 if $data->{'version'} =~ s/-([^-]*)$//s;
  my $apk_chksum = delete $data->{'apk_chksum'};
  if ($options->{'withapkchecksum'} && $apk_chksum) {
    if (substr($apk_chksum, 0, 2) eq 'Q1' && defined &MIME::Base64::decode_base64) {
      my $c = MIME::Base64::decode_base64(substr($apk_chksum, 2));
      $data->{'apkchecksum'} = "sha1:" . unpack('H*', $c) if $c && length($c) == 20;
    } elsif (substr($apk_chksum, 0, 2) eq 'Q2' && defined &MIME::Base64::decode_base64) {
      my $c = MIME::Base64::decode_base64(substr($apk_chksum, 2));
      $data->{'apkchecksum'} = "sha256:" . unpack('H*', $c) if $c && length($c) == 32;
    }
  }
  if (ref($res) eq 'CODE') {
    $res->($data);
  } else {
    push @$res, $data;
  }
}

sub parse {
  my ($in, $res, %options) = @_;
  $res ||= [];
  my $tar = Archive::Tar->new;
  my @read = $tar->read($in, 1, {'filter' => '^APKINDEX$', 'limit' => 1});
  die("$in: not an apk index file\n") unless @read == 1;
  my $pkgidx = $read[0]->get_content;
  Build::Apk::parseidx($pkgidx, sub { addpkg($res, $_[0], \%options) });
  return $res;
}

