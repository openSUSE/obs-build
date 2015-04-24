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
