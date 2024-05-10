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

package Build::Debrepo;

use strict;

sub addpkg {
  my ($res, $data, $options) = @_;
  return unless defined $data->{'version'};
  my $selfprovides;
  $selfprovides = "= $data->{'version'}" if $options->{'addselfprovides'};
  # split version into evr
  $data->{'epoch'} = $1 if $data->{'version'} =~ s/^(\d+)://s;
  $data->{'release'} = $1 if $data->{'version'} =~ s/-([^-]*)$//s;
  for my $d (qw{provides requires conflicts recommends suggests enhances breaks prerequires}) {
    next unless $data->{$d};
    if ($options->{'normalizedeps'}) {
      $data->{$d} =~ s/\(([^\)]*)\)/$1/g;
      $data->{$d} =~ s/<</</g;
      $data->{$d} =~ s/>>/>/g;
    }
    $data->{$d} = [ split(/\s*,\s*/, $data->{$d}) ];
  }
  push @{$data->{'requires'}}, @{$data->{'prerequires'}} if $data->{'prerequires'};
  delete $data->{'prerequires'};
  push @{$data->{'conflicts'}}, @{$data->{'breaks'}} if $data->{'breaks'};
  delete $data->{'breaks'};
  if (defined($selfprovides)) {
    $selfprovides = "($selfprovides)" unless $options->{'normalizedeps'};
    $selfprovides = "$data->{'name'} $selfprovides";
    push @{$data->{'provides'}}, $selfprovides  unless @{$data->{'provides'} || []} && $data->{'provides'}->[-1] eq $selfprovides;
  }
  if ($options->{'withchecksum'}) {
    for (qw {md5 sha1 sha256}) {
      my $c = delete($data->{"checksum_$_"});
      $data->{'checksum'} = "$_:$c" if $c;
    }
  }
  $data->{'source'} =~ s/\s.*// if $data->{'source'};
  if (ref($res) eq 'CODE') {
    $res->($data);
  } else {
    push @$res, $data;
  }
}

my %tmap = (
  'package' => 'name',
  'version' => 'version',
  'architecture' => 'arch',
  'provides' => 'provides',
  'depends' => 'requires',
  'pre-depends' => 'prerequires',
  'conflicts' => 'conflicts',
  'breaks' => 'breaks',
  'recommends' => 'recommends',
  'suggests' => 'suggests',
  'enhances' => 'enhances',
  'filename' => 'location',
  'source' => 'source',
  'multi-arch' => 'multiarch',
);

my %tmap_checksums = (
  'md5sum' => 'checksum_md5',
  'sha1'   => 'checksum_sha1',
  'sha256' => 'checksum_sha256',
);

sub parse {
  my ($in, $res, %options) = @_;
  $res ||= [];
  my $fd;
  if (ref($in)) {
    $fd = $in;
  } else {
    if ($in =~ /\.gz$/) {
      open($fd, '-|', "gzip", "-dc", $in) || die("$in: $!\n");
    } else {
      open($fd, '<', $in) || die("$in: $!\n");
    }
  }
  my $pkg = {};
  my $tag;
  my %ltmap = %tmap;
  %ltmap = (%ltmap, %tmap_checksums) if $options{'withchecksum'};
  while (<$fd>) {
    chomp;
    if ($_ eq '') {
      addpkg($res, $pkg, \%options) if %$pkg;
      $pkg = {};
      next;
    }
    if (/^\s/) {
      next unless $tag;
      $pkg->{$tag} .= "\n".substr($_, 1);
      next;
    }
    my $data;
    ($tag, $data) = split(':', $_, 2);
    next unless defined $data;
    $tag = $ltmap{lc($tag)};
    next unless $tag;
    $data =~ s/^\s*//;
    $pkg->{$tag} = $data;
  }
  addpkg($res, $pkg, \%options) if %$pkg;
  if (!ref($in)) {
    close($fd) || die("close $in: $!\n");
  }
  return $res;
}

sub urldecode {
  my ($str, $iscgi) = @_;
  $str =~ tr/+/ / if $iscgi;
  $str =~ s/%([a-fA-F0-9]{2})/chr(hex($1))/sge;
  return $str;
}

sub parserepourl {
  my ($url) = @_;
  my @components;
  my $baseurl;
  if ($url =~ /\?/) {
    my ($base, $query) = split(/\?/, $url, 2);
    if ("&$query" =~ /\&dist=/) {
      my $dist;
      for my $querypart (split('&', $query)) {
        my ($k, $v) = split('=', $querypart, 2);
        $k = urldecode($k, 1);
        $v = urldecode($v, 1);
        $dist = $v if $k eq 'dist';
        push @components, split(/[,+]/, $v) if $k eq 'component';
      }
      $baseurl = $base;
      $baseurl .= '/' unless $baseurl =~ /\/$/;
      $url = "${baseurl}dists/${dist}/";
      push @components, 'main' unless @components;
    }
  }
  if (@components) {
    ;   # all done above
  } elsif ($url =~ /^(.*\/)\.(\/.*)?$/) {
    # flat repo
    $baseurl = $1;
    @components = ('.');
    $url = defined($2) ? "$1$2" : $1;
    $url .= '/' unless $url =~ /\/$/;
  } else {
    if ($url =~ /([^\/]+)$/) {
      @components = split(/[,+]/, $1);
      $url =~ s/([^\/]+)$//;
    }
    push @components, 'main' unless @components;
    $url .= '/' unless $url =~ /\/$/;
    $baseurl = $url;
    $url =~ s/([^\/]+\/)$/dists\/$1/;
    $baseurl =~ s/([^\/]+\/)$//;
  }
  return $baseurl, $url, \@components;
}

1;
