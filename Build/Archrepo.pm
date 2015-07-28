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

package Build::Archrepo;

use strict;
use Build::Arch;

eval { require Archive::Tar; };
*Archive::Tar::new = sub {die("Archive::Tar is not available\n")} unless defined &Archive::Tar::new;

sub addpkg {
  my ($res, $data, $options) = @_;
  return unless defined $data->{'version'};
  if ($options->{'addselfprovides'}) {
    my $selfprovides = $data->{'name'};
    $selfprovides .= "=$data->{'version'}" if defined $data->{'version'};
    push @{$data->{'provides'}}, $selfprovides unless @{$data->{'provides'} || []} && $data->{'provides'}->[-1] eq $selfprovides;
  }
  if (defined($data->{'version'})) {
    # split version into evr
    $data->{'epoch'} = $1 if $data->{'version'} =~ s/^(\d+)://s;
    $data->{'release'} = $1 if $data->{'version'} =~ s/-([^-]*)$//s;
  }
  $data->{'location'} = delete($data->{'filename'}) if exists $data->{'filename'};
  if ($options->{'withchecksum'}) {
    for (qw {md5 sha1 sha256}) {
      my $c = delete($data->{"checksum_$_"});
      $data->{'checksum'} = "$_:$c" if $c;
    }     
  } else {
    delete $data->{"checksum_$_"} for qw {md5 sha1 sha256};
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
  die("Build::Archrepo::parse needs a filename\n") if ref($in);
  die("$in: $!\n") unless -e $in;
  my $repodb = Archive::Tar->iter($in, 1);
  die("$in is not a tar archive\n") unless $repodb;
  my $e;
  my $lastfn = '';
  my $d;
  while ($e = $repodb->()) {
    next unless $e->type() == Archive::Tar::Constant::FILE;
    my $fn = $e->name();
    next unless $fn =~ s/\/(?:depends|desc|files)$//s;
    if ($lastfn ne $fn) {
      addpkg($res, $d, \%options) if $d->{'name'};
      $d = {};
      $lastfn = $fn;
    }
    Build::Arch::parserepodata($d, $e->get_content());
  }
  addpkg($res, $d, \%options) if $d->{'name'};
  return $res;
}

1;
