################################################################
#
# Copyright (c) 2021 SUSE Linux Products GmbH
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

package Build::SimpleYAML;

use strict;

use Scalar::Util;

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
  "\0" => '\\0',
  "\a" => '\\a',
  "\b" => '\\b',
  "\t" => '\\t',
  "\n" => '\\n',
  "\013" => '\\v',
  "\f" => '\\f',
  "\r" => '\\r',
  "\e" => '\\e',
  "\x85" => '\\N',
);

sub unparse_string {
  my ($d, $inline) = @_;
  return "''" unless length $d;
  return "\"$d\"" if Scalar::Util::looks_like_number($d);
  if ($d =~ /[\x00-\x1f\x7f-\x9f\']/) {
    $d =~ s/\\/\\\\/g;
    $d =~ s/\"/\\\"/g;
    $d =~ s/([\x00-\x1f\x7f-\x9f])/$specialescapes{$1} || '\x'.sprintf("%X",ord($1))/ge;
    return "\"$d\"";
  } elsif ($d =~ /^[\!\&*{}[]|>@`"'#%, ]/s) {
    return "'$d'";
  } elsif ($inline && $d =~ /[,\[\]\{\}]/) {
    return "'$d'";
  } elsif ($d =~ /: / || $d =~ / #/ || $d =~ /[: \t]\z/) {
    return "'$d'";
  } elsif ($d eq '~' || $d eq 'null' || $d eq 'true' || $d eq 'false' && $d =~ /^(?:---|\.\.\.)/s) {
    return "'$d'";
  } elsif ($d =~ /^[-?:](?:\s|\z)/s) {
    return "'$d'";
  } else {
    return $d;
  }
}

sub unparse_literal {
  my ($d, $indent) = @_;
  return unparse_string($d) if !defined($d) || $d eq '' || $d =~ /[\x00-\x09\x0b-\x1f\x7f-\x9f]/;
  my @lines = split("\n", $d, -1);
  return "''" unless @lines;
  my $r = '|';
  my @nonempty = grep {$_ ne ''} @lines;
  $r .= '2' if @nonempty && $nonempty[0] =~ /^ /;
  if ($lines[-1] ne '') {
    $r .= '-';
  } else {
    pop @lines;
    $r .= '+' if @lines && $lines[-1] eq '';
  }
  $r .= $_ ne '' ? "\n$indent$_" : "\n" for @lines;
  return $r;
}

sub unparse_folded {
  my ($d, $indent) = @_;
  return unparse_string($d) if !defined($d) || $d eq '' || $d =~ /[\x00-\x09\x0b-\x1f\x7f-\x9f]/;
  my @lines = split("\n", $d, -1);
  return "''" unless @lines;
  my $r = '>';
  my @nonempty = grep {$_ ne ''} @lines;
  $r .= '2' if @nonempty && $nonempty[0] =~ /^ /;
  if ($lines[-1] ne '') {
    $r .= '-';
  } else {
    pop @lines;
    $r .= '+' if @lines && $lines[-1] eq '';
  }
  my $neednl;
  my $ll = 78 - length($indent);
  $ll = 40 if $ll < 40;
  for (splice(@lines)) {
    if ($_ =~ /^ /) {
      push @lines, $_;
      $neednl = 0;
      next;
    }
    push @lines, '' if $neednl;
    while (length($_) > $ll && (/^(.{1,$ll}[^ ]) [^ ]/s || /^(..*?[^ ]) [^ ]/s)) {
      push @lines, $1;
      $_ = substr($_, length($1) + 1);
    }
    push @lines, $_;
    $neednl = 1;
  }
  $r .= $_ ne '' ? "\n$indent$_" : "\n" for @lines;
  return $r;
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

  return "---\n".unparse($d, %opts, 'noheader' => 1)."\n...\n" unless $opts{'noheader'};
  my $r = '';
  if (ref($d) eq 'ARRAY') {
    return '[]' unless @$d;
    $opts{'inline'} = 1 if $opts{'_type'} && $opts{'_type'} =~ s/^inline_?//;
    if ($opts{'inline'}) {
      my $first = 0;
      for my $dd (@$d) {
        $r .= ", " if $first++;
        $r .= unparse($dd, %opts);
      }
      return "\[$r\]";
    }
    my $indent = $opts{'indent'} || '';
    my $first = 0;
    for my $dd (@$d) {
      $r .= "\n$indent" if $first++;
      $r .= "- ".unparse($dd, %opts, 'indent' => "  $indent");
    }
    return $r;
  }
  if (ref($d) eq 'HASH') {
    my @k = unparse_keys($d);
    return '{}' unless @k;
    $opts{'inline'} = 1 if $opts{'_type'} && $opts{'_type'} =~ s/^inline_?//;
    if ($opts{'inline'}) {
      my $first = 0;
      for my $k (@k) {
        $r .= ", " if $first++;
        my $dd = $d->{$k};
        my $type = ($d->{'_type'} || {})->{$k};
        $r .= unparse_string($k).": ".unparse($dd, %opts, '_type' => $type);
      }
      return "\{$r\}";
    }
    my $indent = $opts{'indent'} || '';
    my $first = 0;
    for my $k (@k) {
      my $dd = $d->{$k};
      my $type = ($d->{'_type'} || {})->{$k} || ($d->{'_type'} || {})->{'*'};
      $r .= "\n$indent" if $first++;
      $r .= unparse_string($k).":";
      if (($type && $type =~ /^inline_?/) || (ref($dd) ne 'ARRAY' && ref($dd) ne 'HASH')) {
        $r .= " ".unparse($dd, %opts, 'indent' => "  $indent", '_type' => $type);
      } elsif (ref($dd) eq 'HASH') {
        $r .= "\n$indent  ";
        $r .= unparse($dd, %opts, 'indent' => "  $indent", '_type' => $type);
      } elsif (ref($dd) eq 'ARRAY') {
        $r .= "\n$indent";
        $r .= unparse($dd, %opts, 'indent' => "$indent", '_type' => $type);
      }
    }
    return $r;
  }
  my $type = $opts{'_type'} || '';
  return '~' unless defined $d;
  return unparse_bool($d) if $type eq 'bool';
  return unparse_number($d) if $type eq 'number';
  return unparse_literal($d, $opts{'indent'} || '') if $type eq 'literal' && !$opts{'inline'};
  return unparse_folded($d, $opts{'indent'} || '') if $type eq 'folded' && !$opts{'inline'};
  return unparse_string($d, $opts{'inline'});
}

1;
