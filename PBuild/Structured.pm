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

package PBuild::Structured;

use Build::SimpleXML;

use PBuild::Util;

use strict;

our $pbuild = [
    'pbuild' =>
     [[ 'destination' =>
	    'name',
	    'config',
	  [ 'repo' ],
	  [ 'registry' ],
     ]],
];

our $link = [
    'link' =>
        'project',
        'package',
        'baserev',
        'missingok',
      [ 'patches' => [[ '' => [] ]] ],
];

our $multibuild = [
    'multibuild' =>
          [ 'package' ],        # obsolete
          [ 'flavor' ],
];

#
# Convert dtd to a hash mapping elements/attributes to multi/subdtd tupels
#
sub _toknown {
  my ($me, @dtd) = @_;
  my %known = map {ref($_) ? (!@$_ ? () : (ref($_->[0]) ? $_->[0]->[0] : $_->[0] => $_)) : ($_=> $_)} @dtd;
  for my $v (values %known) {
    if (!ref($v)) {
      $v = 0;				# string
    } elsif (@$v == 1 && !ref($v->[0])) {
      $v = 1;				# array of strings
    } elsif (@$v == 1) {
      $v = [1, _toknown(@{$v->[0]}) ];	# array of sub-elements
    } else {
      $v = [0, _toknown(@$v) ];		# sub-element
    }
  }
  $known{'.'} = $me;
  return \%known;
}

#
# Process a single element
#
sub _workin {
  my ($known, $out, $in, $allowunknown) = @_;
  die("bad input\n") unless ref($in) eq 'HASH';
  for my $x (sort keys %$in) {
    my $k = $known->{$x};
    if (!defined($k) && defined($known->{''})) {
      $k = $known->{''};
      die("bad dtd\n") unless ref($k);
      if (!$k->[0]) {
	die("element '' must be singleton\n") if exists $out->{''};
	$out = $out->{''} = {};
      } else {
	push @{$out->{''}}, {};
	$out = $out->{''}->[-1];
      }
      $known= $k->[1];
      $k = $known->{$x};
    }
    if (!defined($k)) {
      next if $allowunknown;
      die("unknown element: $x\n");
    }
    my $v = $in->{$x};
    if (ref($v) eq '') {
      # attribute
      if (ref($k)) {
	die("attribute '$x' must be element\n") if @{$known->{$x}} > 1 || ref($known->{$x}->[0]);
	push @{$out->{$x}}, $v;
      } else {
	die("attribute '$x' must be singleton\n") if exists $out->{$x};
	$out->{$x} = $v;
      }
      next;
    }
    die("bad input\n") unless ref($v) eq 'ARRAY';
    for (@$v) {
      die("bad element '$x'\n") if ref($_) ne 'HASH';
    }
    if (!ref($k)) {
      for (@$v) {
        die("element '$x' has subelements\n") if !exists($_->{'_content'}) || keys(%$_) != 1;
      }
      if (!$k) {
	die("element '$x' must be singleton\n") unless @$v == 1 && !exists($out->{$x});
	$out->{$x} = $v->[0]->{'_content'};
      } else {
	push @{$out->{$x}}, map {$_->{'_content'}} @$v;
      }
    } else {
      if (!$k->[0]) {
	die("element '$x' must be singleton\n") unless @$v == 1 && !exists($out->{$x});
	$out->{$x} = {};
	_workin($k->[1], $out->{$x}, $v->[0], $allowunknown);
      } else {
	for (@$v) {
	  push @{$out->{$x}}, {};
	  _workin($k->[1], $out->{$x}->[-1], $_, $allowunknown);
	}
      }
    }
  }
}

#
# Postprocess parsed xml data by matching it to a dtd
#
sub xmlpostprocess {
  my ($d, $dtd, $allowunknown) = @_;
  my $me = $dtd->[0];
  my $known =  {$me => [ 0, _toknown(@$dtd) ] };
  my $out = {};
  _workin($known, $out, $d, $allowunknown);
  die("xml is not a '$me' element\n") unless defined $out->{$me};
  return $out->{$me};
}

#
# Read a file containing XML, parse and postprocess it according to the provided dtd
#
sub readxml {
  my ($fn, $dtd, $nonfatal, $allowunknown) = @_;
  my $d = PBuild::Util::readstr($fn, $nonfatal);
  return $d unless defined $d;
  eval {
    $d = Build::SimpleXML::parse($d);
    $d = xmlpostprocess($d, $dtd, $allowunknown);
  };
  if ($@) {
    return undef if $nonfatal;
    die($@);
  }
  return $d;
}

1;
