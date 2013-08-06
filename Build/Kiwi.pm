package Build::Kiwi;

use strict;
use version;

our $bootcallback;

# worst xml parser ever, just good enough to parse those kiwi files...
# can't use standard XML parsers, unfortunatelly, as the build script
# must not rely on external libraries
#
sub parsexml {
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

sub unify {
  my %h = map {$_ => 1} @_;
  return grep(delete($h{$_}), @_);
}

sub findFallBackArchs {
  my ($fallbackArchXML, $arch) = @_;
  my @fa;

  for my $a (@{$fallbackArchXML->{'arch'}||[]}) {
    if ( $a->{'id'} eq $arch && $a->{'fallback'} ) {
      @fa = unify( $a->{'fallback'}, findFallBackArchs($fallbackArchXML, $a->{'fallback'}));
    }
  }

  return @fa
}

sub kiwiparse {
  my ($xml, $arch, $count) = @_;
  $count ||= 0;
  die("kiwi config inclusion depth limit reached\n") if $count++ > 10;

  my $ret = {};
  my @types;
  my @repos;
  my @bootrepos;
  my @packages;
  my @extrasources;
  my @requiredarch;
  my $schemaversion = 0;
  my $schemaversion56 = version->parse("5.6");
  my $kiwi = parsexml($xml);
  die("not a kiwi config\n") unless $kiwi && $kiwi->{'image'};
  $kiwi = $kiwi->{'image'}->[0];
  $schemaversion = version->parse($kiwi->{'schemaversion'}) if $kiwi->{'schemaversion'}; 
  $ret->{'filename'} = $kiwi->{'name'} if $kiwi->{'name'};
  my $description = (($kiwi->{'description'} || [])->[0]) || {};
  if ($description->{'specification'}) {
    $ret->{'name'} = $description->{'specification'}->[0]->{'_content'};
  }
  # take default version setting
  my $preferences = ($kiwi->{'preferences'} || []);
  if ($preferences->[0]->{'version'}) {
    $ret->{'version'} = $preferences->[0]->{'version'}->[0]->{'_content'};
  }
  for my $pref (@{$preferences || []}) {
    for my $type (@{$pref->{'type'} || []}) {
      next unless @{$pref->{'type'}} == 1 || !$type->{'optional'};
      if (defined $type->{'image'}) {
        # for kiwi 4.1 and 5.x
        push @types, $type->{'image'};
        push @packages, "kiwi-image:$type->{'image'}" if $schemaversion >= $schemaversion56;
      } else {
        # for kiwi 3.8 and before
        push @types, $type->{'_content'};
        push @packages, "kiwi-filesystem:$type->{'filesystem'}" if $type->{'filesystem'};
      }
      if (defined $type->{'boot'}) {
        if ($type->{'boot'} =~ /^obs:\/\/\/?([^\/]+)\/([^\/]+)\/?$/) {
          next unless $bootcallback;
          my ($bootxml, $xsrc) = $bootcallback->($1, $2);
          next unless $bootxml;
          push @extrasources, $xsrc if $xsrc;
          my $bret = kiwiparse($bootxml, $arch, $count);
          push @bootrepos, map {"$_->{'project'}/$_->{'repository'}"} @{$bret->{'path'} || []};
          push @packages, @{$bret->{'deps'} || []};
          push @extrasources, @{$bret->{'extrasource'} || []};
        } else {
          die("bad boot reference: $type->{'boot'}\n") unless $type->{'boot'} =~ /^([^\/]+)\/([^\/]+)$/;
          push @packages, "kiwi-boot:$1";
        }
      }
    }
  }

  my $instsource = ($kiwi->{'instsource'} || [])->[0];
  if ($instsource) {
    foreach my $repository(sort {$a->{priority} <=> $b->{priority}} @{$instsource->{'instrepo'} || []}) {
      my $kiwisource = ($repository->{'source'} || [])->[0];
      if ($kiwisource->{'path'} eq 'obsrepositories:/') {
         # special case, OBS will expand it.
         push @repos, '_obsrepositories';
         next;
      }
      die("bad instsource path: $kiwisource->{'path'}\n") unless $kiwisource->{'path'} =~ /^obs:\/\/\/?([^\/]+)\/([^\/]+)\/?$/;
      push @repos, "$1/$2";
    }
    if ($instsource->{'productoptions'}) {
      my $productoptions = $instsource->{'productoptions'}->[0] || {};
      for my $po (@{$productoptions->{'productvar'} || []}) {
	$ret->{'version'} = $po->{'_content'} if $po->{'name'} eq 'VERSION';
      }
    }
    if ($instsource->{'architectures'}) {
      my $a = $instsource->{'architectures'}->[0] || {};
      for my $ra (@{$a->{'requiredarch'} || []}) {
	push @requiredarch, $ra->{'ref'} if defined $ra->{'ref'};
      }
    }
  }

  # set default values for priority
  for (@{$kiwi->{'repository'} || []}) {
    next if defined $_->{'priority'};
    if ($preferences->[0]->{'packagemanager'}->[0]->{'_content'} eq 'smart') {
       $_->{'priority'} = 0;
    } else {
       $_->{'priority'} = 99;
    }
  }
  my @repositories = sort {$a->{'priority'} <=> $b->{'priority'}} @{$kiwi->{'repository'} || []};
  if ($preferences->[0]->{'packagemanager'}->[0]->{'_content'} eq 'smart') {
    @repositories = reverse @repositories;
  }
  for my $repository (@repositories) {
    my $kiwisource = ($repository->{'source'} || [])->[0];
    next if $kiwisource->{'path'} eq '/var/lib/empty';	# grr
    if ($kiwisource->{'path'} eq 'obsrepositories:/') {
      push @repos, '_obsrepositories';
      next;
    };
    die("bad path using not obs:/ URL: $kiwisource->{'path'}\n") unless $kiwisource->{'path'} =~ /^obs:\/\/\/?([^\/]+)\/([^\/]+)\/?$/;
    push @repos, "$1/$2";
  }

  # Find packages and possible additional required architectures
  my @additionalarchs;
  my @pkgs;
  for my $packages (@{$kiwi->{'packages'}}) {
    next if $packages->{'type'} and $packages->{'type'} ne 'image' and $packages->{'type'} ne 'bootstrap';
    push @pkgs, @{$packages->{'package'}} if $packages->{'package'};
  }
  if ($instsource) {
    push @pkgs, @{$instsource->{'metadata'}->[0]->{'repopackage'} || []} if $instsource->{'metadata'};
    push @pkgs, @{$instsource->{'repopackages'}->[0]->{'repopackage'} || []} if $instsource->{'repopackages'};
  }
  @pkgs = unify(@pkgs);
  for my $package (@pkgs) {
    # filter packages, which are not targeted for the wanted plattform
    if ($package->{'arch'}) {
      my $valid=undef;
      if (@requiredarch) {
        # this is a product
        foreach my $ma(@requiredarch) {
          foreach my $pa(split(",", $package->{'arch'})) {
            $valid = 1 if $ma eq $pa;
          }
        }
      } else {
        # live appliance
        my $ma = $arch;
        $ma =~ s/i[456]86/i386/;
        foreach my $pa(split(",", $package->{'arch'})) {
          $pa =~ s/i[456]86/i386/;
          $valid = 1 if $ma eq $pa;
        }
      }
      next unless $valid;
    }

    # not nice, but optimizes our build dependencies
    # FIXME: design a real blacklist option in kiwi
    if ($package->{'onlyarch'} && $package->{'onlyarch'} eq "skipit") {
       push @packages, "-".$package->{'name'};
       next;
    }

    # we need this package
    push @packages, $package->{'name'};

    # find the maximal superset of possible required architectures
    push @additionalarchs, split(',', $package->{'addarch'}) if $package->{'addarch'};
    push @additionalarchs, split(',', $package->{'onlyarch'}) if $package->{'onlyarch'};
  }
  @requiredarch = unify(@requiredarch, @additionalarchs);

  #### FIXME: kiwi files have no informations where to get -32bit packages from
  push @requiredarch, "i586" if grep {/^ia64/} @requiredarch;
  push @requiredarch, "i586" if grep {/^x86_64/} @requiredarch;
  push @requiredarch, "ppc" if grep {/^ppc64/} @requiredarch;
  push @requiredarch, "s390" if grep {/^s390x/} @requiredarch;
  
  my @fallbackarchs;
  for my $arch (@requiredarch) {
    push @fallbackarchs, findFallBackArchs($instsource->{'architectures'}[0], $arch) if $instsource->{'architectures'}[0];
  }
  @requiredarch = unify(@requiredarch, @fallbackarchs);

  if (!$instsource) {
    my $packman = $preferences->[0]->{'packagemanager'}->[0]->{'_content'};
    push @packages, "kiwi-packagemanager:$packman";
  } else {
    push @packages, "kiwi-packagemanager:instsource";
  }

  $ret->{'exclarch'} = [ unify(@requiredarch) ] if @requiredarch;
  $ret->{'deps'} = [ unify(@packages) ];
  $ret->{'path'} = [ unify(@repos, @bootrepos) ];
  $ret->{'imagetype'} = [ unify(@types) ];
  $ret->{'extrasource'} = \@extrasources if @extrasources;
  for (@{$ret->{'path'}}) {
    my @s = split('/', $_, 2);
    $_ = {'project' => $s[0], 'repository' => $s[1]};
  }
  return $ret;
}

sub parse {
  my ($cf, $fn) = @_;

  local *F;
  open(F, '<', $fn) || die("$fn: $!\n");
  my $xml = '';
  1 while sysread(F, $xml, 4096, length($xml)) > 0;
  close F;
  $cf ||= {};
  my $d;
  eval {
    $d = kiwiparse($xml, ($cf->{'arch'} || ''));
  };
  if ($@) {
    my $err = $@;
    $err =~ s/^\n$//s;
    return {'error' => $err};
  }
  return $d;
}

sub show {
  my ($fn, $field, $arch) = @ARGV;
  my $cf = {'arch' => $arch};
  my $d = parse($cf, $fn);
  die("$d->{'error'}\n") if $d->{'error'};
  my $x = $d->{$field};
  $x = [ $x ] unless ref $x;
  print "@$x\n";
}

# not implemented yet.
sub queryiso {
  my ($handle, %opts) = @_;
  return {};
}


sub queryhdrmd5 {
  my ($bin) = @_;
  die("Build::Kiwi::queryhdrmd5 unimplemented.\n");
}

1;
