################################################################
#
# Copyright (c) 1995-2014 SUSE Linux Products GmbH
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

package Build::Expand;

use strict;

our $expand_dbg;

# XXX: should also check the package EVR
sub nevrmatch {
  my ($config, $r, @p) = @_;
  my $rn = $r;
  $rn =~ s/\s*([<=>]{1,2}).*$//;
  return grep {$_ eq $rn} @p;
}

# check if package $q has a conflict against an installed package.
# if yes, add message to @$eq and return true
sub checkconflicts {
  my ($config, $ins, $q, $eq, @r) = @_;
  my $whatprovides = $config->{'whatprovidesh'};
  my $ret = 0;
  for my $r (@r) {
    if ($r =~ /^\(.*\)$/) {
      # note the []: we ignore errors here. they will be reported if the package is chosen.
      my $n = normalizerich($config, $q, $r, 1, []);
      $ret = 1 if check_conddeps_notinst($q, $n, $eq, $ins);
      next;
    }
    my @eq = grep {$ins->{$_}} @{$whatprovides->{$r} || Build::addproviders($config, $r)};
    next unless @eq;
    push @$eq, map {"(provider $q conflicts with $_)"} @eq;
    $ret = 1;
  }
  return $ret;
}

sub checkobsoletes {
  my ($config, $ins, $q, $eq, @r) = @_;
  my $whatprovides = $config->{'whatprovidesh'};
  my $ret = 0;
  for my $r (@r) {
    my @eq = grep {$ins->{$_}} nevrmatch($config, $r, @{$whatprovides->{$r} || Build::addproviders($config, $r)});
    next unless @eq;
    push @$eq, map {"(provider $q obsoletes $_)"} @eq;
    $ret = 1;
  }
  return $ret;
}

sub todo2recommended {
  my ($config, $recommended, $todo) = @_;
  my $whatprovides = $config->{'whatprovidesh'};
  my $pkgrecommends = $config->{'recommendsh'} || {};
  for my $p (splice @$todo) {
    for my $r (@{$pkgrecommends->{$p} || []}) {
      $recommended->{$_} = 1 for @{$whatprovides->{$r} || Build::addproviders($config, $r)}
    }
  }
}

sub cplx_mix {
  my ($q1, $q2, $todnf) = @_;
  my @q;
  for my $qq1 (@$q1) {
    for my $qq2 (@$q2) {
      my %qq = map {$_ => 1} (@$qq1, @$qq2);
      my @qq = sort keys %qq;
      push @q, \@qq unless grep {$qq{"-$_"}} @qq;
    }
  }
  return $todnf ? 0 : 1 unless @q;
  return (-1, @q);
}

sub cplx_inv {
  my ($f, @q) = @_;
  return 1 - $f if $f == 0 || $f == 1;
  my @iq;
  for my $q (@q) {
    $q = [ map {"-$_"} @$q ];
    s/^--// for @$q;
  }
  return (-1, @q);
}

