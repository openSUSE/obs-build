
package Build::Rpm;

use strict;

sub expr {
  my $expr = shift;
  my $lev = shift;

  $lev ||= 0;
  my ($v, $v2);
  $expr =~ s/^\s+//;
  my $t = substr($expr, 0, 1);
  if ($t eq '(') {
    ($v, $expr) = expr(substr($expr, 1), 0);
    return undef unless defined $v;
    return undef unless $expr =~ s/^\)//;
  } elsif ($t eq '!') {
    ($v, $expr) = expr(substr($expr, 1), 0);
    return undef unless defined $v;
    $v = 0 if $v && $v eq '\"\"';
    $v =~ s/^0+/0/ if $v;
    $v = !$v;
  } elsif ($t eq '-') {
    ($v, $expr) = expr(substr($expr, 1), 0);
    return undef unless defined $v;
    $v = -$v;
  } elsif ($expr =~ /^([0-9]+)(.*?)$/) {
    $v = $1;
    $expr = $2;
  } elsif ($expr =~ /^([a-zA-Z_0-9]+)(.*)$/) {
    $v = "\"$1\"";
    $expr = $2;
  } elsif ($expr =~ /^(\".*?\")(.*)$/) {
    $v = $1;
    $expr = $2;
  } else {
    return;
  }
  while (1) {
    $expr =~ s/^\s+//;
    if ($expr =~ /^&&/) {
      return ($v, $expr) if $lev > 1;
      ($v2, $expr) = expr(substr($expr, 2), 1);
      return undef unless defined $v2;
      $v &&= $v2;
    } elsif ($expr =~ /^\|\|/) {
      return ($v, $expr) if $lev > 1;
      ($v2, $expr) = expr(substr($expr, 2), 1);
      return undef unless defined $v2;
      $v ||= $v2;
    } elsif ($expr =~ /^>=/) {
      return ($v, $expr) if $lev > 2;
      ($v2, $expr) = expr(substr($expr, 2), 2);
      return undef unless defined $v2;
      $v = (($v =~ /^\"/) ? $v ge $v2 : $v >= $v2) ? 1 : 0;
    } elsif ($expr =~ /^>/) {
      return ($v, $expr) if $lev > 2;
      ($v2, $expr) = expr(substr($expr, 1), 2);
      return undef unless defined $v2;
      $v = (($v =~ /^\"/) ? $v gt $v2 : $v > $v2) ? 1 : 0;
    } elsif ($expr =~ /^<=/) {
      return ($v, $expr) if $lev > 2;
      ($v2, $expr) = expr(substr($expr, 2), 2);
      return undef unless defined $v2;
      $v = (($v =~ /^\"/) ? $v le $v2 : $v <= $v2) ? 1 : 0;
    } elsif ($expr =~ /^</) {
      return ($v, $expr) if $lev > 2;
      ($v2, $expr) = expr(substr($expr, 1), 2);
      return undef unless defined $v2;
      $v = (($v =~ /^\"/) ? $v lt $v2 : $v < $v2) ? 1 : 0;
    } elsif ($expr =~ /^==/) {
      return ($v, $expr) if $lev > 2;
      ($v2, $expr) = expr(substr($expr, 2), 2);
      return undef unless defined $v2;
      $v = (($v =~ /^\"/) ? $v eq $v2 : $v == $v2) ? 1 : 0;
    } elsif ($expr =~ /^!=/) {
      return ($v, $expr) if $lev > 2;
      ($v2, $expr) = expr(substr($expr, 2), 2);
      return undef unless defined $v2;
      $v = (($v =~ /^\"/) ? $v ne $v2 : $v != $v2) ? 1 : 0;
    } elsif ($expr =~ /^\+/) {
      return ($v, $expr) if $lev > 3;
      ($v2, $expr) = expr(substr($expr, 1), 3);
      return undef unless defined $v2;
      $v += $v2;
    } elsif ($expr =~ /^-/) {
      return ($v, $expr) if $lev > 3;
      ($v2, $expr) = expr(substr($expr, 1), 3);
      return undef unless defined $v2;
      $v -= $v2;
    } elsif ($expr =~ /^\*/) {
      ($v2, $expr) = expr(substr($expr, 1), 4);
      return undef unless defined $v2;
      $v *= $v2;
    } elsif ($expr =~ /^\//) {
      ($v2, $expr) = expr(substr($expr, 1), 4);
      return undef unless defined $v2 && 0 + $v2;
      $v /= $v2;
    } else {
      return ($v, $expr);
    }
  }
}

sub parse {
  my ($config, $specfile, $xspec) = @_;

  my $packname;
  my $packvers;
  my $packrel;
  my $exclarch;
  my @subpacks;
  my @packdeps;
  my $hasnfb;
  my %macros;
  my $ret = {};
  my $ifdeps;

  my $specdata;
  local *SPEC;
  if (ref($specfile) eq 'GLOB') {
    *SPEC = *$specfile;
  } elsif (ref($specfile) eq 'ARRAY') {
    $specdata = [ @$specfile ];
  } elsif (!open(SPEC, '<', $specfile)) {
    warn("$specfile: $!\n");
    $ret->{'error'} = "open $specfile: $!";
    return $ret;
  }
  my @macros = @{$config->{'macros'}};
  my $skip = 0;
  my $main_preamble = 1;
  my $inspec = 0;
  my $hasif = 0;
  while (1) {
    my $line;
    if (@macros) {
      $line = shift @macros;
      $hasif = 0 unless @macros;
    } elsif ($specdata) {
      $inspec = 1;
      last unless @$specdata;
      $line = shift @$specdata;
      if (ref $line) {
	$line = $line->[0]; # verbatim line
        push @$xspec, $line if $xspec;
        $xspec->[-1] = [ $line, undef ] if $xspec && $skip;
	next;
      }
    } else {
      $inspec = 1;
      $line = <SPEC>;
      last unless defined $line;
      chomp $line;
    }
    push @$xspec, $line if $inspec && $xspec;
    if ($line =~ /^#\s*neededforbuild\s*(\S.*)$/) {
      next if defined $hasnfb;
      $hasnfb = $1;
      next;
    }
    if ($line =~ /^\s*#/) {
      next unless $line =~ /^#!BuildIgnore/;
    }
    my $expandedline = '';
    if (!$skip) {
      my $tries = 0;
      while ($line =~ /^(.*?)%(\{([^\}]+)\}|[\?\!]*[0-9a-zA-Z_]+|%|\()(.*?)$/) {
	if ($tries++ > 1000) {
	  $line = 'MACRO';
	  last;
	}
	$expandedline .= $1;
	$line = $4;
	my $macname = defined($3) ? $3 : $2;
	my $macorig = $2;
	my $mactest = 0;
	if ($macname =~ /^\!\?/ || $macname =~ /^\?\!/) {
	  $mactest = -1;
	} elsif ($macname =~ /^\?/) {
	  $mactest = 1;
	}
	$macname =~ s/^[\!\?]+//;
	$macname =~ s/ .*//;
	my $macalt;
	($macname, $macalt) = split(':', $macname, 2);
	if ($macname eq '%') {
	  $expandedline .= '%';
	  next;
	} elsif ($macname eq '(') {
	  $line = 'MACRO';
	  last;
	} elsif ($macname eq 'define') {
	  if ($line =~ /^\s*([0-9a-zA-Z_]+)(\([^\)]*\))?\s*(.*?)$/) {
	    my $macname = $1;
	    my $macargs = $2;
	    my $macbody = $3;
	    $macbody = undef if $macargs;
	    $macros{$macname} = $macbody;
	  }
	  $line = '';
	  last;
	} elsif ($macname eq 'defined' || $macname eq 'with' || $macname eq 'undefined' || $macname eq 'without' || $macname eq 'bcond_with' || $macname eq 'bcond_without') {
	  my @args;
	  if ($macorig =~ /^\{(.*)\}$/) {
	    @args = split(' ', $1);
	    shift @args;
	  } else {
	    @args = split(' ', $line);
	    $line = '';
	  }
	  next unless @args;
	  if ($macname eq 'bcond_with') {
	    $macros{"with_$args[0]"} = 1 if exists $macros{"_with_$args[0]"};
	    next;
	  }
	  if ($macname eq 'bcond_without') {
	    $macros{"with_$args[0]"} = 1 unless exists $macros{"_without_$args[0]"};
	    next;
	  }
	  $args[0] = "with_$args[0]" if $macname eq 'with' || $macname eq 'without';
	  $line = ((exists($macros{$args[0]}) ? 1 : 0) ^ ($macname eq 'undefined' || $macname eq 'without' ? 1 : 0)).$line;
	} elsif (exists($macros{$macname})) {
	  if (!defined($macros{$macname})) {
	    $line = 'MACRO';
	    last;
	  }
	  $macalt = $macros{$macname} unless defined $macalt;
	  $macalt = '' if $mactest == -1;
	  $line = "$macalt$line";
	} elsif ($mactest) {
	  $macalt = '' if !defined($macalt) || $mactest == 1;
	  $line = "$macalt$line";
	} else {
	  $expandedline .= "%$macorig";
	}
      }
    }
    $line = $expandedline . $line;
    if ($line =~ /^\s*%else\b/) {
      $skip = 1 - $skip if $skip < 2;
      next;
    }
    if ($line =~ /^\s*%endif\b/) {
      $skip-- if $skip;
      next;
    }
    $skip++ if $skip && $line =~ /^\s*%if/;

    if ($skip) {
      $xspec->[-1] = [ $xspec->[-1], undef ] if $xspec;
      $ifdeps = 1 if $line =~ /^(BuildRequires|BuildConflicts|\#\!BuildIgnore):\s*(\S.*)$/i;
      next;
    }

    if ($line =~ /^\s*%ifarch(.*)$/) {
      my $arch = $macros{'_target_cpu'} || 'unknown';
      my @archs = grep {$_ eq $arch} split(/\s+/, $1);
      $skip = 1 if !@archs;
      $hasif = 1;
      next;
    }
    if ($line =~ /^\s*%ifnarch(.*)$/) {
      my $arch = $macros{'_target_cpu'} || 'unknown';
      my @archs = grep {$_ eq $arch} split(/\s+/, $1);
      $skip = 1 if @archs;
      $hasif = 1;
      next;
    }
    if ($line =~ /^\s*%ifos(.*)$/) {
      my $os = $macros{'_target_os'} || 'unknown';
      my @oss = grep {$_ eq $os} split(/\s+/, $1);
      $skip = 1 if !@oss;
      $hasif = 1;
      next;
    }
    if ($line =~ /^\s*%ifnos(.*)$/) {
      my $os = $macros{'_target_os'} || 'unknown';
      my @oss = grep {$_ eq $os} split(/\s+/, $1);
      $skip = 1 if @oss;
      $hasif = 1;
      next;
    }
    if ($line =~ /^\s*%if(.*)$/) {
      my ($v, $r) = expr($1);
      $v = 0 if $v && $v eq '\"\"';
      $v =~ s/^0+/0/ if $v;
      $skip = 1 unless $v;
      $hasif = 1;
      next;
    }
    if ($main_preamble && ($line =~ /^Name:\s*(\S+)/i)) {
      $packname = $1;
      $macros{'name'} = $packname;
    }
    if ($main_preamble && ($line =~ /^Version:\s*(\S+)/i)) {
      $packvers = $1;
      $macros{'version'} = $packvers;
    }
    if ($main_preamble && ($line =~ /^Release:\s*(\S+)/i)) {
      $packrel = $1;
      $macros{'release'} = $packrel;
    }
    if ($main_preamble && ($line =~ /^ExclusiveArch:\s*(.*)/i)) {
      $exclarch ||= [];
      push @$exclarch, split(' ', $1);
    }
    if ($main_preamble && ($line =~ /^(BuildRequires|BuildConflicts|\#\!BuildIgnore):\s*(\S.*)$/i)) {
      my $what = $1;
      my $deps = $2;
      $ifdeps = 1 if $hasif;
      my @deps = $deps =~ /([^\s\[\(,]+)(\s+[<=>]+\s+[^\s\[,]+)?(\s+\[[^\]]+\])?[\s,]*/g;
      my $replace = 0;
      my @ndeps = ();
      while (@deps) {
	my ($pack, $vers, $qual) = splice(@deps, 0, 3);
	if (defined($qual)) {
          $replace = 1;
          my $arch = $macros{'_target_cpu'} || '';
          my $proj = $macros{'_target_project'} || '';
	  $qual =~ s/^\s*\[//;
	  $qual =~ s/\]$//;
	  my $isneg = 0;
	  my $bad;
	  for my $q (split('[\s,]', $qual)) {
	    $isneg = 1 if $q =~ s/^\!//;
	    $bad = 1 if !defined($bad) && !$isneg;
	    if ($isneg) {
	      if ($q eq $arch || $q eq $proj) {
		$bad = 1;
		last;
	      }
	    } elsif ($q eq $arch || $q eq $proj) {
	      $bad = 0;
	    }
	  }
	  next if $bad;
	}
	push @ndeps, $pack;
      }

      $replace = 1 if grep {/^-/} @ndeps;
      if ($what ne 'BuildRequires') {
	push @packdeps, map {"-$_"} @ndeps;
	next;
      }
      if (defined($hasnfb)) {
        next unless $xspec;
        if ((grep {$_ eq 'glibc' || $_ eq 'rpm' || $_ eq 'gcc' || $_ eq 'bash'} @ndeps) > 2) {
          # ignore old generetad BuildRequire lines.
	  $xspec->[-1] = [ $xspec->[-1], undef ];
	}
	next;
      }
      push @packdeps, @ndeps;
      next unless $xspec && $inspec;
      if ($replace) {
	my @cndeps = grep {!/^-/} @ndeps;
	if (@cndeps) {
          $xspec->[-1] = [ $xspec->[-1], "BuildRequires:  ".join(' ', @cndeps) ];
	} else {
          $xspec->[-1] = [ $xspec->[-1], ''];
	}
      }
      next;
    }

    if ($line =~ /^\s*%package\s+(-n\s+)?(\S+)/) {
      if ($1) {
	push @subpacks, $2;
      } else {
	push @subpacks, "$packname-$2" if defined $packname;
      }
    }

    if ($line =~ /^\s*%(package|prep|build|install|check|clean|preun|postun|pretrans|posttrans|pre|post|files|changelog|description|triggerpostun|triggerun|triggerin|trigger|verifyscript)/) {
      $main_preamble = 0;
    }
  }
  close SPEC unless ref $specfile;
  if (defined($hasnfb)) {
    if (!@packdeps) {
      @packdeps = split(' ', $hasnfb);
    }
  }
  unshift @subpacks, $packname;
  $ret->{'name'} = $packname;
  $ret->{'version'} = $packvers;
  $ret->{'release'} = $packrel if defined $packrel;
  $ret->{'subpacks'} = \@subpacks;
  $ret->{'exclarch'} = $exclarch if defined $exclarch;
  $ret->{'deps'} = \@packdeps;
  $ret->{'configdependent'} = 1 if $ifdeps;
  return $ret;
}

###########################################################################

my %rpmstag = (
  "SIGTAG_SIZE"    => 1000,     # /*!< internal Header+Payload size in bytes. */
  "SIGTAG_MD5"     => 1004,     # /*!< internal MD5 signature. */
  "NAME"           => 1000,
  "VERSION"        => 1001,
  "RELEASE"        => 1002,
  "EPOCH"          => 1003,
  "ARCH"           => 1022,
  "OLDFILENAMES"   => 1027,
  "SOURCERPM"      => 1044,
  "PROVIDENAME"    => 1047,
  "REQUIREFLAGS"   => 1048,
  "REQUIRENAME"    => 1049,
  "REQUIREVERSION" => 1050,
  "NOSOURCE"       => 1051,
  "NOPATCH"        => 1052,
  "PROVIDEFLAGS"   => 1112,
  "PROVIDEVERSION" => 1113,
  "DIRINDEXES"     => 1116,
  "BASENAMES"      => 1117,
  "DIRNAMES"       => 1118,
);

sub rpmq {
  my ($rpm, @stags) = @_;

  my @sigtags = grep {/^SIGTAG_/} @stags;
  @stags = grep {!/^SIGTAG_/} @stags;
  my $dosigs = @sigtags && !@stags;
  @stags = @sigtags if $dosigs;

  my $need_filenames = grep { $_ eq 'FILENAMES' } @stags;
  push @stags, 'BASENAMES', 'DIRNAMES', 'DIRINDEXES', 'OLDFILENAMES' if $need_filenames;
  @stags = grep { $_ ne 'FILENAMES' } @stags if $need_filenames;

  my %stags = map {0 + ($rpmstag{$_} || $_) => $_} @stags; 

  my ($magic, $sigtype, $headmagic, $cnt, $cntdata, $lead, $head, $index, $data, $tag, $type, $offset, $count);

  local *RPM;
  if (ref($rpm) eq 'ARRAY') {
    ($headmagic, $cnt, $cntdata) = unpack('N@8NN', $rpm->[0]);
    if ($headmagic != 0x8eade801) {
      warn("Bad rpm\n");
      return ();
    }
    if (length($rpm->[0]) < 16 + $cnt * 16 + $cntdata) {
      warn("Bad rpm\n");
      return ();
    }
    $index = substr($rpm->[0], 16, $cnt * 16);
    $data = substr($rpm->[0], 16 + $cnt * 16, $cntdata);
  } else {
    if (ref($rpm) eq 'GLOB') {
      *RPM = *$rpm;
    } elsif (!open(RPM, '<', $rpm)) {
      warn("$rpm: $!\n");
      return ();
    }
    if (read(RPM, $lead, 96) != 96) {
      warn("Bad rpm $rpm\n");
      close RPM unless ref($rpm);
      return ();
    }
    ($magic, $sigtype) = unpack('N@78n', $lead);
    if ($magic != 0xedabeedb || $sigtype != 5) {
      warn("Bad rpm $rpm\n");
      close RPM unless ref($rpm);
      return ();
    }
    if (read(RPM, $head, 16) != 16) {
      warn("Bad rpm $rpm\n");
      close RPM unless ref($rpm);
      return ();
    }
    ($headmagic, $cnt, $cntdata) = unpack('N@8NN', $head);
    if ($headmagic != 0x8eade801) {
      warn("Bad rpm $rpm\n");
      close RPM unless ref($rpm);
      return ();
    }
    if (read(RPM, $index, $cnt * 16) != $cnt * 16) {
      warn("Bad rpm $rpm\n");
      close RPM unless ref($rpm);
      return ();
    }
    $cntdata = ($cntdata + 7) & ~7;
    if (read(RPM, $data, $cntdata) != $cntdata) {
      warn("Bad rpm $rpm\n");
      close RPM unless ref($rpm);
      return ();
    }
  }

  my %res = ();
  if (@sigtags && !$dosigs) {
    %res = &rpmq(["$head$index$data"], @sigtags);
  }
  if (ref($rpm) eq 'ARRAY' && !$dosigs && @stags && @$rpm > 1) {
    my %res2 = &rpmq([ $rpm->[1] ], @stags);
    %res = (%res, %res2);
    return %res;
  }
  if (ref($rpm) ne 'ARRAY' && !$dosigs && @stags) {
    if (read(RPM, $head, 16) != 16) {
      warn("Bad rpm $rpm\n");
      close RPM unless ref($rpm);
      return ();
    }
    ($headmagic, $cnt, $cntdata) = unpack('N@8NN', $head);
    if ($headmagic != 0x8eade801) {
      warn("Bad rpm $rpm\n");
      close RPM unless ref($rpm);
      return ();
    }
    if (read(RPM, $index, $cnt * 16) != $cnt * 16) {
      warn("Bad rpm $rpm\n");
      close RPM unless ref($rpm);
      return ();
    }
    if (read(RPM, $data, $cntdata) != $cntdata) {
      warn("Bad rpm $rpm\n");
      close RPM unless ref($rpm);
      return ();
    }
  }
  close RPM unless ref($rpm);

  return %res unless @stags;

  while($cnt-- > 0) {
    ($tag, $type, $offset, $count, $index) = unpack('N4a*', $index);
    $tag = 0+$tag;
    if ($stags{$tag}) {
      eval {
        my $otag = $stags{$tag};
        if ($type == 0) {
          $res{$otag} = [ '' ];
        } elsif ($type == 1) {
          $res{$otag} = [ unpack("\@${offset}c$count", $data) ];
        } elsif ($type == 2) {
          $res{$otag} = [ unpack("\@${offset}c$count", $data) ];
        } elsif ($type == 3) {
          $res{$otag} = [ unpack("\@${offset}n$count", $data) ];
        } elsif ($type == 4) {
          $res{$otag} = [ unpack("\@${offset}N$count", $data) ];
        } elsif ($type == 5) {
          $res{$otag} = [ undef ];
        } elsif ($type == 6) {
          $res{$otag} = [ unpack("\@${offset}Z*", $data) ];
        } elsif ($type == 7) {
          $res{$otag} = [ unpack("\@${offset}a$count", $data) ];
        } elsif ($type == 8 || $type == 9) {
          my $d = unpack("\@${offset}a*", $data);
          my @res = split("\0", $d, $count + 1);
          $res{$otag} = [ splice @res, 0, $count ];
        } else {
          $res{$otag} = [ undef ];
        }
      };
      if ($@) {
        warn("Bad rpm $rpm: $@\n");
        return ();
      }
    }
  }

  if ($need_filenames) {
    if ($res{'OLDFILENAMES'}) {
      $res{'FILENAMES'} = [ @{$res{'OLDFILENAMES'}} ];
    } else {
      my $i = 0;
      $res{'FILENAMES'} = [ map {"$res{'DIRNAMES'}->[$res{'DIRINDEXES'}->[$i++]]$_"} @{$res{'BASENAMES'}} ];
    }
  }

  return %res;
}

sub add_flagsvers {
  my $res = shift;
  my $name = shift;
  my $flags = shift;
  my $vers = shift;

  return unless $res;
  my @flags = @{$res->{$flags} || []};
  my @vers = @{$res->{$vers} || []};
  for (@{$res->{$name}}) {
    if (@flags && ($flags[0] & 0xe) && @vers) {
      $_ .= ' ';
      $_ .= '<' if $flags[0] & 2;
      $_ .= '>' if $flags[0] & 4;
      $_ .= '=' if $flags[0] & 8;
      $_ .= " $vers[0]";
    }
    shift @flags;
    shift @vers;
  }
}

sub verscmp_part {
  my ($s1, $s2) = @_;
  if (!defined($s1)) {
    return defined($s2) ? -1 : 0;
  }
  return 1 if !defined $s2;
  return 0 if $s1 eq $s2;
  while (1) {
    $s1 =~ s/^[^a-zA-Z0-9]+//;
    $s2 =~ s/^[^a-zA-Z0-9]+//;
    my ($x1, $x2, $r);
    if ($s1 =~ /^([0-9]+)(.*?)$/) {
      $x1 = $1;
      $s1 = $2;
      $s2 =~ /^([0-9]*)(.*?)$/;
      $x2 = $1;
      $s2 = $2;
      return 1 if $x2 eq '';
      $x1 =~ s/^0+//;
      $x2 =~ s/^0+//;
      $r = length($x1) - length($x2) || $x1 cmp $x2;
    } elsif ($s1 ne '' && $s2 ne '') {
      $s1 =~ /^([a-zA-Z]*)(.*?)$/;
      $x1 = $1;
      $s1 = $2;
      $s2 =~ /^([a-zA-Z]*)(.*?)$/;
      $x2 = $1;
      $s2 = $2;
      return -1 if $x1 eq '' || $x2 eq '';
      $r = $x1 cmp $x2;
    }
    return $r > 0 ? 1 : -1 if $r;
    if ($s1 eq '') {
      return $s2 eq '' ? 0 : -1;
    }
    return 1 if $s2 eq ''
  }
}

sub verscmp {
  my ($s1, $s2, $dtest) = @_;

  return 0 if $s1 eq $s2;
  my ($e1, $v1, $r1) = $s1 =~ /^(?:(\d+):)?(.*?)(?:-([^-]*))?$/s;
  $e1 = 0 unless defined $e1;
  my ($e2, $v2, $r2) = $s2 =~ /^(?:(\d+):)?(.*?)(?:-([^-]*))?$/s;
  $e2 = 0 unless defined $e2;
  if ($e1 ne $e2) {
    my $r = verscmp_part($e1, $e2);
    return $r if $r;
  }
  return 0 if $dtest && ($v1 eq '' || $v2 eq '');
  if ($v1 ne $v2) {
    my $r = verscmp_part($v1, $v2);
    return $r if $r;
  }
  $r1 = '' unless defined $r1;
  $r2 = '' unless defined $r2;
  return 0 if $dtest && ($r1 eq '' || $r2 eq '');
  if ($r1 ne $r2) {
    return verscmp_part($r1, $r2);
  }
  return 0;
}

sub query {
  my ($handle, $withevra) = @_;

  my %res = rpmq($handle, qw{NAME SOURCERPM NOSOURCE NOPATCH SIGTAG_MD5 PROVIDENAME PROVIDEFLAGS PROVIDEVERSION REQUIRENAME REQUIREFLAGS REQUIREVERSION}, ($withevra ? qw{EPOCH VERSION RELEASE ARCH}: ()));
  return undef unless %res;
  my $src = $res{'SOURCERPM'}->[0];
  $src = '' unless defined $src;
  $src =~ s/-[^-]*-[^-]*\.[^\.]*\.rpm//;
  add_flagsvers(\%res, 'PROVIDENAME', 'PROVIDEFLAGS', 'PROVIDEVERSION');
  add_flagsvers(\%res, 'REQUIRENAME', 'REQUIREFLAGS', 'REQUIREVERSION');
  my $data = {
    name => $res{'NAME'}->[0],
    hdrmd5 => unpack('H32', $res{'SIGTAG_MD5'}->[0]),
    provides => [ grep {!/^rpmlib\(/ && !/^\//} @{$res{'PROVIDENAME'} || []} ],
    requires => [ grep {!/^rpmlib\(/ && !/^\//} @{$res{'REQUIRENAME'} || []} ],
  };
  $data->{'source'} = $src if $src ne '';
  if ($withevra) {
    my $arch = $res{'ARCH'}->[0];
    $arch = $res{'NOSOURCE'} || $res{'NOPATCH'} ? 'nosrc' : 'src' unless $src ne '';
    $data->{'version'} = $res{'VERSION'}->[0];
    $data->{'release'} = $res{'RELEASE'}->[0];
    $data->{'arch'} = $arch;
    $data->{'epoch'} = $res{'EPOCH'}->[0] if exists $res{'EPOCH'};
  }
  return $data;
}

sub queryhdrmd5 {
  my ($bin) = @_;

  local *F;
  open(F, '<', $bin) || die("$bin: $!\n");
  my $buf = '';
  my $l;  
  while (length($buf) < 96 + 16) { 
    $l = sysread(F, $buf, 4096, length($buf));
    if (!$l) {
      warn("$bin: read error\n");
      close(F);
      return undef;
    }
  }
  my ($magic, $sigtype) = unpack('N@78n', $buf);
  if ($magic != 0xedabeedb || $sigtype != 5) {
    warn("$bin: not a rpm (bad magic of header type)\n");
    close(F);
    return undef;
  }
  my ($headmagic, $cnt, $cntdata) = unpack('@96N@104NN', $buf);
  if ($headmagic != 0x8eade801) {
    warn("$bin: not a rpm (bad sig header magic)\n");
    close(F);
    return undef;
  }
  my $hlen = 96 + 16 + $cnt * 16 + $cntdata;
  $hlen = ($hlen + 7) & ~7;
  while (length($buf) < $hlen) {
    $l = sysread(F, $buf, 4096, length($buf));
    if (!$l) {
      warn("$bin: read error\n");
      close(F);
      return undef;
    }
  }
  close F;
  my $idxarea = substr($buf, 96 + 16, $cnt * 16);
  if ($idxarea !~ /\A(?:.{16})*\000\000\003\354\000\000\000\007(....)\000\000\000\020/s) {
    warn("$bin: no md5 signature header\n");
    return undef;
  }
  my $md5off = unpack('N', $1);
  if ($md5off >= $cntdata) {
    warn("$bin: bad md5 offset\n");
    return undef;
  }
  $md5off += 96 + 16 + $cnt * 16;
  return unpack("\@${md5off}H32", $buf);
}

1;
