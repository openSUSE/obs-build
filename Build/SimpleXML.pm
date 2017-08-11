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
  my ($xml) = @_;

  my @nodestack;
  my $node = {};
  my $c = '';
  $xml =~ s/^\s*\<\?.*?\?\>//s;
  while ($xml =~ /^(.*?)\</s) {
    if ($1 ne '') {
      $c .= $1;
      $xml = substr($xml, length($1));
    }
    if (substr($xml, 0, 4) eq '<!--') {
      die("bad xml, missing end of comment") unless $xml =~ /.*?-->/s;
      $xml =~ s/.*?-->//s;
      next;
    }
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
      push @{$node->{$tag}}, $n;
      for (sort keys %atts) {
	$n->{$_} = $atts{$_};
      }
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

1;
