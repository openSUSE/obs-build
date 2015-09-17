################################################################
#
# Copyright (c) 2015 SUSE Linux Products GmbH
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

package Build::Mdkrepo;

use strict;
use Data::Dumper;

sub addpkg {
  my ($res, $data, $options) = @_;
  if ($options->{'addselfprovides'} && defined($data->{'name'}) && defined($data->{'version'})) {
    if (($data->{'arch'} || '') ne 'src' && ($data->{'arch'} || '') ne 'nosrc') {
      my $evr = $data->{'version'};
      $evr = "$data->{'epoch'}:$evr" if $data->{'epoch'};
      $evr = "$evr-$data->{'release'}" if defined $data->{'release'};
      my $s = "$data->{'name'} = $evr";
      push @{$data->{'provides'}}, $s unless grep {$_ eq $s} @{$data->{'provides'} || []};
    }
  }
  if (ref($res) eq 'CODE') {
    $res->($data);
  } else {
    push @$res, $data;
  }

}

sub parsedeps {
  my ($d) = @_;
  my @d = split('@', $d);
  for (@d) {
    s/\[\*\]//s;
    s/\[(.*)\]$/ $1/s;
    s/ == / = /;
  }
  return \@d;
}

sub parse {
  my ($in, $res, %options) = @_;
  $res ||= [];
  my $fd;
  if (ref($in)) {
    $fd = $in;
  } else {
    if ($in =~ /\.[gc]z$/) {
      # we need to probe, as mageia uses xz for compression
      open($fd, '<', $in) || die("$in: $!\n");
      my $probe;
      sysread($fd, $probe, 5);
      close($fd);
      if ($probe && $probe eq "\xFD7zXZ") {
        open($fd, '-|', "xzdec", "-dc", $in) || die("$in: $!\n");
      } else {
        open($fd, '-|', "gzip", "-dc", $in) || die("$in: $!\n");
      }
    } else {
      open($fd, '<', $in) || die("$in: $!\n");
    }
  }
  my $s = {};
  while (<$fd>) {
    chomp;
    if (/^\@summary\@/) {
      $s->{'summary'} = substr($_, 9);
    } elsif (/^\@provides\@/) {
      $s->{'provides'} = parsedeps(substr($_, 10));
    } elsif (/^\@requires\@/) {
      $s->{'requires'} = parsedeps(substr($_, 10));
    } elsif (/^\@suggests\@/) {
      $s->{'suggests'} = parsedeps(substr($_, 10));
    } elsif (/^\@recommends\@/) {
      $s->{'recommends'} = parsedeps(substr($_, 12));
    } elsif (/^\@obsoletes\@/) {
      $s->{'obsoletes'} = parsedeps(substr($_, 11));
    } elsif (/^\@conflicts\@/) {
      $s->{'conflicts'} = parsedeps(substr($_, 11));
    } elsif (/^\@info\@/) {
      $s ||= {};
      my @s = split('@', substr($_, 6));
      $s->{'location'} = "$s[0].rpm";
      my $arch;
      if ($s[0] =~ /\.([^\.]+)$/) {
	$arch = $1;
	$s[0] =~ s/\.[^\.]+$//;
      }
      $s->{'epoch'} = $s[1] if $s[1];
      $s[0] =~ s/-\Q$s[4]\E[^-]*$//s if defined($s[4]) && $s[4] ne '';	# strip disttag
      $s[0] .= ":$s[5]" if defined($s[5]) && $s[5] ne '';	# add distepoch
      $s->{'arch'} = $arch || 'noarch';
      if ($s[0] =~ /^(.*)-([^-]+)-([^-]+)$/s) {
	($s->{'name'}, $s->{'version'}, $s->{'release'}) = ($1, $2, $3);
	# fake source entry for now...
	$s->{'source'} = $s->{'name'} if $s->{'arch'} ne 'src' && $s->{'arch'} ne 'nosrc';
        addpkg($res, $s, \%options);
      }
      $s = {};
    }
  }
  return $res;
}

1;