sub normalize_cplx_rec {
  my ($c, $r, $todnf) = @_;
  if ($r->[0] == 0) {
    my $ri = (split(/[ <=>]/, $r->[1], 2))[0];
    my ($config, $p, $ignore, $xignore) = @$c;
    if (!$todnf) {
      return 1 if $ignore->{$ri} || $xignore->{$ri};
      return 1 if defined($p) && ($ignore->{"$p:$ri"} || $xignore->{"$p:$ri"});
    }
    my $whatprovides = $config->{'whatprovidesh'};
    my @q = @{$whatprovides->{$r->[1]} || Build::addproviders($config, $r->[1])};
    return 0 unless @q;
    if ($todnf) {
      return (-1, map { [ $_ ] } @q);
    } else {
      return (-1, [ @q ]);
    }
  }
  if ($r->[0] == 3 && @$r == 4) {
    # complex if/else case: A IF (B ELSE C) -> (A OR ~B) AND (C OR B)
    my ($n1, @q1) = normalize_cplx_rec($c, [3, $r->[1], $r->[2]], $todnf);
    my ($n2, @q2) = normalize_cplx_rec($c, [2, $r->[2], $r->[3]], $todnf);
    return 0 if $n1 == 0 || $n2 == 0;
    return ($n2, @q2) if $n1 == 1;
    return ($n1, @q1) if $n2 == 1;
    if (!$todnf) {
      return (-1, @q1, @q2);
    } else {
      return cplx_mix(\@q1, \@q2, $todnf);
    }
  }
  if ($r->[0] == 4 && @$r == 4) {
    # complex unless/else case: A UNLESS (B ELSE C) -> (A AND ~B) OR (C AND B)
    my ($n1, @q1) = normalize_cplx_rec($c, [4, $r->[1], $r->[2]], $todnf);
    my ($n2, @q2) = normalize_cplx_rec($c, [1, $r->[2], $r->[3]], $todnf);
    return 1 if $n1 == 1 || $n2 == 1;
    return ($n2, @q2) if $n1 == 0;
    return ($n1, @q1) if $n2 == 0;
    if ($todnf) {
      return (-1, @q1, @q2);
    } else {
      return cplx_mix(\@q1, \@q2, $todnf);
    }
  }
  if ($r->[0] == 1 || $r->[0] == 4) {
    # and / unless
    my $todnf2 = $r->[0] == 4 ? !$todnf : $todnf;
    my ($n1, @q1) = normalize_cplx_rec($c, $r->[1], $todnf);
    my ($n2, @q2) = normalize_cplx_rec($c, $r->[2], $todnf2);
    ($n2, @q2) = cplx_inv($n2, @q2) if $r->[0] == 4;
    return 0 if $n1 == 0 || $n2 == 0;
    return ($n2, @q2) if $n1 == 1;
    return ($n1, @q1) if $n2 == 1;
    if (!$todnf) {
      return (-1, @q1, @q2);
    } else {
      return cplx_mix(\@q1, \@q2, $todnf);
    }
  }
  if ($r->[0] == 2 || $r->[0] == 3) {
    # or / if
    my $todnf2 = $r->[0] == 3 ? !$todnf : $todnf;
    my ($n1, @q1) = normalize_cplx_rec($c, $r->[1], $todnf);
    my ($n2, @q2) = normalize_cplx_rec($c, $r->[2], $todnf2);
    ($n2, @q2) = cplx_inv($n2, @q2) if $r->[0] == 3;
    return 1 if $n1 == 1 || $n2 == 1;
    return ($n2, @q2) if $n1 == 0;
    return ($n1, @q1) if $n2 == 0;
    if ($todnf) {
      return (-1, @q1, @q2);
    } else {
      return cplx_mix(\@q1, \@q2, $todnf);
    }
  }
  if ($r->[0] == 6 || $r->[0] == 7) {
    # with / without
    my ($n1, @q1) = normalize_cplx_rec($c, $r->[1], 0);
    my ($n2, @q2) = normalize_cplx_rec($c, $r->[2], 0);
    if ($n2 == 0 && $r->[0] == 7) {
      @q2 = ( [] );
      $n2 = -1;
    }
    return 0 if $n1 != -1 || $n2 != -1;
    return 0 if @q1 != 1 || @q2 != 1;
    @q1 = @{$q1[0]};
    @q2 = @{$q2[0]};
    return 0 if grep {/^-/} @q1;
    return 0 if grep {/^-/} @q2;
    my %q2 = map {$_ => 1} @q2;
    my @q;
    if ($r->[0] == 6) {
      @q = grep {$q2{$_}} @q1;
    } else {
      @q = grep {!$q2{$_}} @q1;
    }
    return 0 unless @q;
    if ($todnf) {
      return (-1, map { [ $_ ] } @q);
    } else {
      return (-1, [ @q ]);
    }
  }
  return 0;
}

