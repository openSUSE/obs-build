################################################################
#
# Copyright (c) 1995-2016 SUSE Linux Products GmbH
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

package Build::SimpleXML;

use strict;

# very simple xml parser, just good enough to parse kiwi and _service files...
# can't use standard XML parsers, unfortunatelly, as the build script
# must not rely on external libraries
#
sub parse {
  my ($xml, %opts) = @_;

  my $record = $opts{'record'};
  my $order = $opts{'order'};
  my @nodestack;
  my $node = {};
  my $c = '';
  my $xmllen = length($xml);
  $xml =~ s/^\s*\<\?.*?\?\>//s;
  while ($xml =~ /^(.*?)\</s) {
    if ($1 ne '') {
      $c .= $1;
      $xml = substr($xml, length($1));
    }
    if (substr($xml, 0, 4) eq '<!--') {
      die("bad xml, missing end of comment\n") unless $xml =~ s/.*?-->//s;
      next;
    }
    my $elstart = length($xml);
    die("bad xml\n") unless $xml =~ /(.*?\>)/s;
    my $tag = $1;
    $xml = substr($xml, length($tag));
    my $mode = 0;
    if ($tag =~ s/^\<\///s) {
      chop $tag;
      $mode = 1;	# end
    } elsif ($tag =~ s/\/\>$//s) {
      $mode = 2;	# start & end
      $tag = substr($tag, 1);
    } else {
      $tag = substr($tag, 1);
      chop $tag;
    }
    my @tag = split(/(=(?:\"[^\"]*\"|\'[^\']*\'|[^\"\s]*))?\s+/, "$tag ");
    $tag = shift @tag;
    shift @tag;
    push @tag, undef if @tag & 1;
    my %atts = @tag;
    for (values %atts) {
      next unless defined $_;
      s/^=\"([^\"]*)\"$/=$1/s or s/^=\'([^\']*)\'$/=$1/s;
      s/^=//s;
      s/&lt;/</g;
      s/&gt;/>/g;
      s/&amp;/&/g;
      s/&apos;/\'/g;
      s/&quot;/\"/g;
    }
    if ($mode == 0 || $mode == 2) {
      my $n = {};
      if ($record) {
        $n->{'_start'} = $xmllen - $elstart;
        $n->{'_end'} = $xmllen - length($xml) if $mode == 2;
      }
      if ($order) {
        push @{$node->{'_order'}}, $tag;
        push @{$n->{'_order'}}, (splice(@tag, 0, 2))[0] while @tag;
      }
      push @{$node->{$tag}}, $n;
      $n->{$_} = $atts{$_} for sort keys %atts;
      if ($mode == 0) {
	push @nodestack, [ $tag, $node, $c ];
	$c = '';
	$node = $n;
      }
    } else {
      die("element '$tag' closes without open\n") unless @nodestack;
      die("element '$tag' closes, but I expected '$nodestack[-1]->[0]'\n") unless $nodestack[-1]->[0] eq $tag;
      $c =~ s/^\s*//s;
      $c =~ s/\s*$//s;
      $node->{'_content'} = $c if $c ne '';
      $node->{'_end'} = $xmllen - length($xml) if $record;
      $node = $nodestack[-1]->[1];
      $c = $nodestack[-1]->[2];
      pop @nodestack;
    }
  }
  $c .= $xml;
  $c =~ s/^\s*//s;
  $c =~ s/\s*$//s;
  $node->{'_content'} = $c if $c ne '';
  return $node;
}

sub unparse_keys {
  my ($d) = @_;
  my @k = grep {$_ ne '_start' && $_ ne '_end' && $_ ne '_order' && $_ ne '_content'} sort keys %$d;
  return @k unless $d->{'_order'};
  my %k = map {$_ => 1} @k;
  my @ko;
  for (@{$d->{'_order'}}) {
    push @ko, $_ if delete $k{$_};
  }
  return (@ko, grep {$k{$_}} @k);
}

sub unparse_escape {
  my ($d) = @_;
  $d =~ s/&/&amp;/sg;
  $d =~ s/</&lt;/sg;
  $d =~ s/>/&gt;/sg;
  $d =~ s/"/&quot;/sg;
  return $d;
}

sub unparse {
  my ($d, %opts) = @_;

  my $r = '';
  my $indent = $opts{'ugly'} ? '' : $opts{'indent'} || '';
  my $nl = $opts{'ugly'} ? '' : "\n";
  my @k = unparse_keys($d);
  my @e = grep {ref($d->{$_}) ne ''} @k;
  for my $e (@e) {
    my $en = unparse_escape($e);
    my $de = $d->{$e};
    $de = [ $de ] unless ref($de) eq 'ARRAY';
    for my $se (@$de) {
      if (ref($se) eq '') {
	$r .= "$indent<$en>".unparse_escape($se)."</$en>$nl";
	next;
      }
      my @sk = unparse_keys($se);
      my @sa = grep {ref($se->{$_}) eq ''} @sk;
      my @se = grep {ref($se->{$_}) ne ''} @sk;
      $r .= "$indent<$en";
      for my $sa (@sa) {
	$r .= " ".unparse_escape($sa);
	$r .= '="'.unparse_escape($se->{$sa}).'"' if defined $se->{$sa};
      }
      $r .= ">";
      $r .= unparse_escape($se->{'_content'}) if defined $se->{'_content'};
      $r .= $nl . unparse($se, %opts, 'indent' => "  $indent") . "$indent" if @se;
      $r .= "</$en>$nl";
    }
  }
  return $r;
}

1;
