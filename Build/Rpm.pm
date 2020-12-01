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

package Build::Rpm;

our $unfilteredprereqs = 0;
our $conflictdeps = 0;
our $includecallback;

use strict;

use Digest::MD5;

sub expr_boolify {
  my ($v) = @_;
  return !defined($v) || $v eq '"' || $v =~ /^(?:0*$|v)/s ? 0 : 1;
}

sub expr_vcmp {
  my ($v1, $v2, $rr) = @_;
  my $r = verscmp(substr($v1, 1), substr($v2, 1));
  return ($r < 0 ? 1 : $r > 0 ? 4 : 2) & $rr ? 1 : 0;
}

sub expr_dummyexpander {
  return '';
}

sub expr_expand {
  my ($v, $expr, $xp, $r) = @_;
  while (1) {
    if ($expr =~ /^%%/s) {
      $v .= substr($expr, 0, 2, '');
    } elsif ($expr =~ /^%/s) {
      my $m = macroend($expr);
      $v .= substr($expr, 0, length($m), '');
    } elsif ($expr =~ /$r/) {
      $v .= substr($expr, 0, length($1), '');
    } else {
      return ($xp->($v), $expr);
    }
  }
}

sub expr {
  my ($expr, $lev, $xp) = @_;

  $lev ||= 0;
  my ($v, $v2);
  $expr =~ s/^\s+//;
  my $t = substr($expr, 0, 1);
  if ($t eq '(') {
    ($v, $expr) = expr(substr($expr, 1), 0, $xp);
    return undef unless defined $v;
    return undef unless $expr =~ s/^\)//;
  } elsif ($t eq '!') {
    ($v, $expr) = expr(substr($expr, 1), 6, $xp);
    return undef unless defined $v;
    $v = expr_boolify($v) ? 0 : 1;
  } elsif ($t eq '-') {
    ($v, $expr) = expr(substr($expr, 1), 6, $xp);
    return undef unless defined $v;
    $v = -$v;
  } elsif ($expr =~ /^([0-9]+)(.*?)$/s || ($xp && $expr =~ /^(%)(.*)$/)) {
    $v = $1;
    $expr = $2;
    ($v, $expr) = expr_expand('0', "$1$2", $xp, qr/^([0-9]+)/) if $xp;
    $v = 0 + $v;
  } elsif ($expr =~ /^v\"(.*?)(\".*)$/s) {
    $v = "v$1";		# version
    $expr = $2;
    ($v, $expr) = expr_expand('v', substr("$1$2", 2), $xp, qr/^([^%\"]+)/) if $xp;
    $expr =~ s/^\"//s;
  } elsif ($expr =~ /^(\".*?)(\".*)$/s) {
    $v = $1;
    $expr = $2;
    ($v, $expr) = expr_expand('"', substr("$1$2", 1), $xp, qr/^([^%\"]+)/) if $xp;
    $expr =~ s/^\"//s;
  } elsif ($expr =~ /^([a-zA-Z][a-zA-Z_0-9]*)(.*)$/s) {
    # actually no longer supported with new rpm versions
    $v = "\"$1";
    $expr = $2;
  } else {
    return;
  }
  return ($v, $expr) if $lev >= 6;
  while (1) {
    $expr =~ s/^\s+//;
    if ($expr =~ /^&&/) {
      return ($v, $expr) if $lev >= 2;
      my $b = expr_boolify($v);
      ($v2, $expr) = expr(substr($expr, 2), 2, $xp && !$b ? \&expr_dummyexpander : $xp);
      return undef unless defined $v2;
      $v = $v2 if $b;
    } elsif ($expr =~ /^\|\|/) {
      return ($v, $expr) if $lev >= 2;
      my $b = expr_boolify($v);
      ($v2, $expr) = expr(substr($expr, 2), 2, $xp && $b ? \&expr_dummyexpander : $xp);
      return undef unless defined $v2;
      $v = $v2 unless $b;
    } elsif ($expr =~ /^>=/) {
      return ($v, $expr) if $lev >= 3;
      ($v2, $expr) = expr(substr($expr, 2), 3, $xp);
      return undef unless defined $v2;
      $v = (($v =~ /^v/) ? expr_vcmp($v, $v2, 6) : ($v =~ /^\"/) ? $v ge $v2 : $v >= $v2) ? 1 : 0;
    } elsif ($expr =~ /^>/) {
      return ($v, $expr) if $lev >= 3;
      ($v2, $expr) = expr(substr($expr, 1), 3, $xp);
      return undef unless defined $v2;
      $v = (($v =~ /^v/) ? expr_vcmp($v, $v2, 4) : ($v =~ /^\"/) ? $v gt $v2 : $v > $v2) ? 1 : 0;
    } elsif ($expr =~ /^<=/) {
      return ($v, $expr) if $lev >= 3;
      ($v2, $expr) = expr(substr($expr, 2), 3, $xp);
      return undef unless defined $v2;
      $v = (($v =~ /^v/) ? expr_vcmp($v, $v2, 3) : ($v =~ /^\"/) ? $v le $v2 : $v <= $v2) ? 1 : 0;
    } elsif ($expr =~ /^</) {
      return ($v, $expr) if $lev >= 3;
      ($v2, $expr) = expr(substr($expr, 1), 3, $xp);
      return undef unless defined $v2;
      $v = (($v =~ /^v/) ? expr_vcmp($v, $v2, 1) : ($v =~ /^\"/) ? $v lt $v2 : $v < $v2) ? 1 : 0;
    } elsif ($expr =~ /^==/) {
      return ($v, $expr) if $lev >= 3;
      ($v2, $expr) = expr(substr($expr, 2), 3, $xp);
      return undef unless defined $v2;
      $v = (($v =~ /^v/) ? expr_vcmp($v, $v2, 2) : ($v =~ /^\"/) ? $v eq $v2 : $v == $v2) ? 1 : 0;
    } elsif ($expr =~ /^!=/) {
      return ($v, $expr) if $lev >= 3;
      ($v2, $expr) = expr(substr($expr, 2), 3, $xp);
      return undef unless defined $v2;
      $v = (($v =~ /^v/) ? expr_vcmp($v, $v2, 5) : ($v =~ /^\"/) ? $v ne $v2 : $v != $v2) ? 1 : 0;
    } elsif ($expr =~ /^\+/) {
      return ($v, $expr) if $lev >= 4;
      ($v2, $expr) = expr(substr($expr, 1), 4, $xp);
      return undef unless defined $v2;
      if ($v =~ /^\"/ && $v2 =~ s/^\"//) {
	$v .= $v2;
      } else {
        $v += $v2;
      }
    } elsif ($expr =~ /^-/) {
      return ($v, $expr) if $lev >= 4;
      ($v2, $expr) = expr(substr($expr, 1), 4, $xp);
      return undef unless defined $v2;
      $v -= $v2;
    } elsif ($expr =~ /^\*/) {
      ($v2, $expr) = expr(substr($expr, 1), 5, $xp);
      return undef unless defined $v2;
      $v *= $v2;
    } elsif ($expr =~ /^\//) {
      ($v2, $expr) = expr(substr($expr, 1), 5, $xp);
      return undef unless defined $v2 && 0 + $v2;
      $v /= $v2;
    } elsif ($expr =~ /^\?/) {
      return ($v, $expr) if $lev > 1;
      my $b = expr_boolify($v);
      ($v, $expr) = expr(substr($expr, 1), 1, $xp && !$b ? \&expr_dummyexpander : $xp);
      warn("syntax error while parsing ternary in $_[0]\n") unless defined($v) && $expr =~ s/^://;
      ($v2, $expr) = expr($expr, 1, $xp && $b ? \&expr_dummyexpander : $xp);
      return undef unless defined $v2;
      $v = $v2 unless $b;
    } elsif ($expr =~ /^([=&|])/) {
      warn("syntax error while parsing $1$1\n");
      return ($v, $expr);
    } else {
      return ($v, $expr);
    }
  }
}

sub adaptmacros {
  my ($macros, $optold, $optnew) = @_;
  for (keys %$optold) {
    delete $macros->{$_};
  }
  for (keys %$optnew) {
    $macros->{$_} = $optnew->{$_};
  }
  return $optnew;
}

sub grabargs {
  my ($macname, $getopt, @args) = @_;
  my %m;
  $m{'0'} = $macname;
  $m{'**'} = join(' ', @args);
  my %go;
  %go = ($getopt =~ /(.)(:*)/sg) if defined $getopt;
  while (@args && $args[0] =~ s/^-//) {
    my $o = shift @args;
    last if $o eq '-';
    while ($o =~ /^(.)(.*)$/) {
      if ($go{$1}) {
	my $arg = $2;
	$arg = shift(@args) if @args && $arg eq '';
	$m{"-$1"} = "-$1 $arg";
	$m{"-$1*"} = $arg;
	last;
      }
      $m{"-$1"} = "-$1";
      $o = $2;
    }
  }
  $m{'#'} = scalar(@args);
  my $i = 1;
  for (@args) {
    $m{$i} = $_;
    $i++;
  }
  $m{'*'} = join(' ', @args);
  return \%m;
}

sub initmacros {
  my ($config, $macros, $macros_args) = @_;
  for my $line (@{$config->{'macros'} || []}) {
    next unless $line =~ /^%define\s*([0-9a-zA-Z_]+)(?:\(([^\)]*)\))?\s*(.*?)$/;
    my $macname = $1;
    my $macargs = $2;
    my $macbody = $3;
    if (defined $macargs) {
      $macros_args->{$macname} = $macargs;
    } else {
      delete $macros_args->{$macname};
    }
    $macros->{$macname} = $macbody;
  }
}

sub macroend {
  my ($expr) = @_;
  if ($expr =~ /^%([\(\{\[])/s) {
    my $o = $1;
    my $c = $o eq '[' ? ']' : $o eq '(' ? ')' : '}';
    my $m = substr($expr, 0, 2, '');
    my $cnt = 1;
    my $r = qr/^(.*?)([$o$c\\])/s;
    while ($expr =~ /$r/) {
      $m .= substr($expr, 0, length($1) + 1, '');
      if ($2 eq '\\') {
	$m .= substr($expr, 0, 1, '');
      } elsif ($2 eq $o) {
	$cnt++;
      } elsif ($2 eq $c) {
	return $m if --$cnt == 0;
      }
    }
    return "$m$expr";
  }
  return $1 if $expr =~ /^(%[?!]*-?[a-zA-Z0-9_]*(?:\*|\*\*|\#)?)/s;
}

sub expandmacros {
  my ($config, $line, $lineno, $macros, $macros_args, $tries) = @_;

  if (!$macros) {
    $macros = {};
    $macros_args = {};
    initmacros($config, $macros, $macros_args);
  }
  my $expandedline = '';
  $tries ||= 0;
  my @expandstack;
  my $optmacros = {};
  # newer perls: \{((?:(?>[^{}]+)|(?2))*)\}
reexpand:
  while ($line =~ /^(.*?)%(\{([^\}]+)\}|[\?\!]*[0-9a-zA-Z_]+|%|\*\*?|#|\(|\[)(.*?)$/s) {
    if ($tries++ > 1000) {
      print STDERR "Warning: spec file parser ",($lineno?" line $lineno":''),": macro too deeply nested\n" if $config->{'warnings'};
      $line = 'MACRO';
      last;
    }
    $expandedline .= $1;
    $line = $4;
    if ($2 eq '%') {
      $expandedline .= '%';
      next;
    }
    my $macname = defined($3) ? $3 : $2;
    my $macorig = $2;
    my $macdata;
    my $macalt;
    if (defined($3)) {
      if ($macname =~ /[{\\]/) {	# tricky, use macroend
	$macname = macroend("%$macorig$line");
	$line = substr("%$macorig$line", length($macname));
        $macorig = substr($macname, 1);
	$macname =~ s/^%\{//s;
	$macname =~ s/\}$//s;
      }
      $macdata = '';
      if ($macname =~ /^([^\s:]+)([\s:])(.*)$/) {
	$macname = $1;
	if ($2 eq ':') {
	  $macalt = $3;
	} else {
	  $macdata = $3;
	}
      }
    }
    my $mactest = 0;
    if ($macname =~ /^\!\?/ || $macname =~ /^\?\!/) {
      $mactest = -1;
    } elsif ($macname =~ /^\?/) {
      $mactest = 1;
    }
    $macname =~ s/^[\!\?]+//;
    if ($macname eq '(') {
      print STDERR "Warning: spec file parser",($lineno?" line $lineno":''),": can't expand %(...)\n" if $config->{'warnings'};
      $line = 'MACRO';
      last;
    } elsif ($macname eq '[') {
      $macalt = macroend("%[$line");
      $line = substr($line, length($macalt) - 2);
      $macalt =~ s/^%\[//;
      $macalt =~ s/\]$//;
      my $xp = sub {expandmacros($config, $_[0], $lineno, $macros, $macros_args, $tries)};
      $macalt = (expr($macalt, 0, $xp))[0];
      $macalt =~ s/^[v\"]//;	# stringify
      $expandedline .= $macalt;
    } elsif ($macname eq 'define' || $macname eq 'global') {
      my $isglobal = $macname eq 'global' ? 1 : 0;
      if ($line =~ /^\s*([0-9a-zA-Z_]+)(?:\(([^\)]*)\))?\s*(.*?)$/) {
	my $macname = $1;
	my $macargs = $2;
	my $macbody = $3;
	$macbody = expandmacros($config, $macbody, $lineno, $macros, $macros_args, $tries) if $isglobal;
	if (defined $macargs) {
	  $macros_args->{$macname} = $macargs;
	} else {
	  delete $macros_args->{$macname};
	}
	$macros->{$macname} = $macbody;
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
	$macros->{"with_$args[0]"} = 1 if exists $macros->{"_with_$args[0]"};
	next;
      }
      if ($macname eq 'bcond_without') {
	$macros->{"with_$args[0]"} = 1 unless exists $macros->{"_without_$args[0]"};
	next;
      }
      $args[0] = "with_$args[0]" if $macname eq 'with' || $macname eq 'without';
      $line = ((exists($macros->{$args[0]}) ? 1 : 0) ^ ($macname eq 'undefined' || $macname eq 'without' ? 1 : 0)).$line;
    } elsif ($macname eq 'expand') {
      $macalt = $macros->{$macname} unless defined $macalt;
      $macalt = '' if $mactest == -1;
      push @expandstack, ($expandedline, $line, undef);
      $line = $macalt;
      $expandedline = '';
    } elsif ($macname eq 'expr') {
      $macalt = $macros->{$macname} unless defined $macalt;
      $macalt = '' if $mactest == -1;
      $macalt = expandmacros($config, $macalt, $lineno, $macros, $macros_args, $tries);
      $macalt = (expr($macalt))[0];
      $macalt =~ s/^[v\"]//;	# stringify
      $expandedline .= $macalt;
    } elsif (exists($macros->{$macname})) {
      if (!defined($macros->{$macname})) {
	print STDERR "Warning: spec file parser",($lineno?" line $lineno":''),": can't expand '$macname'\n" if $config->{'warnings'};
	$line = 'MACRO';
	last;
      }
      if (defined($macros_args->{$macname})) {
	# macro with args!
	if (!defined($macdata)) {
	  $line =~ /^\s*([^\n]*).*$/;
	  $macdata = $1;
	  $line = '';
	}
	push @expandstack, ($expandedline, $line, $optmacros);
	$optmacros = adaptmacros($macros, $optmacros, grabargs($macname, $macros_args->{$macname}, split(' ', $macdata)));
	$line = $macros->{$macname};
	$expandedline = '';
	next;
      }
      $macalt = $macros->{$macname} unless defined $macalt;
      $macalt = '' if $mactest == -1;
      if ($macalt =~ /%/) {
	push @expandstack, ('', $line, 1) if $line ne '';
	$line = $macalt;
      } else {
	$expandedline .= $macalt;
      }
    } elsif ($mactest) {
      $macalt = '' if !defined($macalt) || $mactest == 1;
      if ($macalt =~ /%/) {
	push @expandstack, ('', $line, 1) if $line ne '';
	$line = $macalt;
      } else {
	$expandedline .= $macalt;
      }
    } else {
      $expandedline .= "%$macorig" unless $macname =~ /^-/;
    }
  }
  $line = $expandedline . $line;
  if (@expandstack) {
    my $m = pop(@expandstack);
    if ($m) {
      $optmacros = adaptmacros($macros, $optmacros, $m) if ref $m;
      $expandstack[-2] .= $line;
      $line = pop(@expandstack);
      $expandedline = pop(@expandstack);
    } else {
      my $todo = pop(@expandstack);
      $expandedline = pop(@expandstack);
      push @expandstack, ('', $todo, 1) if $todo ne '';
    }
    goto reexpand;
  }
  return $line;
}

sub splitdeps {
  my ($d) = @_;
  my @deps;
  $d =~ s/^[\s,]+//;
  while ($d ne '') {
    if ($d =~ /^\(/) {
      my @s = split(' ', $d);
      push @deps, shiftrich(\@s), undef, undef;
      $d = join(' ', @s);
    } else {
      last unless $d =~ s/([^\s\[,]+)(\s+[<=>]+\s+[^\s\[,]+)?(\s+\[[^\]]+\])?[\s,]*//;
      push @deps, $1, $2, $3;
    }
  }
  return @deps;
}

# xspec may be passed as array ref to return the parsed spec files
# an entry in the returned array can be
# - a string: verbatim line from the original file
# - a two element array ref:
#   - [0] original line
#   - [1] undef: line unused due to %if
#   - [1] scalar: line after macro expansion. Only set if it's a build deps
#                 line and build deps got modified or 'save_expanded' is set in
#                 config
sub parse {
  my ($config, $specfile, $xspec) = @_;

  my $packname;
  my $exclarch;
  my $badarch;
  my @subpacks;
  my @packdeps;
  my @prereqs;
  my $hasnfb;
  my $nfbline;
  my %macros;
  my %macros_args;
  my $ret = {};
  my $ifdeps;
  my %autonum = (patch => 0, source => 0);

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
  
  initmacros($config, \%macros, \%macros_args);
  my $skip = 0;
  my $main_preamble = 1;
  my $preamble = 1;
  my $hasif = 0;
  my $lineno = 0;
  my @includelines;
  my $includenum = 0;
  my $obspackage = defined($config->{'obspackage'}) ? $config->{'obspackage'} : '@OBS_PACKAGE@';
  my $buildflavor = defined($config->{'buildflavor'}) ? $config->{'buildflavor'} : '';
  while (1) {
    my $line;
    my $doxspec = $xspec ? 1 : 0;
    if (@includelines) {
      $line = shift(@includelines);
      $includenum = 0 unless @includelines;
      $doxspec = 0;	# only record lines from main file
    } elsif ($specdata) {
      last unless @$specdata;
      $line = shift @$specdata;
      ++$lineno;
      if (ref $line) {
	$line = $line->[0]; # verbatim line, used for macro collection
	push @$xspec, $line if $doxspec;
	$xspec->[-1] = [ $line, undef ] if $doxspec && $skip;
	next;
      }
    } else {
      $line = <SPEC>;
      last unless defined $line;
      chomp $line;
      ++$lineno;
    }
    push @$xspec, $line if $doxspec;
    if ($line =~ /^#\s*neededforbuild\s*(\S.*)$/) {
      if (defined $hasnfb) {
	$xspec->[-1] = [ $xspec->[-1], undef ] if $doxspec;
	next;
      }
      $hasnfb = $1;
      $nfbline = \$xspec->[-1] if $doxspec;
      next;
    }
    if ($line =~ /^\s*#/) {
      next unless $line =~ /^#!Build(?:Ignore|Conflicts|Requires)\s*:/i;
    }
    if (!$skip && ($line =~ /%/)) {
      $line = expandmacros($config, $line, $lineno, \%macros, \%macros_args);
    }
    if ($line =~ /^\s*%(?:elif|elifarch|elifos)\b/) {
      $skip = 1 if !$skip;
      $skip = 2 - $skip if $skip <= 2;
      next if $skip;
      $line =~ s/^(\s*%)el/$1/;
      $line = expandmacros($config, $line, $lineno, \%macros, \%macros_args);
    }
    if ($line =~ /^\s*%else\b/) {
      $skip = 2 - $skip if $skip <= 2;
      next;
    }
    if ($line =~ /^\s*%endif\b/) {
      $skip = $skip > 2 ? $skip - 2 : 0;
      next;
    }

    if ($skip) {
      $skip += 2 if $line =~ /^\s*%if/;
      $xspec->[-1] = [ $xspec->[-1], undef ] if $doxspec;
      $ifdeps = 1 if $line =~ /^(BuildRequires|BuildPrereq|BuildConflicts|\#\!BuildIgnore|\#\!BuildConflicts|\#\!BuildRequires)\s*:\s*(\S.*)$/i;
      next;
    }

    if ($line =~ /\@/) {
      $line =~ s/\@BUILD_FLAVOR\@/$buildflavor/g;
      $line =~ s/\@OBS_PACKAGE\@/$obspackage/g;
    }

    if ($line =~ /^\s*%ifarch(.*)$/) {
      my $arch = $macros{'_target_cpu'} || 'unknown';
      my @archs = grep {$_ eq $arch} split(/\s+/, $1);
      $skip = 2 if !@archs;
      $hasif = 1;
      next;
    }
    if ($line =~ /^\s*%ifnarch(.*)$/) {
      my $arch = $macros{'_target_cpu'} || 'unknown';
      my @archs = grep {$_ eq $arch} split(/\s+/, $1);
      $skip = 2 if @archs;
      $hasif = 1;
      next;
    }
    if ($line =~ /^\s*%ifos(.*)$/) {
      my $os = $macros{'_target_os'} || 'unknown';
      my @oss = grep {$_ eq $os} split(/\s+/, $1);
      $skip = 2 if !@oss;
      $hasif = 1;
      next;
    }
    if ($line =~ /^\s*%ifnos(.*)$/) {
      my $os = $macros{'_target_os'} || 'unknown';
      my @oss = grep {$_ eq $os} split(/\s+/, $1);
      $skip = 2 if @oss;
      $hasif = 1;
      next;
    }
    if ($line =~ /^\s*%if(.*)$/) {
      my ($v, $r) = expr($1);
      $v = expr_boolify($v);
      $skip = 2 unless $v;
      $hasif = 1;
      next;
    }
    if ($includecallback && $line =~ /^\s*%include\s+(.*)\s*$/) {
      if ($includenum++ < 10) {
	my $data = $includecallback->($1);
	unshift @includelines, split("\n", $data) if $data;
      } else {
	warn("%include statment level too high, ignored\n") if $config->{'warnings'};
      }
    }
    if ($main_preamble) {
      if ($line =~ /^(Name|Version|Disttag|Release)\s*:\s*(\S+)/i) {
	$ret->{lc $1} = $2;
	$macros{lc $1} = $2;
      } elsif ($line =~ /^ExclusiveArch\s*:\s*(.*)/i) {
	$exclarch ||= [];
	push @$exclarch, split(' ', $1);
      } elsif ($line =~ /^ExcludeArch\s*:\s*(.*)/i) {
	$badarch ||= [];
	push @$badarch, split(' ', $1);
      }
    }
    if (@subpacks && $preamble && exists($ret->{'version'}) && $line =~ /^Version\s*:\s*(\S+)/i) {
      $ret->{'multiversion'} = 1 if $ret->{'version'} ne $1;
    }
    if ($preamble && $line =~ /^\#\!ForceMultiVersion\s*$/i) {
      $ret->{'multiversion'} = 1;
    }
    if ($line =~ /^(?:Requires\(pre\)|Requires\(post\)|PreReq)\s*:\s*(\S.*)$/i) {
      my $deps = $1;
      my @deps;
      if (" $deps" =~ /[\s,]\(/) {
	@deps = splitdeps($deps);
      } else {
	@deps = $deps =~ /([^\s\[,]+)(\s+[<=>]+\s+[^\s\[,]+)?(\s+\[[^\]]+\])?[\s,]*/g;
      }
      while (@deps) {
	my ($pack, $vers, $qual) = splice(@deps, 0, 3);
	next if $pack eq 'MACRO';	# hope for the best...
	if (!$unfilteredprereqs && $pack =~ /^\//) {
	  $ifdeps = 1;
	  next unless $config->{'fileprovides'}->{$pack};
	}
	push @prereqs, $pack unless grep {$_ eq $pack} @prereqs;
      }
      next;
    }
    if ($preamble && ($line =~ /^(BuildRequires|BuildPrereq|BuildConflicts|\#\!BuildIgnore|\#\!BuildConflicts|\#\!BuildRequires)\s*:\s*(\S.*)$/i)) {
      my $what = $1;
      my $deps = $2;
      $ifdeps = 1 if $hasif;
      # XXX: weird syntax addition. can append arch or project to dependency
      # BuildRequire: foo > 17 [i586,x86_64]
      # BuildRequire: foo [home:bar]
      # BuildRequire: foo [!home:bar]
      my @deps;
      if (" $deps" =~ /[\s,]\(/) {
	# we need to be careful, there could be a rich dep
	@deps = splitdeps($deps);
      } else {
	@deps = $deps =~ /([^\s\[,]+)(\s+[<=>]+\s+[^\s\[,]+)?(\s+\[[^\]]+\])?[\s,]*/g;
      }
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
	$vers = '' unless defined $vers;
	$vers =~ s/=(>|<)/$1=/;
	push @ndeps, "$pack$vers";
      }

      $replace = 1 if grep {/^-/} @ndeps;
      my $lcwhat = lc($what);
      if ($lcwhat ne 'buildrequires' && $lcwhat ne 'buildprereq' && $lcwhat ne '#!buildrequires') {
        if ($conflictdeps && $what =~ /conflict/i) {
	  push @packdeps, map {"!$_"} @ndeps;
	  next;
	}
	push @packdeps, map {"-$_"} @ndeps;
	next;
      }
      if (defined($hasnfb)) {
	if ((grep {$_ eq 'glibc' || $_ eq 'rpm' || $_ eq 'gcc' || $_ eq 'bash'} @ndeps) > 2) {
	  # ignore old generated BuildRequire lines.
	  $xspec->[-1] = [ $xspec->[-1], undef ] if $doxspec;
	  next;
	}
      }
      push @packdeps, @ndeps;
      next unless $doxspec;
      if ($replace) {
	my @cndeps = grep {!/^-/} @ndeps;
	if (@cndeps) {
	  $xspec->[-1] = [ $xspec->[-1], "$what:  ".join(' ', @cndeps) ];
	} else {
	  $xspec->[-1] = [ $xspec->[-1], ''];
	}
      }
      next;
    } elsif ($preamble && $line =~ /^(Source\d*|Patch\d*|Url|Icon)\s*:\s*(\S+)/i) {
      my ($tag, $val) = (lc($1), $2);
      $macros{$tag} = $val if $tag eq 'url';
      # associate url and icon tags with the corresponding subpackage
      $tag .= scalar @subpacks if ($tag eq 'url' || $tag eq 'icon') && @subpacks;
      if ($tag =~ /icon/) {
        # there can be a gif and xpm icon
        push @{$ret->{$tag}}, $val;
      } else {
	if ($tag =~ /^(source|patch)(\d+)?$/) {
	  my $num = defined($2) ? $2 : $autonum{$1};
	  my $m = uc($1) . "URL$num";
	  if (exists $macros{$m}) {
	    # gross hack. Before autonumbering "Patch" and "Patch0" could
	    # exist. So take out the previous patch and add it back
	    # without number. This does not exactly work as old rpms
	    # but hopefully good enough :-)
	    if ($1 eq 'patch' && $num == 0) {
	      $ret->{'patch'} = $ret->{$tag};
	    } else {
	      $ret->{'error'} = "$1 number $num exists!";
	      return $ret;
	    }
	  }
	  $autonum{$1} = $num+1 if $num >= $autonum{$1};
	  $macros{$m} = $val;
	  $tag = "$1$num";
	}
	$ret->{$tag} = $val;
      }
    } elsif (!$preamble && ($line =~ /^(Source\d*|Patch\d*|Url|Icon|BuildRequires|BuildPrereq|BuildConflicts|\#\!BuildIgnore|\#\!BuildConflicts|\#\!BuildRequires)\s*:\s*(\S.*)$/i)) {
      print STDERR "Warning: spec file parser ".($lineno ? " line $lineno" : '').": Ignoring $1 used beyond the preamble.\n" if $config->{'warnings'};
    }

    if ($line =~ /^\s*%package\s+(-n\s+)?(\S+)/) {
      if ($1) {
	push @subpacks, $2;
      } else {
	push @subpacks, $ret->{'name'}.'-'.$2 if defined $ret->{'name'};
      }
      $preamble = 1;
      $main_preamble = 0;
    }

    if ($line =~ /^\s*%(prep|build|install|check|clean|preun|postun|pretrans|posttrans|pre|post|files|changelog|description|triggerpostun|triggerun|triggerin|trigger|verifyscript)/) {
      $main_preamble = 0;
      $preamble = 0;
    }

    # do this always?
    if ($doxspec && $config->{'save_expanded'}) {
      $xspec->[-1] = [ $xspec->[-1], $line ];
    }
  }
  close SPEC unless ref $specfile;
  if (defined($hasnfb)) {
    if (!@packdeps) {
      @packdeps = split(' ', $hasnfb);
    } elsif ($nfbline) {
      $$nfbline = [$$nfbline, undef ];
    }
  }
  unshift @subpacks, $ret->{'name'} if defined $ret->{'name'};
  $ret->{'subpacks'} = \@subpacks;
  $ret->{'exclarch'} = $exclarch if defined $exclarch;
  $ret->{'badarch'} = $badarch if defined $badarch;
  $ret->{'deps'} = \@packdeps;
  $ret->{'prereqs'} = \@prereqs if @prereqs;
  $ret->{'configdependent'} = 1 if $ifdeps;
  return $ret;
}

###########################################################################

my %rpmstag = (
  "SIGTAG_SIZE"    => 1000,     # Header+Payload size in bytes. */
  "SIGTAG_PGP"     => 1002,     # RSA signature over Header+Payload
  "SIGTAG_MD5"     => 1004,     # MD5 hash over Header+Payload
  "SIGTAG_GPG"     => 1005,     # DSA signature over Header+Payload
  "NAME"           => 1000,
  "VERSION"        => 1001,
  "RELEASE"        => 1002,
  "EPOCH"          => 1003,
  "SUMMARY"        => 1004,
  "DESCRIPTION"    => 1005,
  "BUILDTIME"      => 1006,
  "ARCH"           => 1022,
  "OLDFILENAMES"   => 1027,
  "SOURCERPM"      => 1044,
  "PROVIDENAME"    => 1047,
  "REQUIREFLAGS"   => 1048,
  "REQUIRENAME"    => 1049,
  "REQUIREVERSION" => 1050,
  "NOSOURCE"       => 1051,
  "NOPATCH"        => 1052,
  "SOURCEPACKAGE"  => 1106,
  "PROVIDEFLAGS"   => 1112,
  "PROVIDEVERSION" => 1113,
  "DIRINDEXES"     => 1116,
  "BASENAMES"      => 1117,
  "DIRNAMES"       => 1118,
  "DISTURL"        => 1123,
  "CONFLICTFLAGS"  => 1053,
  "CONFLICTNAME"   => 1054,
  "CONFLICTVERSION" => 1055,
  "OBSOLETENAME"   => 1090,
  "OBSOLETEFLAGS"  => 1114,
  "OBSOLETEVERSION" => 1115,
  "OLDSUGGESTSNAME" => 1156,
  "OLDSUGGESTSVERSION" => 1157,
  "OLDSUGGESTSFLAGS" => 1158,
  "OLDENHANCESNAME" => 1159,
  "OLDENHANCESVERSION" => 1160,
  "OLDENHANCESFLAGS" => 1161,
  "RECOMMENDNAME" => 5046,
  "RECOMMENDVERSION" => 5047,
  "RECOMMENDFLAGS" => 5048,
  "SUGGESTNAME"    => 5049,
  "SUGGESTVERSION" => 5050,
  "SUGGESTFLAGS"   => 5051,
  "SUPPLEMENTNAME" => 5052,
  "SUPPLEMENTVERSION" => 5053,
  "SUPPLEMENTFLAGS" => 5054,
  "ENHANCENAME"    => 5055,
  "ENHANCEVERSION" => 5056,
  "ENHANCEFLAGS"   => 5057,
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
  my $forcebinary;
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
    $forcebinary = 1 if unpack('@6n', $lead) != 1;
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
  if (ref($rpm) eq 'ARRAY' && !$dosigs && @$rpm > 1) {
    my %res2 = &rpmq([ $rpm->[1] ], @stags);
    %res = (%res, %res2);
    return %res;
  }
  if (ref($rpm) ne 'ARRAY' && !$dosigs) {
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

#  return %res unless @stags;

  while($cnt-- > 0) {
    ($tag, $type, $offset, $count, $index) = unpack('N4a*', $index);
    $tag = 0+$tag;
    if ($stags{$tag} || !@stags) {
      eval {
	my $otag = $stags{$tag} || $tag;
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
  if ($forcebinary && $stags{1044} && !$res{$stags{1044}} && !($stags{1106} && $res{$stags{1106}})) {
    $res{$stags{1044}} = [ '(none)' ];	# like rpm does...
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
  my ($res, $name, $flags, $vers) = @_;

  return unless $res && $res->{$name};
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

sub filteroldweak {
  my ($res, $name, $flags, $data, $strong, $weak) = @_;

  return unless $res && $res->{$name};
  my @flags = @{$res->{$flags} || []};
  my @strong;
  my @weak;
  for (@{$res->{$name}}) {
    if (@flags && ($flags[0] & 0x8000000)) {
      push @strong, $_;
    } else {
      push @weak, $_;
    }
    shift @flags;
  }
  $data->{$strong} = \@strong if @strong;
  $data->{$weak} = \@weak if @weak;
}

sub verscmp_part {
  my ($s1, $s2) = @_;
  if (!defined($s1)) {
    return defined($s2) ? -1 : 0;
  }
  return 1 if !defined $s2;
  return 0 if $s1 eq $s2;
  while (1) {
    $s1 =~ s/^[^a-zA-Z0-9~\^]+//;
    $s2 =~ s/^[^a-zA-Z0-9~\^]+//;
    if ($s1 =~ s/^~//) {
      next if $s2 =~ s/^~//;
      return -1;
    }
    return 1 if $s2 =~ /^~/;
    if ($s1 =~ s/^\^//) {
      next if $s2 =~ s/^\^//;
      return $s2 eq '' ? 1 : -1;
    }
    return $s1 eq '' ? -1 : 1 if $s2 =~ /^\^/;
    if ($s1 eq '') {
      return $s2 eq '' ? 0 : -1;
    }
    return 1 if $s2 eq '';
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
  my ($handle, %opts) = @_;

  my @tags = qw{NAME SOURCERPM NOSOURCE NOPATCH SIGTAG_MD5 PROVIDENAME PROVIDEFLAGS PROVIDEVERSION REQUIRENAME REQUIREFLAGS REQUIREVERSION SOURCEPACKAGE};
  push @tags, qw{EPOCH VERSION RELEASE ARCH};
  push @tags, qw{FILENAMES} if $opts{'filelist'};
  push @tags, qw{SUMMARY DESCRIPTION} if $opts{'description'};
  push @tags, qw{DISTURL} if $opts{'disturl'};
  push @tags, qw{BUILDTIME} if $opts{'buildtime'};
  push @tags, qw{CONFLICTNAME CONFLICTVERSION CONFLICTFLAGS OBSOLETENAME OBSOLETEVERSION OBSOLETEFLAGS} if $opts{'conflicts'};
  push @tags, qw{RECOMMENDNAME RECOMMENDVERSION RECOMMENDFLAGS SUGGESTNAME SUGGESTVERSION SUGGESTFLAGS SUPPLEMENTNAME SUPPLEMENTVERSION SUPPLEMENTFLAGS ENHANCENAME ENHANCEVERSION ENHANCEFLAGS OLDSUGGESTSNAME OLDSUGGESTSVERSION OLDSUGGESTSFLAGS OLDENHANCESNAME OLDENHANCESVERSION OLDENHANCESFLAGS} if $opts{'weakdeps'};

  my %res = rpmq($handle, @tags);
  return undef unless %res;
  my $src = $res{'SOURCERPM'}->[0];
  $src = '' unless defined $src;
  $src =~ s/-[^-]*-[^-]*\.[^\.]*\.rpm//;
  add_flagsvers(\%res, 'PROVIDENAME', 'PROVIDEFLAGS', 'PROVIDEVERSION');
  add_flagsvers(\%res, 'REQUIRENAME', 'REQUIREFLAGS', 'REQUIREVERSION');
  my $data = {
    name => $res{'NAME'}->[0],
    hdrmd5 => unpack('H32', $res{'SIGTAG_MD5'}->[0]),
  };
  if ($opts{'alldeps'}) {
    $data->{'provides'} = [ @{$res{'PROVIDENAME'} || []} ];
    $data->{'requires'} = [ @{$res{'REQUIRENAME'} || []} ];
  } else {
    $data->{'provides'} = [ grep {!/^rpmlib\(/ && !/^\//} @{$res{'PROVIDENAME'} || []} ];
    $data->{'requires'} = [ grep {!/^rpmlib\(/ && !/^\//} @{$res{'REQUIRENAME'} || []} ];
  }
  if ($opts{'conflicts'}) {
    add_flagsvers(\%res, 'CONFLICTNAME', 'CONFLICTFLAGS', 'CONFLICTVERSION');
    add_flagsvers(\%res, 'OBSOLETENAME', 'OBSOLETEFLAGS', 'OBSOLETEVERSION');
    $data->{'conflicts'} = [ @{$res{'CONFLICTNAME'}} ] if $res{'CONFLICTNAME'};
    $data->{'obsoletes'} = [ @{$res{'OBSOLETENAME'}} ] if $res{'OBSOLETENAME'};
  }
  if ($opts{'weakdeps'}) {
    for (qw{RECOMMEND SUGGEST SUPPLEMENT ENHANCE}) {
      next unless $res{"${_}NAME"};
      add_flagsvers(\%res, "${_}NAME", "${_}FLAGS", "${_}VERSION");
      $data->{lc($_)."s"} = [ @{$res{"${_}NAME"}} ];
    }
    if ($res{'OLDSUGGESTSNAME'}) {
      add_flagsvers(\%res, 'OLDSUGGESTSNAME', 'OLDSUGGESTSFLAGS', 'OLDSUGGESTSVERSION');
      filteroldweak(\%res, 'OLDSUGGESTSNAME', 'OLDSUGGESTSFLAGS', $data, 'recommends', 'suggests');
    }
    if ($res{'OLDENHANCESNAME'}) {
      add_flagsvers(\%res, 'OLDENHANCESNAME', 'OLDENHANCESFLAGS', 'OLDENHANCESVERSION');
      filteroldweak(\%res, 'OLDENHANCESNAME', 'OLDENHANCESFLAGS', $data, 'supplements', 'enhances');
    }
  }

  # rpm3 compatibility: retrofit missing self provides
  if ($src ne '') {
    my $haveselfprovides;
    if (@{$data->{'provides'}}) {
      if ($data->{'provides'}->[-1] =~ /^\Q$res{'NAME'}->[0]\E =/) {
	$haveselfprovides = 1;
      } elsif (@{$data->{'provides'}} > 1 && $data->{'provides'}->[-2] =~ /^\Q$res{'NAME'}->[0]\E =/) {
	$haveselfprovides = 1;
      }
    }
    if (!$haveselfprovides) {
      my $evr = "$res{'VERSION'}->[0]-$res{'RELEASE'}->[0]";
      $evr = "$res{'EPOCH'}->[0]:$evr" if $res{'EPOCH'} && $res{'EPOCH'}->[0];
      push @{$data->{'provides'}}, "$res{'NAME'}->[0] = $evr";
    }
  }

  $data->{'source'} = $src eq '(none)' ? $data->{'name'} : $src if $src ne '';
  if ($opts{'evra'}) {
    my $arch = $res{'ARCH'}->[0];
    $arch = $res{'NOSOURCE'} || $res{'NOPATCH'} ? 'nosrc' : 'src' unless $src ne '';
    $data->{'version'} = $res{'VERSION'}->[0];
    $data->{'release'} = $res{'RELEASE'}->[0];
    $data->{'arch'} = $arch;
    $data->{'epoch'} = $res{'EPOCH'}->[0] if exists $res{'EPOCH'};
  }
  if ($opts{'filelist'}) {
    $data->{'filelist'} = $res{'FILENAMES'};
  }
  if ($opts{'description'}) {
    $data->{'summary'} = $res{'SUMMARY'}->[0];
    $data->{'description'} = $res{'DESCRIPTION'}->[0];
  }
  $data->{'buildtime'} = $res{'BUILDTIME'}->[0] if $opts{'buildtime'};
  $data->{'disturl'} = $res{'DISTURL'}->[0] if $opts{'disturl'} && $res{'DISTURL'};
  return $data;
}

sub queryhdrmd5 {
  my ($bin, $leadsigp) = @_;

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
  $$leadsigp = Digest::MD5::md5_hex(substr($buf, 0, $hlen)) if $leadsigp;
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

sub queryinstalled {
  my ($root, %opts) = @_;

  $root = '' if !defined($root) || $root eq '/';
  local *F;
  my $dochroot = $root ne '' && !$opts{'nochroot'} && !$< && (-x "$root/usr/bin/rpm" || -x "$root/bin/rpm") ? 1 : 0;
  my $pid = open(F, '-|');
  die("fork: $!\n") unless defined $pid;
  if (!$pid) {
    if ($dochroot && chroot($root)) {
      chdir('/') || die("chdir: $!\n");
      $root = '';
    }
    my @args;
    unshift @args, '--nodigest', '--nosignature' if -e "$root/usr/bin/rpmquery ";
    unshift @args, '--dbpath', "$root/var/lib/rpm" if $root ne '';
    push @args, '--qf', '%{NAME}/%{ARCH}/%|EPOCH?{%{EPOCH}}:{0}|/%{VERSION}/%{RELEASE}/%{BUILDTIME}\n';
    if (-x "$root/usr/bin/rpm") {
      exec("$root/usr/bin/rpm", '-qa', @args);
      die("$root/usr/bin/rpm: $!\n");
    }
    if (-x "$root/bin/rpm") {
      exec("$root/bin/rpm", '-qa', @args);
      die("$root/bin/rpm: $!\n");
    }
    die("rpm: command not found\n");
  }
  my @pkgs;
  while (<F>) {
    chomp;
    my @s = split('/', $_);
    next unless @s >= 5;
    my $q = {'name' => $s[0], 'arch' => $s[1], 'version' => $s[3], 'release' => $s[4]};
    $q->{'epoch'} = $s[2] if $s[2];
    $q->{'buildtime'} = $s[5] if $s[5];
    push @pkgs, $q;
  }
  if (!close(F)) {
    return queryinstalled($root, %opts, 'nochroot' => 1) if !@pkgs && $dochroot;
    die("rpm: exit status $?\n");
  }
  return \@pkgs;
}

# return (lead, sighdr, hdr [, hdrmd5]) of a rpm
sub getrpmheaders {
  my ($path, $withhdrmd5) = @_;

  my $hdrmd5;
  local *F;
  open(F, '<', $path) || die("$path: $!\n");
  my $buf = '';
  my $l;
  while (length($buf) < 96 + 16) {
    $l = sysread(F, $buf, 4096, length($buf));
    die("$path: read error\n") unless $l;
  }
  die("$path: not a rpm\n") unless unpack('N', $buf) == 0xedabeedb && unpack('@78n', $buf) == 5;
  my ($headmagic, $cnt, $cntdata) = unpack('@96N@104NN', $buf);
  die("$path: not a rpm (bad sig header)\n") unless $headmagic == 0x8eade801 && $cnt < 16384 && $cntdata < 1048576;
  my $hlen = 96 + 16 + $cnt * 16 + $cntdata;
  $hlen = ($hlen + 7) & ~7;
  while (length($buf) < $hlen + 16) {
    $l = sysread(F, $buf, 4096, length($buf));
    die("$path: read error\n") unless $l;
  }
  if ($withhdrmd5) {
    my $idxarea = substr($buf, 96 + 16, $cnt * 16);
    die("$path: no md5 signature header\n") unless $idxarea =~ /\A(?:.{16})*\000\000\003\354\000\000\000\007(....)\000\000\000\020/s;
    my $md5off = unpack('N', $1);
    die("$path: bad md5 offset\n") unless $md5off;
    $md5off += 96 + 16 + $cnt * 16; 
    $hdrmd5 = unpack("\@${md5off}H32", $buf);
  }
  ($headmagic, $cnt, $cntdata) = unpack('N@8NN', substr($buf, $hlen));
  die("$path: not a rpm (bad header)\n") unless $headmagic == 0x8eade801 && $cnt < 1048576 && $cntdata < 33554432;
  my $hlen2 = $hlen + 16 + $cnt * 16 + $cntdata;
  while (length($buf) < $hlen2) {
    $l = sysread(F, $buf, 4096, length($buf));
    die("$path: read error\n") unless $l;
  }
  close F;
  return (substr($buf, 0, 96), substr($buf, 96, $hlen - 96), substr($buf, $hlen, $hlen2 - $hlen), $hdrmd5);
}

sub getnevr_rich {
  my ($d) = @_;
  my $n = '';
  my $bl = 0;
  while ($d =~ /^([^ ,\(\)]*)/) {
    $n .= $1;
    $d = substr($d, length($1));
    last unless $d =~ /^([\(\)])/;
    $bl += $1 eq '(' ? 1 : -1;
    last if $bl < 0;
    $n .= $1;
    $d = substr($d, 1);
  }
  return $n;
}

my %richops  = (
  'and'     => 1,
  'or'      => 2,
  'if'      => 3,
  'unless'  => 4,
  'else'    => 5,
  'with'    => 6,
  'without' => 7,
);

sub parse_rich_rec {
  my ($dep, $chainop) = @_;
  my $d = $dep;
  $chainop ||= 0;
  return ($d, undef) unless $d =~ s/^\(\s*//;
  my ($r, $r2);
  if ($d =~ /^\(/) {
    ($d, $r) = parse_rich_rec($d);
    return ($d, undef) unless $r;
  } else {
    return ($d, undef) if $d =~ /^\)/;
    my $n = getnevr_rich($d);
    $d = substr($d, length($n));
    $d =~ s/^ +//;
    if ($d =~ /^([<=>]+)/) {
      $n .= " $1 ";
      $d =~ s/^[<=>]+ +//;
      my $evr = getnevr_rich($d);
      $d = substr($d, length($evr));
      $n .= $evr;
    }
    $r = [0, $n];
  }
  $d =~ s/^\s+//;
  return ($d, undef) unless $d ne '';
  return ($d, $r) if $d =~ s/^\)//;
  return ($d, undef) unless $d =~ s/([a-z]+)\s+//;
  my $op = $richops {$1};
  return ($d, undef) unless $op;
  return ($d, undef) if $op == 5 && $chainop != 3 && $chainop != 4;
  $chainop = 0 if $op == 5;
  return ($d, undef) if $chainop && (($chainop != 1 && $chainop != 2 && $chainop != 6) || $op != $chainop);
  ($d, $r2) = parse_rich_rec("($d", $op);
  return ($d, undef) unless $r2;
  if (($op == 3 || $op == 4) && $r2->[0] == 5) {
    $r = [$op, $r, $r2->[1], $r2->[2]];
  } else {
    $r = [$op, $r, $r2];
  }
  return ($d, $r);
}

sub parse_rich_dep {
  my ($dep) = @_;
  my ($d, $r) = parse_rich_rec($dep);
  return undef if !$r || $d ne '';
  return $r;
}

my @testcaseops = ('', '&', '|', '<IF>', '<UNLESS>', '<ELSE>', '+', '-');

sub testcaseformat_rec {
  my ($r, $addparens) = @_;
  my $op = $r->[0];
  return $r->[1] unless $op;
  my $top = $testcaseops[$op];
  my $r1 = testcaseformat_rec($r->[1], 1);
  if (($op == 3 || $op == 4) && @$r == 4) {
    $r1 = "$r1 $top " . testcaseformat_rec($r->[2], 1);
    $top = '<ELSE>';
  }
  my $addparens2 = 1;
  $addparens2 = 0 if $r->[2]->[0] == $op && ($op == 1 || $op == 2 || $op == 6);
  my $r2 = testcaseformat_rec($r->[-1], $addparens2);
  return $addparens ? "($r1 $top $r2)" : "$r1 $top $r2";
}

sub testcaseformat {
  my ($dep) = @_;
  my $r = parse_rich_dep($dep);
  return $dep unless $r;
  return testcaseformat_rec($r);
}

sub shiftrich {
  my ($s) = @_;
  # FIXME: do this right!
  my $dep = shift @$s;
  while (@$s && ($dep =~ y/\(/\(/) > ($dep =~ y/\)/\)/)) {
    $dep .= ' ' . shift(@$s);
  }
  return $dep;
}

1;
