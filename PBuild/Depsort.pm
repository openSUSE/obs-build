################################################################
#
# Copyright (c) 2021 SUSE LLC
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

package PBuild::Depsort;

#
# Sort packages by dependencies
#
sub depsort {
  my ($depsp, $mapp, $cycp, @packs) = @_;

  return @packs if @packs < 2;

  my %deps;
  my %rdeps;
  my %needed;

  # map and unify dependencies, create rdeps and needed
  my %known = map {$_ => 1} @packs;
  die("sortpacks: input not unique\n") if @packs != keys(%known);
  for my $p (@packs) {
    my @fdeps = @{$depsp->{$p} || []};
    @fdeps = map {$mapp->{$_} || $_} @fdeps if $mapp;
    @fdeps = grep {$known{$_}} @fdeps;
    my %fdeps = ($p => 1);      # no self reference
    @fdeps = grep {!$fdeps{$_}++} @fdeps;
    $deps{$p} = \@fdeps;
    $needed{$p} = @fdeps;
    push @{$rdeps{$_}}, $p for @fdeps;
  }
  undef %known;         # free memory

  @packs = sort {$needed{$a} <=> $needed{$b} || $a cmp $b} @packs;
  my @good;
  my @res;
  # the big sort loop
  while (@packs) {
    @good = grep {$needed{$_} == 0} @packs;
    if (@good) {
      @packs = grep {$needed{$_}} @packs;
      push @res, @good;
      for my $p (@good) {
        $needed{$_}-- for @{$rdeps{$p}};
      }
      next;
    }
    die unless @packs > 1;
    # uh oh, cycle alert. find and remove all cycles.
    my %notdone = map {$_ => 1} @packs;
    $notdone{$_} = 0 for @res;  # already did those
    my @todo = @packs;
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
      # print "cycle: ".join(' -> ', @cyc)."\n";
      push @$cycp, [ @cyc ] if $cycp;
      my $breakv = (sort {$needed{$a} <=> $needed{$b} || $a cmp $b} @cyc)[0];
      push @cyc, $cyc[0];
      shift @cyc while $cyc[0] ne $breakv;
      $v = $cyc[1];
      # print "  breaking with $breakv -> $v\n";
      $deps{$breakv} = [ grep {$_ ne $v} @{$deps{$breakv}} ];
      $rdeps{$v} = [ grep {$_ ne $breakv} @{$rdeps{$v}} ];
      $needed{$breakv}--;
    }
  }
  return @res;
}

#
# Sort packages by dependencies mapped to source packages
#
sub depsort2 {
  my ($deps, $dep2src, $pkg2src, $cycles, @packs) = @_;
  my %src2pkg = reverse(%$pkg2src);
  my %pkgdeps;
  my @dups;
  if (keys(%src2pkg) != keys (%$pkg2src)) {
    @dups = grep {$src2pkg{$pkg2src->{$_}} ne $_} reverse(keys %$pkg2src);
  }
  if (@dups) {
    push @dups, grep {defined($_)} map {delete $src2pkg{$pkg2src->{$_}}} @dups;
    @dups = sort(@dups);
    #print "src2pkg dups: @dups\n";
    push @{$src2pkg{$pkg2src->{$_}}}, $_ for @dups;
    for my $pkg (keys %$deps) {
      $pkgdeps{$pkg} = [ map {ref($_) ? @$_ : $_} map { $src2pkg{$dep2src->{$_} || $_} || $dep2src->{$_} || $_} @{$deps->{$pkg}} ];
    }    
  } else {
    for my $pkg (keys %$deps) {
      $pkgdeps{$pkg} = [ map { $src2pkg{$dep2src->{$_} || $_} || $dep2src->{$_} || $_} @{$deps->{$pkg}} ];
    }    
  }
  return depsort(\%pkgdeps, undef, $cycles, @packs);
}

1;
