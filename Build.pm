package Build;

use strict;
use Digest::MD5;
use Build::Rpm;
use Data::Dumper;

our $expand_dbg;

our $do_rpm;
our $do_deb;
our $do_kiwi;

sub import {
  for (@_) {
    $do_rpm = 1 if $_ eq ':rpm';
    $do_deb = 1 if $_ eq ':deb';
    $do_kiwi = 1 if $_ eq ':kiwi';
  }
  $do_rpm = $do_deb = $do_kiwi = 1 if !$do_rpm && !$do_deb && !$do_kiwi;
  if ($do_deb) {
    require Build::Deb;
  }
  if ($do_kiwi) {
    require Build::Kiwi;
  }
}

my $std_macros = q{
%define nil
%define ix86 i386 i486 i586 i686 athlon
%define arm armv4l armv4b armv5l armv5b armv5el armv5eb armv5tel armv5teb armv6el armv6eb armv7el armv7eb
%define arml armv4l armv5l armv5tel armv5el armv6el armv7el
%define armb armv4b armv5b armv5teb armv5eb armv6eb armv7eb
%define sparc sparc sparcv8 sparcv9 sparcv9v sparc64 sparc64v
};
my $extra_macros = '';

sub unify {
  my %h = map {$_ => 1} @_;
  return grep(delete($h{$_}), @_);
}

sub define($)
{
  my $def = shift;
  $extra_macros .= '%define '.$def."\n";
}

sub init_helper_hashes {
  my ($config) = @_;

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
}

