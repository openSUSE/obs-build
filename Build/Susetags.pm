package Build::Susetags;

use strict;
use warnings;
use Data::Dumper;

sub addpkg {
  my ($pkgs, $cur, $order, $cb, $cbdata, @arches) = @_;
  if (defined($cur) && (!@arches || grep { /$cur->{'arch'}/ } @arches)) {
    if(!$cb || &$cb($cur, $cbdata)) {
      my $k = "$cur->{'name'}-$cur->{'version'}-$cur->{'release'}-$cur->{'arch'}";
      $pkgs->{$k} = $cur;
      # keep order (or should we use Tie::IxHash?)
      push @{$order}, $k if defined $order;
    }
  }
}

sub parse {
  # if @arches is empty take all arches
  my ($file, $tmap, $order, @arches) = @_;
  my $cb;
  my $cbdata;
  if (ref $order eq 'HASH') {
    my $d = $order;
    $order = undef;
    $cb = $d->{'cb'} if (exists $d->{'cb'});
    $cbdata = $d->{'data'} if (exists $d->{'data'});
  }

  # if @arches is empty take all arches
  my @needed = keys %$tmap;
  my $r = '(' . join('|', @needed) . '|Pkg):\s*(.*)';

  if (!open(F, '<', $file)) {
    if (!open(F, '-|', "gzip", "-dc", $file.'.gz')) {
      die "$file: $!";
    }
  }

  my $cur;
  my $pkgs = {};
  while (<F>) {
    chomp;
    next unless $_ =~ /([\+=])$r/;
    my ($multi, $tag, $data) = ($1, $2, $3);
    if ($multi eq '+') {
      while (<F>) {
	chomp;
	last if $_ =~ /-$tag/;
	push @{$cur->{$tmap->{$tag}}}, $_;
      }
    } elsif ($tag eq 'Pkg') {
      addpkg($pkgs, $cur, $order, $cb, $cbdata, @arches);
      $cur = {};
      ($cur->{'name'}, $cur->{'version'}, $cur->{'release'}, $cur->{'arch'}) = split(' ', $data);
    } else {
      $cur->{$tmap->{$tag}} = $data;
    }
  }
  addpkg($pkgs, $cur, $order, $cb, $cbdata, @arches);
  close(F);
  return $pkgs;
}

1;
