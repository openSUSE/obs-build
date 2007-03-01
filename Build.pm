
package Build;

our $expand_dbg;

use strict;
use Digest::MD5;

use Build::Rpm;
use Build::Deb;

my $std_macros = q{
%define ix86 i386 i486 i586 i686 athlon
%define arm armv4l armv4b armv5l armv5b armv5tel armv5teb
%define arml armv4l armv5l armv5tel
%define armb armv4b armv5b armv5teb
};

sub unify {
  my %h = map {$_ => 1} @_;
  return grep(delete($h{$_}), @_);
}

sub read_config_dist {
  my ($dist, $archpath, $configdir) = @_;

  my $arch = $archpath;
  $arch = 'noarch' unless defined $arch;
  $arch =~ s/:.*//;
  $arch = 'noarch' if $arch eq '';
  die("Please specify a distribution!\n") unless defined $dist;
  if ($dist !~ /\//) {
    $configdir = '.' unless defined $configdir;
    $dist =~ s/-.*//;
    $dist = "sl$dist" if $dist =~ /^\d/;
    $dist = "$configdir/$dist.conf";
    $dist = "$configdir/default.conf" unless -e $dist;
  }
  die("$dist: $!\n") unless -e $dist;
  my $cf = read_config($arch, $dist);
  die("$dist: parse error\n") unless $cf;
  return $cf;
}