# 'canonicalize' dist string as found in rpm dist tags
sub dist_canon($$) {
  my ($rpmdist, $arch) = @_;
  $rpmdist = lc($rpmdist);
  $rpmdist =~ s/-/_/g;
  $rpmdist =~ s/opensuse/suse linux/;
  my $rpmdista;
  if ($rpmdist =~ /\(/) {
    $rpmdista = $rpmdist;
    $rpmdista =~ s/.*\(//;
    $rpmdista =~ s/\).*//;
  } else {
    $rpmdista = $arch;
  }
  $rpmdista =~ s/i[456]86/i386/;
  $rpmdist = '' unless $rpmdista =~ /^(i386|x86_64|ia64|ppc|ppc64|s390|s390x)$/;
  my $dist = 'default';
  if ($rpmdist =~ /unitedlinux 1\.0.*/) {
    $dist = "ul1-$rpmdista";
  } elsif ($rpmdist =~ /suse sles_(\d+)/) {
    $dist = "sles$1-$rpmdista";
  } elsif ($rpmdist =~ /suse linux enterprise (\d+)/) {
    $dist = "sles$1-$rpmdista";
  } elsif ($rpmdist =~ /suse linux (\d+)\.(\d+)\.[4-9]\d/) {
    # alpha version
    $dist = "$1.".($2 + 1)."-$rpmdista";
  } elsif ($rpmdist =~ /suse linux (\d+\.\d+)/) {
    $dist = "$1-$rpmdista";
  }
  return $dist;
}

sub read_config_dist {
  my ($dist, $archpath, $configdir) = @_;

  my $arch = $archpath;
  $arch = 'noarch' unless defined $arch;
  $arch =~ s/:.*//;
  $arch = 'noarch' if $arch eq '';
  die("Please specify a distribution!\n") unless defined $dist;
  if ($dist !~ /\//) {
    my $saved = $dist;
    $configdir = '.' unless defined $configdir;
    $dist =~ s/-.*//;
    $dist = "sl$dist" if $dist =~ /^\d/;
    $dist = "$configdir/$dist.conf";
    if (! -e $dist) {
      $dist =~ s/-.*//;
      $dist = "sl$dist" if $dist =~ /^\d/;
      $dist = "$configdir/$dist.conf";
    }
    if (! -e $dist) {
      warn "$saved.conf not found, using default.conf\n" unless $saved eq 'default';
      $dist = "$configdir/default.conf";
    }
  }
  die("$dist: $!\n") unless -e $dist;
  my $cf = read_config($arch, $dist);
  die("$dist: parse error\n") unless $cf;
  return $cf;
}

sub read_config {
  my ($arch, $cfile) = @_;
  my @macros = split("\n", $std_macros.$extra_macros);
  push @macros, "%define _target_cpu $arch";
  push @macros, "%define _target_os linux";
  my $config = {'macros' => \@macros, 'arch' => $arch};
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
  $config->{'save_expanded'} = 1;
  Build::Rpm::parse($config, \@newconfig, \@spec);
  delete $config->{'save_expanded'};
  $config->{'preinstall'} = [];
  $config->{'vminstall'} = [];
  $config->{'cbpreinstall'} = [];
  $config->{'cbinstall'} = [];
  $config->{'runscripts'} = [];
  $config->{'required'} = [];
  $config->{'support'} = [];
  $config->{'keep'} = [];
  $config->{'prefer'} = [];
  $config->{'ignore'} = [];
  $config->{'conflict'} = [];
  $config->{'substitute'} = {};
  $config->{'substitute_vers'} = {};
  $config->{'optflags'} = {};
  $config->{'order'} = {};
  $config->{'exportfilter'} = {};
  $config->{'publishfilter'} = [];
  $config->{'rawmacros'} = '';
  $config->{'release'} = '<CI_CNT>.<B_CNT>';
  $config->{'repotype'} = [];
  $config->{'patterntype'} = [];
  $config->{'fileprovides'} = {};
  for my $l (@spec) {
    $l = $l->[1] if ref $l;
    next unless defined $l;
    my @l = split(' ', $l);
    next unless @l;
    my $ll = shift @l;
    my $l0 = lc($ll);
    if ($l0 eq 'macros:') {
      $l =~ s/.*?\n//s;
      if ($l =~ /^!\n/s) {
	$config->{'rawmacros'} = substr($l, 2);
      } else {
	$config->{'rawmacros'} .= $l;
      }
      next;
    }
    if ($l0 eq 'preinstall:' || $l0 eq 'vminstall:' || $l0 eq 'cbpreinstall:' || $l0 eq 'cbinstall:' || $l0 eq 'required:' || $l0 eq 'support:' || $l0 eq 'keep:' || $l0 eq 'prefer:' || $l0 eq 'ignore:' || $l0 eq 'conflict:' || $l0 eq 'runscripts:') {
      my $t = substr($l0, 0, -1);
      for my $l (@l) {
	if ($l eq '!*') {
	  $config->{$t} = [];
	} elsif ($l =~ /^!/) {
	  $config->{$t} = [ grep {"!$_" ne $l} @{$config->{$t}} ];
	} else {
	  push @{$config->{$t}}, $l;
	}
      }
    } elsif ($l0 eq 'substitute:') {
      next unless @l;
      $ll = shift @l;
      if ($ll eq '!*') {
	$config->{'substitute'} = {};
      } elsif ($ll =~ /^!(.*)$/) {
	delete $config->{'substitute'}->{$1};
      } else {
	$config->{'substitute'}->{$ll} = [ @l ];
      }
    } elsif ($l0 eq 'fileprovides:') {
      next unless @l;
      $ll = shift @l;
      if ($ll eq '!*') {
	$config->{'fileprovides'} = {};
      } elsif ($ll =~ /^!(.*)$/) {
	delete $config->{'fileprovides'}->{$1};
      } else {
	$config->{'fileprovides'}->{$ll} = [ @l ];
      }
    } elsif ($l0 eq 'exportfilter:') {
      next unless @l;
      $ll = shift @l;
      $config->{'exportfilter'}->{$ll} = [ @l ];
    } elsif ($l0 eq 'publishfilter:') {
      $config->{'publishfilter'} = [ @l ];
    } elsif ($l0 eq 'optflags:') {
      next unless @l;
      $ll = shift @l;
      $config->{'optflags'}->{$ll} = join(' ', @l);
    } elsif ($l0 eq 'order:') {
      for my $l (@l) {
	if ($l eq '!*') {
	  $config->{'order'} = {};
	} elsif ($l =~ /^!(.*)$/) {
	  delete $config->{'order'}->{$1};
	} else {
	  $config->{'order'}->{$l} = 1;
	}
      }
    } elsif ($l0 eq 'repotype:') { #type of generated repository data
      $config->{'repotype'} = [ @l ];
    } elsif ($l0 eq 'type:') { #kind of packaging system (spec, dsc or kiwi)
      $config->{'type'} = $l[0];
    } elsif ($l0 eq 'patterntype:') { #kind of generated patterns in repository
      $config->{'patterntype'} = [ @l ];
    } elsif ($l0 eq 'release:') {
      $config->{'release'} = $l[0];
    } elsif ($l0 eq 'releaseprg:') {
      $config->{'releaseprg'} = $l[0];
    } elsif ($l0 eq 'changetarget:' || $l0 eq 'target:') {
      $config->{'target'} = join(' ', @l);
    } elsif ($l0 !~ /^[#%]/) {
      warn("unknown keyword in config: $l0\n");
    }
  }
  for my $l (qw{preinstall vminstall cbpreinstall cbinstall required support keep runscripts repotype patterntype}) {
    $config->{$l} = [ unify(@{$config->{$l}}) ];
  }
  for my $l (keys %{$config->{'substitute'}}) {
    $config->{'substitute_vers'}->{$l} = [ map {/^(.*?)(=)?$/g} unify(@{$config->{'substitute'}->{$l}}) ];
    $config->{'substitute'}->{$l} = [ unify(@{$config->{'substitute'}->{$l}}) ];
    s/=$// for @{$config->{'substitute'}->{$l}};
  }
  init_helper_hashes($config);
  if ( ! $config->{'type'}) {
    # Fallback to old guessing method if no type (spec, dsc or kiwi) is defined
    if (grep {$_ eq 'rpm'} @{$config->{'preinstall'} || []}) {
      $config->{'type'} = 'spec';
    } elsif (grep {$_ eq 'debianutils'} @{$config->{'preinstall'} || []}) {
      $config->{'type'} = 'dsc';
    } else {
      $config->{'type'} = 'UNDEFINED';
    }
  }
  # add rawmacros to our macro list
  if ($config->{'rawmacros'} ne '') {
    for my $rm (split("\n", $config->{'rawmacros'})) {
      if (@macros && $macros[-1] =~ /\\$/) {
	if ($rm =~ /\\$/) {
	  push @macros, '...\\';
	} else {
	  push @macros, '...';
	}
      } elsif ($rm !~ /^%/) {
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
    my $ds = $d;
    $ds =~ s/\s*[<=>].*$//s;
    if ($subst->{$ds}) {
      unshift @deps, @{$subst->{$ds}};
      push @res, $d if grep {$_ eq $ds} @{$subst->{$ds}};
    } else {
      push @res, $d;
    }
    $done{$d} = 1;
  }
  return @res;
}

sub do_subst_vers {
  my ($config, @deps) = @_;
  my @res;
  my %done;
  my $subst = $config->{'substitute_vers'};
  while (@deps) {
    my ($d, $dv) = splice(@deps, 0, 2);
    next if $done{$d};
    if ($subst->{$d}) {
      unshift @deps, map {defined($_) && $_ eq '=' ? $dv : $_} @{$subst->{$d}};
      push @res, $d, $dv if grep {defined($_) && $_ eq $d} @{$subst->{$d}};
    } else {
      push @res, $d, $dv;
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

sub get_vminstalls {
  my ($config) = @_;
  return @{$config->{'vminstall'}};
}

sub get_cbpreinstalls {
  my ($config) = @_;
  return @{$config->{'cbpreinstall'}};
}

sub get_cbinstalls {
  my ($config) = @_;
  return @{$config->{'cbinstall'}};
}

sub get_runscripts {
  my ($config) = @_;
  return @{$config->{'runscripts'}};
}

###########################################################################

sub readdeps {
  my ($config, $pkginfo, @depfiles) = @_;

  my %requires = ();
  local *F;
  my %provides;
  my $dofileprovides = %{$config->{'fileprovides'}};
  for my $depfile (@depfiles) {
    if (ref($depfile) eq 'HASH') {
      for my $rr (keys %$depfile) {
	$provides{$rr} = $depfile->{$rr}->{'provides'};
	$requires{$rr} = $depfile->{$rr}->{'requires'};
      }
      next;
    }
    # XXX: we don't support different architectures per file
    open(F, "<$depfile") || die("$depfile: $!\n");
    while(<F>) {
      my @s = split(' ', $_);
      my $s = shift @s;
      my @ss;
      while (@s) {
	if (!$dofileprovides && $s[0] =~ /^\//) {
	  shift @s;
	  next;
	}
	if ($s[0] =~ /^rpmlib\(/) {
	    splice(@s, 0, 3);
	    next;
	}
	push @ss, shift @s;
	while (@s) {
	  if ($s[0] =~ /^[\(<=>|]/) {
	    $ss[-1] .= " $s[0] $s[1]";
	    $ss[-1] =~ s/ \((.*)\)/ $1/;
	    $ss[-1] =~ s/(<|>){2}/$1/;
	    splice(@s, 0, 2);
	  } else {
	    last;
	  }
	}
      }
      my %ss;
      @ss = grep {!$ss{$_}++} @ss;
      if ($s =~ /^(P|R):(.*)\.(.*)-\d+\/\d+\/\d+:$/) {
	my $pkgid = $2;
	my $arch = $3;
	if ($1 eq "R") {
	  $requires{$pkgid} = \@ss;
	  $pkginfo->{$pkgid}->{'requires'} = \@ss if $pkginfo;
	  next;
	}
	# handle provides
	$provides{$pkgid} = \@ss;
	if ($pkginfo) {
	  # extract ver and rel from self provides
	  my ($v, $r) = map { /\Q$pkgid\E = ([^-]+)(?:-(.+))?$/ } @ss;
	  die("$pkgid: no self provides\n") unless $v;
	  $pkginfo->{$pkgid}->{'name'} = $pkgid;
	  $pkginfo->{$pkgid}->{'version'} = $v;
	  $pkginfo->{$pkgid}->{'release'} = $r if defined($r);
	  $pkginfo->{$pkgid}->{'arch'} = $arch;
	  $pkginfo->{$pkgid}->{'provides'} = \@ss;
	}
      }
    }
    close F;
  }
  $config->{'providesh'} = \%provides;
  $config->{'requiresh'} = \%requires;
  makewhatprovidesh($config);
}

sub makewhatprovidesh {
  my ($config) = @_;

  my %whatprovides;
  my $provides = $config->{'providesh'};

  for my $p (keys %$provides) {
    my @pp = @{$provides->{$p}};
    s/[ <=>].*// for @pp;
    push @{$whatprovides{$_}}, $p for unify(@pp);
  }
  for my $p (keys %{$config->{'fileprovides'}}) {
    my @pp = map {@{$whatprovides{$_} || []}} @{$config->{'fileprovides'}->{$p}};
    @{$whatprovides{$p}} = unify(@{$whatprovides{$p} || []}, @pp) if @pp;
  }
  $config->{'whatprovidesh'} = \%whatprovides;
}

sub setdeps {
  my ($config, $provides, $whatprovides, $requires) = @_;
  $config->{'providesh'} = $provides;
  $config->{'whatprovidesh'} = $whatprovides;
  $config->{'requiresh'} = $requires;
}

sub forgetdeps {
  my ($config) = @_;
  delete $config->{'providesh'};
  delete $config->{'whatprovidesh'};
  delete $config->{'requiresh'};
}

my %addproviders_fm = (
  '>'  => 1,
  '='  => 2,
  '>=' => 3,
  '<'  => 4,
  '<=' => 6,
);

sub addproviders {
  my ($config, $r) = @_;

  my @p;
  my $whatprovides = $config->{'whatprovidesh'};
  $whatprovides->{$r} = \@p;
  if ($r =~ /\|/) {
    for my $or (split(/\s*\|\s*/, $r)) {
      push @p, @{$whatprovides->{$or} || addproviders($config, $or)};
    }
    @p = unify(@p) if @p > 1;
    return \@p;
  }
  return \@p if $r !~ /^(.*?)\s*([<=>]{1,2})\s*(.*?)$/;
  my $rn = $1;
  my $rv = $3;
  my $rf = $addproviders_fm{$2};
  return \@p unless $rf;
  my $provides = $config->{'providesh'};
  my @rp = @{$whatprovides->{$rn} || []};
  for my $rp (@rp) {
    for my $pp (@{$provides->{$rp} || []}) {
      if ($pp eq $rn) {
	# debian: unversioned provides do not match
	# kiwi: supports only rpm, so we need to hand it like it
	next if $config->{'type'} eq 'dsc';
	push @p, $rp;
	last;
      }
      next unless $pp =~ /^\Q$rn\E\s*([<=>]{1,2})\s*(.*?)$/;
      my $pv = $2;
      my $pf = $addproviders_fm{$1};
      next unless $pf;
      if ($pf & $rf & 5) {
	push @p, $rp;
	last;
      }
      if ($pv eq $rv) {
	next unless $pf & $rf & 2;
	push @p, $rp;
	last;
      }
      my $rr = $rf == 2 ? $pf : ($rf ^ 5);
      $rr &= 5 unless $pf & 2;
      # verscmp for spec and kiwi types
      my $vv;
      if ($config->{'type'} eq 'dsc') {
	$vv = Build::Deb::verscmp($pv, $rv, 1);
      } else {
	$vv = Build::Rpm::verscmp($pv, $rv, 1);
      }
      if ($rr & (1 << ($vv + 1))) {
	push @p, $rp;
	last;
      }
    }
  }
  @p = unify(@p) if @p > 1;
  return \@p;
}

sub expand {
  my ($config, @p) = @_;

  my $conflicts = $config->{'conflicth'};
  my $prefer = $config->{'preferh'};
  my $ignore = $config->{'ignoreh'};

  my $whatprovides = $config->{'whatprovidesh'};
  my $requires = $config->{'requiresh'};

  my %xignore = map {substr($_, 1) => 1} grep {/^-/} @p;
  @p = grep {!/^-/} @p;

  my %p;		# expanded packages
  my %aconflicts;	# packages we are conflicting with

  # add direct dependency packages. this is different from below,
  # because we add packages even if to dep is already provided and
  # we break ambiguities if the name is an exact match.
  for my $p (splice @p) {
    my @q = @{$whatprovides->{$p} || addproviders($config, $p)};
    if (@q > 1) {
      my $pn = $p;
      $pn =~ s/ .*//;
      @q = grep {$_ eq $pn} @q;
    }
    if (@q != 1) {
      push @p, $p;
      next;
    }
    print "added $q[0] because of $p (direct dep)\n" if $expand_dbg;
    push @p, $q[0];
    $p{$q[0]} = 1;
    $aconflicts{$_} = 1 for @{$conflicts->{$q[0]} || []};
  }

  my @pamb = ();
  my $doamb = 0;
  while (@p) {
    my @error = ();
    my @rerror = ();
    for my $p (splice @p) {
      for my $r (@{$requires->{$p} || [$p]}) {
	my $ri = (split(/[ <=>]/, $r, 2))[0];
	next if $ignore->{"$p:$ri"} || $xignore{"$p:$ri"};
	next if $ignore->{$ri} || $xignore{$ri};
	my @q = @{$whatprovides->{$r} || addproviders($config, $r)};
	next if grep {$p{$_}} @q;
	next if grep {$xignore{$_}} @q;
	next if grep {$ignore->{"$p:$_"} || $xignore{"$p:$_"}} @q;
	@q = grep {!$aconflicts{$_}} @q;
	if (!@q) {
	  if ($r eq $p) {
	    push @rerror, "nothing provides $r";
	  } else {
	    next if $r =~ /^\//;
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
	    for my $rr (split(/\s*\|\s*/, $r)) {
		next unless $whatprovides->{$rr};
		my @pq = grep {$pq{$_}} @{$whatprovides->{$rr}};
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

sub order {
  my ($config, @p) = @_;

  my $requires = $config->{'requiresh'};
  my $whatprovides = $config->{'whatprovidesh'};
  my %deps;
  my %rdeps;
  my %needed;
  my %p = map {$_ => 1} @p;
  for my $p (@p) {
    my @r;
    for my $r (@{$requires->{$p} || []}) {
      my @q = @{$whatprovides->{$r} || addproviders($config, $r)};
      push @r, grep {$_ ne $p && $p{$_}} @q;
    }
    if (%{$config->{'order'} || {}}) {
      push @r, grep {$_ ne $p && $config->{'order'}->{"$_:$p"}} @p;
    }
    @r = unify(@r);
    $deps{$p} = \@r;
    $needed{$p} = @r;
    push @{$rdeps{$_}}, $p for @r;
  }
  @p = sort {$needed{$a} <=> $needed{$b} || $a cmp $b} @p;
  my @good;
  my @res;
  # the big sort loop
  while (@p) {
    @good = grep {$needed{$_} == 0} @p;
    if (@good) {
      @p = grep {$needed{$_}} @p;
      push @res, @good;
      for my $p (@good) {
	$needed{$_}-- for @{$rdeps{$p}};
      }
      next;
    }
    # uh oh, cycle alert. find and remove all cycles.
    my %notdone = map {$_ => 1} @p;
    $notdone{$_} = 0 for @res;  # already did those
    my @todo = @p;
    while (@todo) {
      my $v = shift @todo;
      if (ref($v)) {
	$notdone{$$v} = 0;      # finished this one
	next;
      }
      my $s = $notdone{$v};
      next unless $s;
      my @e = grep {$notdone{$_}} @{$deps{$v}};
      if (!@e) {
	$notdone{$v} = 0;       # all deps done, mark as finished
	next;
      }
      if ($s == 1) {
	$notdone{$v} = 2;       # now under investigation
	unshift @todo, @e, \$v;
	next;
      }
      # reached visited package, found a cycle!
      my @cyc = ();
      my $cycv = $v;
      # go back till $v is reached again
      while(1) {
	die unless @todo;
	$v = shift @todo;
	next unless ref($v);
	$v = $$v;
	$notdone{$v} = 1 if $notdone{$v} == 2;
	unshift @cyc, $v;
	last if $v eq $cycv;
      }
      unshift @todo, $cycv;
      print STDERR "cycle: ".join(' -> ', @cyc)."\n";
      my $breakv;
      my @breakv = (@cyc, $cyc[0]);
      while (@breakv > 1) {
	last if $config->{'order'}->{"$breakv[0]:$breakv[1]"};
	shift @breakv;
      }
      if (@breakv > 1) {
	$breakv = $breakv[0];
      } else {
	$breakv = (sort {$needed{$a} <=> $needed{$b} || $a cmp $b} @cyc)[-1];
      }
      push @cyc, $cyc[0];	# make it loop
      shift @cyc while $cyc[0] ne $breakv;
      $v = $cyc[1];
      print STDERR "  breaking dependency $breakv -> $v\n";
      $deps{$breakv} = [ grep {$_ ne $v} @{$deps{$breakv}} ];
      $rdeps{$v} = [ grep {$_ ne $breakv} @{$rdeps{$v}} ];
      $needed{$breakv}--;
    }
  }
  return @res;
}

sub add_all_providers {
  my ($config, @p) = @_;
  my $whatprovides = $config->{'whatprovidesh'};
  my $requires = $config->{'requiresh'};
  my %a;
  for my $p (@p) {
    for my $r (@{$requires->{$p} || [$p]}) {
      my $rn = (split(' ', $r, 2))[0];
      $a{$_} = 1 for @{$whatprovides->{$rn} || []};
    }
  }
  push @p, keys %a;
  return unify(@p);
}

###########################################################################

sub parse {
  my ($cf, $fn, @args) = @_;
  return Build::Rpm::parse($cf, $fn, @args) if $do_rpm && $fn =~ /\.spec$/;
  return Build::Deb::parse($cf, $fn, @args) if $do_deb && $fn =~ /\.dsc$/;
  return Build::Kiwi::parse($cf, $fn, @args) if $do_kiwi && $fn =~ /config\.xml$/;
  return Build::Kiwi::parse($cf, $fn, @args) if $do_kiwi && $fn =~ /\.kiwi$/;
  return undef;
}

sub query {
  my ($binname, %opts) = @_;
  my $handle = $binname;
  if (ref($binname) eq 'ARRAY') {
    $handle = $binname->[1];
    $binname = $binname->[0];
  }
  return Build::Rpm::query($handle, %opts) if $do_rpm && $binname =~ /\.rpm$/;
  return Build::Deb::query($handle, %opts) if $do_deb && $binname =~ /\.deb$/;
  return Build::Kiwi::queryiso($handle, %opts) if $do_kiwi && $binname =~ /\.iso$/;
  return undef;
}

sub queryhdrmd5 {
  my ($binname) = @_;
  return Build::Rpm::queryhdrmd5(@_) if $do_rpm && $binname =~ /\.rpm$/;
  return Build::Deb::queryhdrmd5(@_) if $do_deb && $binname =~ /\.deb$/;
  return Build::Kiwi::queryhdrmd5(@_) if $do_kiwi && $binname =~ /\.iso$/;
  return Build::Kiwi::queryhdrmd5(@_) if $do_kiwi && $binname =~ /\.raw$/;
  return Build::Kiwi::queryhdrmd5(@_) if $do_kiwi && $binname =~ /\.raw.install$/;
  return undef;
}

1;
