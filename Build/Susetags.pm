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

package Build::Susetags;

use strict;

# compatibility to old OBS code
sub parse_obs_compat {
  my ($file, undef, undef, @arches) = @_;
  $file = "$file.gz" if ! -e $file && -e "$file.gz";
  my $pkgs = {};
  parse($file, sub {
    my ($data) = @_;
    my $medium = delete($data->{'medium'});
    my $loc = delete($data->{'location'});
    if (defined($medium) && defined($loc)) {
      $loc =~ s/^\Q$data->{'arch'}\E\///;
      $data->{'path'} = "$medium $loc";
    }
    return unless !@arches || grep { /$data->{'arch'}/ } @arches;
    $pkgs->{"$data->{'name'}-$data->{'version'}-$data->{'release'}-$data->{'arch'}"} = $data;
  }, 'addselfprovides' => 1);
  return $pkgs;
}

my %tmap = (
  'Pkg' => '',
  'Loc' => 'location',
  'Src' => 'source',
  'Prv' => 'provides',
  'Req' => 'requires',
  'Con' => 'conflicts',
  'Obs' => 'obsoletes',
  'Rec' => 'recommends',
  'Sug' => 'suggests',
  'Sup' => 'supplements',
  'Enh' => 'enhances',
  'Tim' => 'buildtime',
);

sub addpkg {
  my ($res, $data, $options) = @_;
  # fixup location and source
  if (exists($data->{'location'})) {
    my ($medium, $dir, $loc) = split(' ', $data->{'location'}, 3);
    $data->{'medium'} = $medium;
    $data->{'location'} = defined($loc) ? "$dir/$loc" : "$data->{'arch'}/$dir";
  }
  $data->{'source'} =~ s/\s.*// if exists $data->{'source'};
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

sub parse {
  return parse_obs_compat(@_) if @_ > 2 && !defined $_[2];
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
  my $cur;
  my $r = join('|', sort keys %tmap);
  $r = qr/^([\+=])($r):\s*(.*)/;
  while (<$fd>) {
    chomp;
    next unless /$r/;
    my ($multi, $tag, $data) = ($1, $2, $3);
    if ($multi eq '+') {
      while (<$fd>) {
	chomp;
	last if /^-\Q$tag\E/;
	next if $tag eq 'Req' && /^rpmlib\(/;
	push @{$cur->{$tmap{$tag}}}, $_;
      }
    } elsif ($tag eq 'Pkg') {
      addpkg($res, $cur, \%options) if $cur;
      $cur = {};
      ($cur->{'name'}, $cur->{'version'}, $cur->{'release'}, $cur->{'arch'}) = split(' ', $data);
      $cur->{'epoch'} = $1 if $cur->{'version'} =~ s/^(\d+)://;
    } else {
      $cur->{$tmap{$tag}} = $data;
    }
  }
  addpkg($res, $cur, \%options) if $cur;
  if (!ref($in)) {
    close($fd) || die("close $in: $!\n");
  }
  return $res;
}
  
1;
