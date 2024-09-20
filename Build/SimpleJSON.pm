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
  my ($d, $order, $keepspecial) = @_;
  my @k = sort keys %$d;
  if (!$keepspecial) {
    @k = grep {$_ ne '_start' && $_ ne '_end' && $_ ne '_order' && $_ ne '_type'} @k;
    $order = $d->{'_order'} if $d->{'_order'};
  }
  return @k unless $order;
  my %k = map {$_ => 1} @k;
  my @ko;
  for (@$order) {
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
  $d =~ s/([\"\\\000-\037])/$specialescapes{$1} || sprintf('\\u%04x', ord($1))/ge;
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
  my $template = delete $opts{'template'};
  $opts{'_type'} ||= $template if $template && !ref($template);
  undef $template unless ref($template) eq 'HASH';
  if (ref($d) eq 'ARRAY') {
    return '[]' unless @$d;
    $opts{'template'} = $template if $template;
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
    my $keepspecial = $opts{'keepspecial'};
    my @k = unparse_keys($d, $template ? $template->{'_order'} : undef, $keepspecial);
    return '{}' unless @k;
    my $indent = $opts{'ugly'} ? '' : $opts{'indent'} || '';
    my $nl = $opts{'ugly'} ? '' : "\n";
    my $sp = $opts{'ugly'} ? '' : " ";
    my $first = 0;
    for my $k (@k) {
      $opts{'template'} = $template->{$k} || $template->{'*'} if $template;
      $r .= ",$nl" if $first++;
      my $dd = $d->{$k};
      my $type = $keepspecial ? undef : $d->{'_type'};
      $r .= "$indent$sp$sp$sp".unparse_string($k)."$sp:$sp".unparse($dd, %opts, 'indent' => "   $indent", '_type' => ($type || {})->{$k});
    }
    return "\{$nl$r$nl$indent\}";
  }
  return 'null' unless defined $d;
  my $type = $opts{'_type'} || '';
  return unparse_bool($d) if $type eq 'bool';
  return unparse_number($d) if $type eq 'number';
  return unparse_string($d);
}


# reverse of specialescapes, with \u and \<nl> added
my %specialescapes_parse = (
  '\\"' => '"',
  '\\\\' => '\\',
  '\\/' => '/',
  '\\b' => "\b",
  '\\f' => "\f",
  '\\n' => "\n",
  '\\r' => "\r",
  '\\t' => "\t",
  "\\\n" => "\n",
  '\\u' => 'u',
);

sub parse {
  my ($c, %opts) = @_;

  my ($record, $order, $type, $bytes) = ($opts{'record'}, $opts{'order'}, $opts{'type'}, $opts{'bytes'});
  my $origlen = length($c);
  my @q;
  my ($v, $t);					# value, type
  while (1) {
    substr($c, 0, length($1), '') while substr($c, 0, 16) =~ /\A([ \t\r\n]+)/s;
    my $fc = substr($c, 0, 1, '');
    die("malformed JSON: key must be of type 'string'\n") if @q && $q[-1] eq '}' && $fc ne '"' && $fc ne '}';
    ($v, $t) = (undef, undef);
    if ($fc eq '"') {				# string
      $v = '';
      while (1) {
        my $idx = index($c, '"');
        die("malformed JSON: unterminated string\n") unless $idx >= 0;
	my $vv = substr($c, 0, $idx);
        if (($idx = index($vv, '\\')) < 0) {
	  $v .= $vv;
          substr($c, 0, length($vv) + 1, '');
	  last;
	}
        $v .= substr($c, 0, $idx, '');
        my $r = $specialescapes_parse{substr($c, 0, 2, '')};
        die("malformed JSON: unknown string escape\n") unless defined $r;
	if ($r eq 'u') {
          die("malformed JSON: bad unicode escape\n") unless substr($c, 0, 4) =~ /\A([0-9a-fA-F]{4})/s;
          $r = hex($1);
          substr($c, 0, 4, '');
	  if ($r >= 0xd800 && $r < 0xdc00) {
            die("malformed JSON: bad unicode surrogate escape\n") unless substr($c, 0, 6) =~ /\A\\u([0-9a-fA-F]{4})/s;
            my $r2 = hex($1);
            substr($c, 0, 6, '');
            die("malformed JSON: bad unicode surrogate escape\n") unless $r2 >= 0xdc00 && $r2 <= 0xe000;
	    $r = 0x10000 + (($r & 0x3ff) << 10 | ($r2 & 0x3ff));
	  }
	  $r = $bytes ? pack('C0U', $r) : chr($r);
	}
	$v .= $r;
      }
    } elsif ($fc eq '[') {			# array
      push @q, [], ']';
      next;
    } elsif ($fc eq '{') {			# hash
      push @q, {}, '}';
      $q[-2]->{'_start'} =  $origlen - (1 + length($c)) if $record;
      next;
    } elsif ($fc eq ']' || $fc eq '}') {	# array/hash end
      die("malformed JSON: unexpected '$fc'\n") unless @q && $q[-1] eq $fc;
      ($v) = splice(@q, -2);
      $v->{'_end'} = $origlen - length($c) if $record && $fc eq '}';
    } elsif ($fc =~ /\A[0-9\+\-\.]/) {		# number
      $t = 'number';
      $v = $fc;
      $v .= substr($c, 0, length($1), '') while substr($c, 0, 16) =~ /\A([0-9\+\-\.eE]+)/s;
    } elsif ($fc =~ /\A[a-z]/) {		# literal
      $v = $fc;
      $v .= substr($c, 0, length($1), '') while substr($c, 0, 16) =~ /\A([a-z]+)/s;
      if ($v eq 'null') {
	$v = undef;
      } elsif ($v eq 'true' || $v eq 'false') {
        $t = 'bool';
	$v = $v eq 'true' ? 1 : 0;
      } else {
        die("malformed JSON: unknown literal '$v'\n");
      }
    } else {
      die("malformed JSON\n");
    }
    substr($c, 0, length($1), '') while substr($c, 0, 16) =~ /\A([ \t\r\n]+)/s;
    last unless @q;
    if ($q[-1] eq '}') {
      $fc = substr($c, 0, 1, '');
      die("malformed JSON: expected ':'\n") unless $fc eq ':';
      push @q, $v, '{';
    } elsif ($q[-1] eq '{') {
      my ($key) = splice(@q, -2);
      $q[-2]->{$key} = $v;
      $q[-2]->{'_type'}->{$key} = $t if $type && $t;
      push @{$q[-2]->{'_order'}}, $key if $order;
      $fc = substr($c, 0, 1);
      die("malformed JSON: expected '}' or ','\n") unless $fc eq ',' || $fc eq '}';
      substr($c, 0, 1, '') if $fc eq ',';
    } elsif ($q[-1] eq ']') {
      push @{$q[-2]}, $v;
      $fc = substr($c, 0, 1);
      die("malformed JSON: expected ']' or ','\n") unless $fc eq ',' || $fc eq ']';
      substr($c, 0, 1, '') if $fc eq ',';
    } else {
      die("malformed JSON: internal error\n");
    }
  }
  die("malformed JSON: trailing data\n") if $c ne '';
  return $v;
}

1;