sub read_config {
  my ($arch, $cfile) = @_;
  my @macros = split("\n", $std_macros);
  push @macros, "%define _target_cpu $arch";
  push @macros, "%define _target_os linux";
  my $config = {'macros' => \@macros};
  my @config;
  if (ref($cfile)) {
    @config = @$cfile;
  } elsif (defined($cfile)) {
    local *CONF;
    return undef unless open(CONF, '<', $cfile);
    @config = <CONF>;
    close CONF;
    chomp @config;
  }
  # create verbatim macro blobs
  my @newconfig;
  while (@config) {
    push @newconfig, shift @config;
    next unless $newconfig[-1] =~ /^\s*macros:\s*$/si;
    $newconfig[-1] = "macros:\n";
    while (@config) {
      my $l = shift @config;
      last if $l =~ /^\s*:macros\s*$/si;
      $newconfig[-1] .= "$l\n";
    }
  }
  my @spec;
  Build::Rpm::parse($config, \@newconfig, \@spec);
  $config->{'preinstall'} = [];
  $config->{'runscripts'} = [];
  $config->{'required'} = [];
  $config->{'support'} = [];
  $config->{'keep'} = [];
  $config->{'prefer'} = [];
  $config->{'ignore'} = [];
  $config->{'conflict'} = [];
  $config->{'substitute'} = {};
  $config->{'optflags'} = {};
  $config->{'rawmacros'} = '';
  $config->{'repotype'} = [];
  for my $l (@spec) {
    $l = $l->[1] if ref $l;
    next unless defined $l;
    my @l = split(' ', $l);
    next unless @l;
    my $ll = shift @l;
    my $l0 = lc($ll);
    if ($l0 eq 'macros:') {
      $l =~ s/.*?\n//s;
      $config->{'rawmacros'} .= $l;
      next;
    }
    if ($l0 eq 'preinstall:' || $l0 eq 'required:' || $l0 eq 'support:' || $l0 eq 'keep:' || $l0 eq 'prefer:' || $l0 eq 'ignore:' || $l0 eq 'conflict:' || $l0 eq 'runscripts:') {
      push @{$config->{substr($l0, 0, -1)}}, @l;
    } elsif ($l0 eq 'substitute:') {
      next unless @l;
      $ll = shift @l;
      push @{$config->{'substitute'}->{$ll}}, @l;
    } elsif ($l0 eq 'optflags:') {
      next unless @l;
      $ll = shift @l;
      $config->{'optflags'}->{$ll} = join(' ', @l);
    } elsif ($l0 eq 'repotype:') {
      $config->{'repotype'} = [ @l ];
    } elsif ($l0 !~ /^[#%]/) {
      warn("unknown keyword in config: $l0\n");
    }
  }
  for my $l (qw{preinstall required support keep runscripts repotype}) {
    $config->{$l} = [ unify(@{$config->{$l}}) ];
  }
  for my $l (keys %{$config->{'substitute'}}) {
    $config->{'substitute'}->{$l} = [ unify(@{$config->{'substitute'}->{$l}}) ];
  }
  $config->{'preferh'} = { map {$_ => 1} @{$config->{'prefer'}} };
  my %ignore;
  for (@{$config->{'ignore'}}) {
    if (!/:/) {
      $ignore{$_} = 1;
      next;
    }
    my @s = split(/[,:]/, $_);
    my $s = shift @s;
    $ignore{"$s:$_"} = 1 for @s;
  }
  $config->{'ignoreh'} = \%ignore;
  my %conflicts;
  for (@{$config->{'conflict'}}) {
    my @s = split(/[,:]/, $_);
    my $s = shift @s;
    push @{$conflicts{$s}}, @s;
    push @{$conflicts{$_}}, $s for @s;
  }
  for (keys %conflicts) {
    $conflicts{$_} = [ unify(@{$conflicts{$_}}) ]
  }
  $config->{'conflicth'} = \%conflicts;
  $config->{'type'} = (grep {$_ eq 'rpm'} @{$config->{'preinstall'} || []}) ? 'spec' : 'dsc';
  # add rawmacros to our macro list
  if ($config->{'rawmacros'} ne '') {
    for my $rm (split("\n", $config->{'rawmacros'})) {
      if ((@macros && $macros[-1] =~ /\\$/) || $rm !~ /^%/) {
	push @macros, $rm;
      } else {
	push @macros, "%define ".substr($rm, 1);
      }
    }
  }
  return $config;
}

sub do_subst {
  my ($config, @deps) = @_;
  my @res;
  my %done;
  my $subst = $config->{'substitute'};
  while (@deps) {
    my $d = shift @deps;
    next if $done{$d};
    if ($subst->{$d}) {
      unshift @deps, @{$subst->{$d}};
      push @res, $d if grep {$_ eq $d} @{$subst->{$d}};
    } else {
      push @res, $d;
    }
    $done{$d} = 1;
  }
  return @res;
}

sub get_build {
  my ($config, $subpacks, @deps) = @_;
  my @ndeps = grep {/^-/} @deps;
  my %keep = map {$_ => 1} (@deps, @{$config->{'keep'} || []}, @{$config->{'preinstall'}});
  for (@{$subpacks || []}) {
    push @ndeps, "-$_" unless $keep{$_};
  }
  my %ndeps = map {$_ => 1} @ndeps;
  @deps = grep {!$ndeps{$_}} @deps;
  push @deps, @{$config->{'preinstall'}};
  push @deps, @{$config->{'required'}};
  push @deps, @{$config->{'support'}};
  @deps = grep {!$ndeps{"-$_"}} @deps;
  @deps = do_subst($config, @deps);
  @deps = grep {!$ndeps{"-$_"}} @deps;
  @deps = expand($config, @deps, @ndeps);
  return @deps;
}

sub get_deps {
  my ($config, $subpacks, @deps) = @_;
  my @ndeps = grep {/^-/} @deps;
  my %keep = map {$_ => 1} (@deps, @{$config->{'keep'} || []}, @{$config->{'preinstall'}});
  for (@{$subpacks || []}) {
    push @ndeps, "-$_" unless $keep{$_};
  }
  my %ndeps = map {$_ => 1} @ndeps;
  @deps = grep {!$ndeps{$_}} @deps;
  push @deps, @{$config->{'required'}};
  @deps = grep {!$ndeps{"-$_"}} @deps;
  @deps = do_subst($config, @deps);
  @deps = grep {!$ndeps{"-$_"}} @deps;
  my %bdeps = map {$_ => 1} (@{$config->{'preinstall'}}, @{$config->{'support'}});
  delete $bdeps{$_} for @deps;
  @deps = expand($config, @deps, @ndeps);
  if (@deps && $deps[0]) {
    my $r = shift @deps;
    @deps = grep {!$bdeps{$_}} @deps;
    unshift @deps, $r;
  }
  return @deps;
}

sub get_preinstalls {
  my ($config) = @_;
  return @{$config->{'preinstall'}};
}

sub get_runscripts {
  my ($config) = @_;
  return @{$config->{'runscripts'}};
}

###########################################################################

sub readdeps {
  my ($config, $pkgidp, @depfiles) = @_;

  my %provides = ();
  my %requires = ();
  local *F;
  my %prov;
  for my $depfile (@depfiles) {
    if (ref($depfile) eq 'HASH') {
      for my $rr (keys %$depfile) {
	$prov{$rr} = $depfile->{$rr}->{'provides'};
	$requires{$rr} = $depfile->{$rr}->{'requires'};
      }
      next;
    }
    open(F, "<$depfile") || die("$depfile: $!\n");
    while(<F>) {
      my @s = split(' ', $_);
      my $s = shift @s;
      my @ss; 
      while (@s) {
	if ($s[0] =~ /^\//) {
	  shift @s;
	  next;
	}
	if ($s[0] =~ /^rpmlib\(/) {
	  shift @s;
	  shift @s;
	  shift @s;
	  next;
	}
	push @ss, shift @s;
	if (@s && $s[0] =~ /^[<=>]/) {
	  shift @s;
	  shift @s;
	}
      }
      my %ss; 
      @ss = grep {!$ss{$_}++} @ss;
      if ($s =~ s/^P:(.*):$/$1/) {
	my $pkgid = $s;
	$s =~ s/-[^-]+-[^-]+-[^-]+$//;
	$prov{$s} = \@ss; 
	$pkgidp->{$s} = $pkgid if $pkgidp;
      } elsif ($s =~ s/^R:(.*):$/$1/) {
	my $pkgid = $s;
	$s =~ s/-[^-]+-[^-]+-[^-]+$//;
	$requires{$s} = \@ss; 
	$pkgidp->{$s} = $pkgid if $pkgidp;
      }
    }
    close F;
  }
  for my $p (keys %prov) {
    push @{$provides{$_}}, $p for unify(@{$prov{$p}});
  }
  my @ors = grep {/\|/} map {@$_} values %requires;
  @ors = unify(@ors) if @ors > 1;
  for my $or (@ors) {
    my @p = map {@{$provides{$_} || []}} split(/\|/, $or);
    @p = unify(@p) if @p > 1;
    $provides{$or} = \@p;
  }
  $config->{'providesh'} = \%provides;
  $config->{'requiresh'} = \%requires;
}

sub forgetdeps {
  my $config;
  delete $config->{'providesh'};
  delete $config->{'requiresh'};
}

sub expand {
  my ($config, @p) = @_;

  my $conflicts = $config->{'conflicth'};
  my $prefer = $config->{'preferh'};
  my $ignore = $config->{'ignoreh'};

  my $provides = $config->{'providesh'};
  my $requires = $config->{'requiresh'};

  my %xignore = map {substr($_, 1) => 1} grep {/^-/} @p;
  @p = grep {!/^-/} @p;
 
  my %p = map {$_ => 1} grep {$requires->{$_}} @p;

  my %aconflicts;
  for my $p (keys %p) {
    next unless exists $conflicts->{$p};
    $aconflicts{$_} = 1 for @{$conflicts->{$p} || []};
  }

  my @pamb = ();
  my $doamb = 0;
  while (@p) {
    my @error = ();
    my @rerror = ();
    for my $p (splice @p) {
      for my $r (@{$requires->{$p} || [$p]}) {
	next if $ignore->{"$p:$r"} || $xignore{"$p:$r"};
	next if $ignore->{$r} || $xignore{$r};
	my @q = @{$provides->{$r} || []};
	next if grep {$p{$_}} @q;
	next if grep {$xignore{$_}} @q;
	next if grep {$ignore->{"$p:$_"} || $xignore{"$p:$_"}} @q;
	@q = grep {!$aconflicts{$_}} @q;
	if (!@q) {
	  if ($r eq $p) {
	    push @rerror, "nothing provides $r";
	  } else {
	    push @rerror, "nothing provides $r needed by $p";
	  }
	  next;
	}
	if (@q > 1 && !$doamb) {
	  push @pamb, $p unless @pamb && $pamb[-1] eq $p;
	  print "undecided about $p:$r: @q\n" if $expand_dbg;
	  next;
	}
	if (@q > 1) {
	  my @pq = grep {!$prefer->{"-$_"} && !$prefer->{"-$p:$_"}} @q;
	  @q = @pq if @pq;
	  @pq = grep {$prefer->{$_} || $prefer->{"$p:$_"}} @q;
	  if (@pq > 1) {
	    my %pq = map {$_ => 1} @pq;
	    @q = (grep {$pq{$_}} @{$config->{'prefer'}})[0];
	  } elsif (@pq == 1) {
	    @q = @pq;
	  }
	}
	if (@q > 1 && $r =~ /\|/) {
	    # choice op, implicit prefer of first match...
	    my %pq = map {$_ => 1} @q;
	    for my $rr (split(/\|/, $r)) {
		next unless $provides->{$rr};
		my @pq = grep {$pq{$_}} @{$provides->{$rr}};
		next unless @pq;
		@q = @pq;
		last;
	    }
	}
	if (@q > 1) {
	  if ($r ne $p) {
	    push @error, "have choice for $r needed by $p: @q";
          } else {
	    push @error, "have choice for $r: @q";
          }
	  push @pamb, $p unless @pamb && $pamb[-1] eq $p;
	  next;
	}
	push @p, $q[0];
	print "added $q[0] because of $p:$r\n" if $expand_dbg;
	$p{$q[0]} = 1;
	$aconflicts{$_} = 1 for @{$conflicts->{$q[0]} || []};
	@error = ();
	$doamb = 0;
      }
    }
    return undef, @rerror if @rerror;
    next if @p;		# still work to do

    # only ambig stuff left
    if (@pamb && !$doamb) {
      @p = @pamb;
      @pamb = ();
      $doamb = 1;
      print "now doing undecided dependencies\n" if $expand_dbg;
      next;
    }
    return undef, @error if @error;
  }
  return 1, (sort keys %p);
}

sub add_all_providers {
  my ($config, @p) = @_;
  my $provides = $config->{'providesh'};
  my $requires = $config->{'requiresh'};
  my %a;
  for my $p (@p) {
    for my $r (@{$requires->{$p} || [$p]}) {
      $a{$_} = 1 for @{$provides->{$r} || []};
    }
  }
  push @p, keys %a;
  return unify(@p);
}

###########################################################################

sub parse {
  my ($cf, $fn, @args) = @_;
  return Build::Rpm::parse($cf, $fn, @args) if $fn =~ /\.spec$/;
  return Build::Deb::parse($cf, $fn, @args) if $fn =~ /\.dsc$/;
  return undef;
}

sub query {
  my ($binname, $withevra) = @_;
  my $handle = $binname;
  if (ref($binname) eq 'ARRAY') {
    $handle = $binname->[1];
    $binname = $binname->[0];
  }
  return Build::Rpm::query($handle, $withevra) if $binname =~ /\.rpm$/;
  return Build::Deb::query($handle, $withevra) if $binname =~ /\.deb$/;
  return undef;
}

sub queryhdrmd5 {
  my ($binname) = @_;
  return Build::Rpm::queryhdrmd5($binname) if $binname =~ /\.rpm$/;
  return Build::Deb::queryhdrmd5($binname) if $binname =~ /\.deb$/;
  return undef;
}

1;