sub normalizerich {
  my ($config, $p, $dep, $deptype, $error, $ignore, $xignore) = @_;
  my $r = Build::Rpm::parse_rich_dep($dep);
  if (!$r) {
    if (defined($p)) {
      push @$error, "cannot parse dependency $dep from $p";
    } else {
      push @$error, "cannot parse dependency $dep";
    }
    return [];
  }
  my $c = [$config, $p, $ignore || {}, $xignore || {}];
  my ($n, @q);
  if ($deptype == 0 || $deptype == 2) {
    ($n, @q) = normalize_cplx_rec($c, $r);
    return () if $n == 1;
    if (!$n) {
      return () if $deptype == 2;
      if (defined($p)) {
        push @$error, "nothing provides $dep needed by $p";
      } else {
        push @$error, "nothing provides $dep";
      }
      return [];
    }
  } else {
    ($n, @q) = normalize_cplx_rec($c, $r, 1);
    ($n, @q) = cplx_inv($n, @q);
    if (!$n) {
      if (defined($p)) {
        push @$error, "$p conflicts with always true $dep";
      } else {
        push @$error, "conflict with always true $dep";
      }
    }
  }
  for my $q (@q) {
    my @neg = @$q;
    @neg = grep {s/^-//} @neg;
    @neg = grep {$_ ne $p} @neg if defined $p;
    @$q = grep {!/^-/} @$q;
    $q = [$dep, $deptype, \@neg, @$q];
  }
  return \@q;
}

# handle a normalized rich dependency from install of package p
# todo_cond is undef if we are re-checking the cond queue
sub check_conddeps_inst {
  my ($p, $n, $error, $installed, $aconflicts, $todo, $todo_cond) = @_;
  for my $c (@$n) {
    my ($r, $rtype, $cond, @q) = @$c; 
    next unless defined $cond;			# already handled?
    next if grep {$installed->{$_}} @q;         # already fulfilled
    my @cx = grep {!$installed->{$_}} @$cond;   # open conditions
    if (!@cx) {
      $c->[2] = undef;				# mark as handled to avoid dups
      if (@q) {
        push @$todo, $c, $p;
      } elsif (@$cond) {
	if (!$rtype) {
	  if (defined($p)) {
	    push @$error, "nothing provides $r needed by $p";
	  } else {
	    push @$error, "nothing provides $r";
	  }
	  next;
	}
	next if $rtype == 2;			# ignore for recommends
	if (defined($p)) {
	  push @$error, map {"$p conflicts with $_"} sort(@$cond);
	} else {
	  push @$error, map {"conflicts with $_"} sort(@$cond);
	}
      }    
    } else {
      if (!@q && @cx == 1) { 
	next if $rtype == 2;
	if (!$rtype) {
	  if (defined($p)) {
	    $aconflicts->{$cx[0]} = "conflicts with $r needed by $p";
	  } else {
	    $aconflicts->{$cx[0]} = "conflicts with $r";
	  }
	  next;
	}
	if (defined($p)) {
          $aconflicts->{$cx[0]} = "is in conflict with $p";
	} else {
          $aconflicts->{$cx[0]} = "is in conflict";
	}
      } elsif ($todo_cond) {
        push @{$todo_cond->{$_}}, [ $c, $p ] for @cx;
      }
    }
  }
}

# handle a normalized rich dependency from a not-yet installed package
# (we just check conflicts)
sub check_conddeps_notinst {
  my ($p, $n, $eq, $installed) = @_;
  my $ret = 0;
  for my $c (@$n) {
    my ($r, $rtype, $cond, @q) = @$c; 
    next if @q || !@$cond || grep {!$installed->{$_}} @$cond;
    push @$eq, map {"(provider $p conflicts with $_)"} sort(@$cond);
    $ret = 1;
  }
  return $ret;
}

sub fulfilled_cplx_rec_set {
  my ($config, $r) = @_;
  if ($r->[0] == 0) {
    my $whatprovides = $config->{'whatprovidesh'};
    return @{$whatprovides->{$r->[1]} || Build::addproviders($config, $r->[1])};
  }
  $r = [2, $r->[1], $r->[3]] if ($r->[0] == 3 || $r->[0] == 4) && @$r == 4;
  return fulfilled_cplx_rec_set($config, $r->[1]) if $r->[0] == 3 || $r->[0] == 4;
  if ($r->[0] == 1 || $r->[0] == 2) {
    my %s = map {$_ => 1} fulfilled_cplx_rec_set($config, $r->[1]), fulfilled_cplx_rec_set($config, $r->[2]);
    return sort keys %s;
  }
  if ($r->[0] == 6) {
    my %s = map {$_ => 1} fulfilled_cplx_rec_set($config, $r->[2]);
    return grep {$s{$_}} fulfilled_cplx_rec_set($config, $r->[1]);
  }
  if ($r->[0] == 7) {
    my %s = map {$_ => 1} fulfilled_cplx_rec_set($config, $r->[2]);
    return grep {!$s{$_}} fulfilled_cplx_rec_set($config, $r->[1]);
  }
  return ();
}

sub fulfilled_cplx_rec {
  my ($config, $installed, $r) = @_;
  if ($r->[0] == 0) {
    my $whatprovides = $config->{'whatprovidesh'};
    return 1 if grep {$installed->{$_}} @{$whatprovides->{$r->[1]} || Build::addproviders($config, $r->[1])};
    return 0;
  }
  if ($r->[0] == 1) {			# A AND B
    return fulfilled_cplx_rec($config, $installed, $r->[1]) && fulfilled_cplx_rec($config, $installed, $r->[2]);
  }
  if ($r->[0] == 2) {			# A OR B
    return fulfilled_cplx_rec($config, $installed, $r->[1]) || fulfilled_cplx_rec($config, $installed, $r->[2]);
  }
  if ($r->[0] == 3) {			# A IF B
    return fulfilled_cplx_rec($config, $installed, $r->[1]) if fulfilled_cplx_rec($config, $installed, $r->[2]);
    return @$r == 4 ? fulfilled_cplx_rec($config, $installed, $r->[3]) : 1;
  }
  if ($r->[0] == 4) {			# A UNLESS B
    return fulfilled_cplx_rec($config, $installed, $r->[1]) unless fulfilled_cplx_rec($config, $installed, $r->[2]);
    return @$r == 4 ? fulfilled_cplx_rec($config, $installed, $r->[3]) : 0;
  }
  return 1 if grep {$installed->{$_}} fulfilled_cplx_rec_set($config, $r);
  return 0;
}

sub extractnative {
  my ($config, $r, $p, $foreign) = @_;
  my $ma = $config->{'multiarchh'}->{$p} || '';
  if ($ma eq 'foreign' || ($ma eq 'allowed' && $r =~ /:any/)) {
    if ($expand_dbg && !grep {$r eq $_} @$foreign) {
      print "added $r to foreign dependencies\n";
    }
    push @$foreign, $r;
    return 1;
  }
  return 0;
}

sub expand {
  my ($config, @p) = @_;

  print "expand: @p\n" if $expand_dbg;
  my $conflicts = $config->{'conflicth'};
  my $pkgconflicts = $config->{'pkgconflictsh'} || {};
  my $pkgobsoletes = $config->{'pkgobsoletesh'} || {};
  my $prefer = $config->{'preferh'};
  my $ignore = $config->{'ignoreh'};
  my $ignoreconflicts = $config->{'expandflags:ignoreconflicts'};
  my $keepfilerequires = $config->{'expandflags:keepfilerequires'};
  my $dosupplements = $config->{'expandflags:dosupplements'};
  my $ignoreignore;
  my $userecommendsforchoices = 1;
  my $usesupplementsforchoices;
  my $dorecommends = $config->{'expandflags:dorecommends'};

  my $binarytype = $config->{'binarytype'} || 'rpm';
  $keepfilerequires = 1 if $binarytype ne 'rpm' && $binarytype ne 'UNDEFINED';

  my $whatprovides = $config->{'whatprovidesh'};
  my $requires = $config->{'requiresh'};

  my $xignore = { map {substr($_, 1) => 1} grep {/^-/} @p };
  $ignoreconflicts = 1 if $xignore->{'-ignoreconflicts--'};
  $keepfilerequires = 1 if $xignore->{'-keepfilerequires--'};
  $dorecommends = 1 if $xignore->{'-dorecommends--'};
  $dosupplements = 1 if $xignore->{'-dosupplements--'};
  $ignore = {} if $xignore->{'-ignoreignore--'};
  if ($ignoreignore) {
    $xignore = {};
    $ignore = {};
  }
  $usesupplementsforchoices = 1 if $dosupplements;
  my @directdepsend;
  if ($xignore->{'-directdepsend--'}) {
    delete $xignore->{'-directdepsend--'};
    @directdepsend = @p;
    for my $p (splice @p) {
      last if $p eq '--directdepsend--';
      push @p, $p;
    }
    @directdepsend = grep {!/^-/} splice(@directdepsend, @p + 1);
  }

  my $extractnative;
  (undef, $extractnative) = splice(@p, 0, 2) if @p > 1 && $p[0] eq '--extractnative--' && ref($p[1]);
  undef $extractnative if $extractnative && !%{$config->{'multiarchh'} || {}};

  my %p;		# expanded packages
  my @todo;		# dependencies to install
  my @todo_inst;	# packages we decided to install
  my @todo_recommends;
  my %todo_cond;
  my %recommended;	# recommended by installed packages
  my @rec_todo;		# installed todo
  my @error;
  my %aconflicts;	# packages we are conflicting with
  my @native;

  # handle conflicts from the project config
  push @{$aconflicts{$_}}, "is in conflict" for @{$conflicts->{':'} || []};

  # handle direct conflicts
  for (grep {/^!/} @p) {
    my $r = /^!!/ ? substr($_, 2) : substr($_, 1);
    if ($r =~ /^\(.*\)$/) {
      my $n = normalizerich($config, undef, $r, 1, \@error);
      my %naconflicts;
      check_conddeps_inst(undef, $n, \@error, \%p, \%naconflicts, \@todo, \%todo_cond);
      push @{$aconflicts{$_}}, $naconflicts{$_} for keys %naconflicts;
      next;
    }
    my @q = @{$whatprovides->{$r} || Build::addproviders($config, $r)};
    @q = nevrmatch($config, $r, @q) if /^!!/;
    push @{$aconflicts{$_}}, "is in conflict" for @q;
  }
  @p = grep {!/^[-!]/} @p;

  # add direct dependency packages. this is different from below,
  # because we add packages even if the dep is already provided and
  # we break ambiguities if the name is an exact match.
  for my $r (splice @p) {
    if ($r =~ /^\(.*\)$/) {
      push @p, $r;	# rich deps are never direct
      next;
    }
    my @q = @{$whatprovides->{$r} || Build::addproviders($config, $r)};
    @q = grep {!$aconflicts{$_}} @q if @q > 1;
    my $pn = $r;
    $pn =~ s/ .*//;
    @q = grep {$_ eq $pn} @q;
    if (@q != 1) {
      push @p, $r;
      next;
    }
    my $p = $q[0];
    next if $extractnative && extractnative($config, $r, $p, \@native);
    print "added $p because of $r (direct dep)\n" if $expand_dbg;
    push @todo_inst, $p;
  }

  for my $r (@p, @directdepsend) {
    if ($r =~ /^\(.*\)$/) {
      # rich dep. normalize, put on todo.
      my $n = normalizerich($config, undef, $r, 0, \@error);
      my %naconflicts;
      check_conddeps_inst(undef, $n, \@error, \%p, \%naconflicts, \@todo, \%todo_cond);
      push @{$aconflicts{$_}}, $naconflicts{$_} for keys %naconflicts;
    } else {
      push @todo, $r, undef;
    }
  }

  for my $p (@todo_inst) {
    push @error, map {"$p $_"} @{$aconflicts{$p}} if $aconflicts{$p};
  }
  return (undef, @error) if @error;

  push @native, '--directdepsend--' if $extractnative;

  while (@todo || @todo_inst) {
    # install a set of chosen packages
    # ($aconficts must not be set for any of them)
    if (@todo_inst) {
      if (@todo_inst > 1) {
        my %todo_inst = map {$_ => 1} @todo_inst;
	@todo_inst = grep {delete($todo_inst{$_})} @todo_inst;
      }

      # check aconflicts (just in case)
      for my $p (@todo_inst) {
        push @error, map {"$p $_"} @{$aconflicts{$p}} if $aconflicts{$p};
      }
      return (undef, @error) if @error;

      # check against old cond dependencies. we do this step by step so we don't get dups.
      for my $p (@todo_inst) {
	push @todo_recommends, $p if $dorecommends;
	$p{$p} = 1;
	if ($todo_cond{$p}) {
          for my $c (@{delete $todo_cond{$p}}) {
	    my %naconflicts;
	    check_conddeps_inst($c->[1], [ $c->[0] ], \@error, \%p, \%naconflicts, \@todo);
	    push @{$aconflicts{$_}}, $naconflicts{$_} for keys %naconflicts;
	  }
	}
        delete $aconflicts{$p};		# no longer needed
      }
      return undef, @error if @error;

      # now check our own dependencies
      for my $p (@todo_inst) {
	my %naconflicts;
	my %naobsoletes;
	$naconflicts{$_} = "is in conflict with $p" for @{$conflicts->{$p} || []};
	for my $r (@{$requires->{$p} || []}) {
	  if ($r =~ /^\(.*\)$/) {
	    my $n = normalizerich($config, $p, $r, 0, \@error, $ignore, $xignore);
	    check_conddeps_inst($p, $n, \@error, \%p, \%naconflicts, \@todo, \%todo_cond);
	    next;
	  }
	  my $ri = (split(/[ <=>]/, $r, 2))[0];
	  next if $ignore->{"$p:$ri"} || $xignore->{"$p:$ri"};
	  next if $ignore->{$ri} || $xignore->{$ri};
	  next if $ri =~ /^rpmlib\("/;
	  next if !$keepfilerequires && ($ri =~ /^\//) && !@{$whatprovides->{$ri} || []};
	  push @todo, ($r, $p);
	}
	if (!$ignoreconflicts) {
	  for my $r (@{$pkgconflicts->{$p}}) {
	    if ($r =~ /^\(.*\)$/) {
	      my $n = normalizerich($config, $p, $r, 1, \@error);
	      check_conddeps_inst($p, $n, \@error, \%p, \%naconflicts, \@todo, \%todo_cond);
	      next;
	    }
	    $naconflicts{$_} = "is in conflict with $p" for @{$whatprovides->{$r} || Build::addproviders($config, $r)};
	  }
	  for my $r (@{$pkgobsoletes->{$p}}) {
	    $naobsoletes{$_} =  "is obsoleted by $p" for nevrmatch($config, $r, @{$whatprovides->{$r} || Build::addproviders($config, $r)});
	  }
	}
	if (%naconflicts) {
	  push @error, map {"$p conflicts with $_"} grep {$_ ne $p && $p{$_}} sort keys %naconflicts;
	  push @{$aconflicts{$_}}, $naconflicts{$_} for keys %naconflicts;
	}
	if (%naobsoletes) {
	  push @error, map {"$p obsoletes $_"} grep {$_ ne $p && $p{$_}} sort keys %naobsoletes;
	  push @{$aconflicts{$_}}, $naobsoletes{$_} for keys %naobsoletes;
	}
	push @rec_todo, $p if $userecommendsforchoices;
      }
      return undef, @error if @error;
      @todo_inst = ();
    }
 
    for my $pass (0, 1, 2, 3, 4, 5, 6) {
      next if $pass == 5 && !$usesupplementsforchoices;
      my @todo_next;
      while (@todo) {
	my ($r, $p) = splice(@todo, 0, 2);
	my $rtodo = $r;
	my @q;
	if (ref($r)) {
	  ($r, undef, undef, @q) = @$r;
	} else {
	  @q = @{$whatprovides->{$r} || Build::addproviders($config, $r)};
	}
	next if grep {$p{$_}} @q;
	my $pp = defined($p) ? "$p:" : '';
	my $pn = defined($p) ? " needed by $p" : '';
	if (defined($p) && !$ignoreignore) {
	  next if grep {$ignore->{$_} || $xignore->{$_}} @q;
	  next if grep {$ignore->{"$pp$_"} || $xignore->{"$pp$_"}} @q;
	}

	if (!@q) {
	  next if defined($p) && $r =~ /^rpmlib\(/;
	  next if defined($p) && !$keepfilerequires && ($r =~ /^\//);
	  push @error, "nothing provides $r$pn";
	  next;
	}

	if (@q > 1 && $pass == 0) {
	  push @todo_next, $rtodo, $p;
	  next;
	}

	# pass 0: only one provider
	# pass 1: conflict pruning
        my $nq = @q;
	my @eq;
	for my $q (@q) {
	  push @eq, map {"(provider $q $_)"} @{$aconflicts{$q}} if $aconflicts{$q};
	}
	@q = grep {!$aconflicts{$_}} @q;
	if (!$ignoreconflicts) {
	  for my $q (splice @q) {
	    push @q, $q unless @{$pkgconflicts->{$q} || []} && checkconflicts($config, \%p, $q, \@eq, @{$pkgconflicts->{$q}});
	  }
	  for my $q (splice @q) {
	    push @q, $q unless @{$pkgobsoletes->{$q} || []} && checkobsoletes($config, \%p, $q, \@eq, @{$pkgobsoletes->{$q}});
	  }
	}

	if (!@q) {
	  push @error, "conflict for providers of $r$pn", sort(@eq);
	  next;
	}
        if (@q == 1) {
	  next if $extractnative && extractnative($config, $r, $q[0], \@native);
	  print "added $q[0] because of $pp$r\n" if $expand_dbg;
	  push @todo_inst, $q[0];
          next;
        }

	# pass 2: prune neg prefers and simple pos prefers
        if ($pass < 2) {
	  print "undecided about $pp$r: @q\n" if $expand_dbg;
	  push @todo_next, $rtodo, $p;
	  next;
        }
	if (@q > 1) {
	  my @pq = grep {!$prefer->{"-$_"} && !$prefer->{"-$pp$_"}} @q;
	  @q = @pq if @pq;
	  @pq = grep {$prefer->{$_} || $prefer->{"$pp$_"}} @q;
	  @q = @pq if @pq == 1;
	}
        if (@q == 1) {
	  next if $extractnative && extractnative($config, $r, $q[0], \@native);
	  push @todo_inst, $q[0];
	  print "added $q[0] because of $pp$r\n" if $expand_dbg;
          next;
        }

	# pass 3: prune pos prefers and debian choice deps
        if ($pass < 3) {
	  push @todo_next, $rtodo, $p;
	  next;
        }
	if (@q > 1) {
	  my @pq = grep {$prefer->{$_} || $prefer->{"$pp$_"}} @q;
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
        if (@q == 1) {
	  next if $extractnative && extractnative($config, $r, $q[0], \@native);
	  push @todo_inst, $q[0];
	  print "added $q[0] because of $pp$r\n" if $expand_dbg;
          next;
        }

	# pass 4: prune recommends
        if ($pass < 4) {
	  push @todo_next, $rtodo, $p;
	  next;
        }
	todo2recommended($config, \%recommended, \@rec_todo) if @rec_todo;
	my @pq = grep {$recommended{$_}} @q;
	print "recommended [@pq] among [@q]\n" if $expand_dbg;
	@q = @pq if @pq;
        if (@q == 1) {
	  next if $extractnative && extractnative($config, $r, $q[0], \@native);
	  push @todo_inst, $q[0];
	  print "added $q[0] because of $pp$r\n" if $expand_dbg;
          next;
        }

	# pass 5: prune with supplements
	if ($pass < 5) {
	  push @todo_next, $rtodo, $p;
	  next;
	}
	if ($usesupplementsforchoices) {
	  my $pkgsupplements = $config->{'supplementsh'} || {};
	  my @pq;
	  for my $q (@q) {
	    for my $rs (@{$pkgsupplements->{$q} || []}) {
	      if ($rs =~ /^\(.*\)$/) {
		my $rd = Build::Rpm::parse_rich_dep($rs);
		next if !$rd || fulfilled_cplx_rec($config, \%p, $rd);
	      } else {
	        next unless grep {$p{$_}} @{$whatprovides->{$rs} || Build::addproviders($config, $rs)};
	      }
	      push @pq, $q;
	      last;
	    }
	  }
	  print "supplemented [@pq] among [@q]\n" if $expand_dbg;
	  @q = @pq if @pq;
	  if (@q == 1) {
	    next if $extractnative && extractnative($config, $r, $q[0], \@native);
	    push @todo_inst, $q[0];
	    print "added $q[0] because of $pp$r\n" if $expand_dbg;
	    next;
	  }
	}

        # pass 6: record error
        if ($pass < 6) {
	  push @todo_next, $rtodo, $p;
	  next;
        }
	@q = sort(@q);
	if (defined($p)) {
	  push @error, "have choice for $r needed by $p: @q";
	} else {
	  push @error, "have choice for $r: @q";
	}
      }
      @todo = @todo_next;
      last if @todo_inst;
    }
    return undef, @error if @error;

    if (@todo_recommends && !@todo && !@todo_inst) {
      my $pkgrecommends = $config->{'recommendsh'} || {};
      for my $p (@todo_recommends) {
	for my $r (@{$pkgrecommends->{$p} || []}) {
	  if ($r =~ /^\(.*\)$/) {
	    my $n = normalizerich($config, $p, $r, 2, \@error, $ignore, $xignore);
	    check_conddeps_inst($p, $n, \@error, \%p, undef, \@todo, \%todo_cond);
	  } else {
	    my @q = @{$whatprovides->{$r} || Build::addproviders($config, $r)};
	    next if grep {$p{$_}} @q;
	    @q = grep {!$aconflicts{$_}} @q;
	    if (!$ignoreconflicts) {
	      for my $q (splice @q) {
		push @q, $q unless @{$pkgconflicts->{$q} || []} && checkconflicts($config, \%p, $q, [], @{$pkgconflicts->{$q}});
	      }
	      for my $q (splice @q) {
		push @q, $q unless @{$pkgobsoletes->{$q} || []} && checkobsoletes($config, \%p, $q, [], @{$pkgobsoletes->{$q}});
	      }
	    }
	    push @todo, $r, $p if @q;
	  }
	}
      }
    }

    if ($dosupplements) {
      my $pkgsupplements = $config->{'supplementsh'} || {};
      for my $p (sort keys %$pkgsupplements) {
	next unless @{$pkgsupplements->{$p}};
	next if $p{$p};
	next if $aconflicts{$p};
	if (!$ignoreconflicts) {
	  next if @{$pkgconflicts->{$p} || []} && checkconflicts($config, \%p, $p, [], @{$pkgconflicts->{$p}});
	  next if @{$pkgobsoletes->{$p} || []} && checkobsoletes($config, \%p, $p, [], @{$pkgobsoletes->{$p}});
	}
	for my $rs (@{$pkgsupplements->{$p} || []}) {
	  if ($rs =~ /^\(.*\)$/) {
	    my $rd = Build::Rpm::parse_rich_dep($rs);
	    next unless $rd && fulfilled_cplx_rec($config, \%p, $rd);
	  } else {
	    next unless grep {$p{$_}} @{$whatprovides->{$rs} || Build::addproviders($config, $rs)};
	  }
	  last if $extractnative && extractnative($config, $rs, $p, \@native);
	  push @todo_inst, $p;
	  print "added $p because it supplements $rs\n" if $expand_dbg;
	  last;
	}
      }
    }
  }

  if ($extractnative && @native) {
    my %rdone;
    for my $r (splice @native) {
      next if $rdone{$r}++;
      if ($r eq '--directdepsend--') {
	push @native, $r;
	next;
      }
      my @q = @{$whatprovides->{$r} || Build::addproviders($config, $r)};
      push @native, $r unless grep {$p{$_}} @q;
    }
    pop @native if @native && $native[-1] eq '--directdepsend--';
    push @$extractnative, @native;
  }

  return 1, (sort keys %p);
}

1;
