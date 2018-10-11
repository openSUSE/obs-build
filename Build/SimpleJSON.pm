################################################################
#
# Copyright (c) 2018 SUSE Linux Products GmbH
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

package Build::SimpleJSON;

use strict;

sub unparse_keys {
  my ($d) = @_;
  my @k = grep {$_ ne '_start' && $_ ne '_end' && $_ ne '_order' && $_ ne '_type'} sort keys %$d;
  return @k unless $d->{'_order'};
  my %k = map {$_ => 1} @k;
  my @ko;
  for (@{$d->{'_order'}}) {
    push @ko, $_ if delete $k{$_};
  }
  return (@ko, grep {$k{$_}} @k);
}

my %specialescapes = (
  '"' => '\\"',
  '\\' => '\\\\',
  '/' => '\\/',
  "\b" => '\\b',
  "\f" => '\\f',
  "\n" => '\\n',
  "\r" => '\\r',
  "\t" => '\\t',
);

sub unparse_string {
  my ($d) = @_;
  $d =~ s/([\"\\\000-\037])/$specialescapes{$1} || sprintf('\\u%04d', ord($1))/ge;
  return "\"$d\"";
}

sub unparse_bool {
  my ($d) = @_;
  return $d ? 'true' : 'false';
}

sub unparse_number {
  my ($d) = @_;
  return sprintf("%.f", $d) if $d == int($d);
  return sprintf("%g", $d);
}

sub unparse {
  my ($d, %opts) = @_;

  my $r = '';
  if (ref($d) eq 'ARRAY') {
    return '[]' unless @$d;
    my $indent = $opts{'ugly'} ? '' : $opts{'indent'} || '';
    my $nl = $opts{'ugly'} ? '' : "\n";
    my $sp = $opts{'ugly'} ? '' : " ";
    my $first = 0;
    for my $dd (@$d) {
      $r .= ",$nl" if $first++;
      $r .= "$indent$sp$sp$sp".unparse($dd, %opts, 'indent' => "   $indent");
    }
    return "\[$nl$r$nl$indent\]";
  }
  if (ref($d) eq 'HASH') {
    my @k = unparse_keys($d);
    return '{}' unless @k;
    my $indent = $opts{'ugly'} ? '' : $opts{'indent'} || '';
    my $nl = $opts{'ugly'} ? '' : "\n";
    my $sp = $opts{'ugly'} ? '' : " ";
    my $first = 0;
    for my $k (@k) {
      $r .= ",$nl" if $first++;
      my $dd = $d->{$k};
      $r .= "$indent$sp$sp$sp".unparse_string($k)."$sp:$sp".unparse($dd, %opts, 'indent' => "   $indent", '_type' => ($d->{'_type'} || {})->{$k});
    }
    return "\{$nl$r$nl$indent\}";
  }
  return 'null' unless defined $d;
  my $type = $opts{'_type'} || '';
  return unparse_bool($d) if $type eq 'bool';
  return unparse_number($d) if $type eq 'number';
  return unparse_string($d);
}

1;
