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

package Build::Deb;

use strict;
use Digest::MD5;

my $have_zlib;
eval {
  require Compress::Zlib;
  $have_zlib = 1;
};

my %obs2debian = (
  "i486"    => "i386",
  "i586"    => "i386",
  "i686"    => "i386",
  "ppc"     => "powerpc",
  "ppc64le" => "ppc64el",
  "x86_64"  => "amd64",
  "armv4l"  => "armel",
  "armv5l"  => "armel",
  "armv6l"  => "armel",
  "armv7el" => "armel",
  "armv7l"  => "armhf",
  "armv7hl" => "armhf",
  "aarch64" => "arm64",
);

sub basearch {
  my ($arch) = @_;
  return 'all' if !defined($arch) || $arch eq 'noarch';
  return $obs2debian{$arch} || $arch;
}

sub obsarch {
  my ($arch) = @_;
  return grep {$obs2debian{$_} eq $arch} sort keys %obs2debian;
}

sub parse {
  my ($bconf, $fn) = @_;
  my $ret;
  my @control;

  # get arch and os from macros
  my ($arch, $os) = Build::gettargetarchos($bconf);
  # map to debian names
  $os = 'linux' unless defined $os;
  $arch = basearch($arch);

  if (ref($fn) eq 'ARRAY') {
    @control = @$fn;
  } else {
    local *F;
    if (!open(F, '<', $fn)) {
      $ret->{'error'} = "$fn: $!";
      return $ret;
    }
    @control = <F>;
    close F;
    chomp @control;
  }
  splice(@control, 0, 3) if @control > 3 && $control[0] =~ /^-----BEGIN/;
  my $name;
  my $version;
  my @deps;
  my @exclarch;
  while (@control) {
    my $c = shift @control;
    last if $c eq '';   # new paragraph
    my ($tag, $data) = split(':', $c, 2);
    next unless defined $data;
    $tag = uc($tag);
    while (@control && $control[0] =~ /^\s/) {
      $data .= "\n".substr(shift @control, 1);
    }
    $data =~ s/^\s+//s;
    $data =~ s/\s+$//s;
    if ($tag eq 'VERSION') {
      $version = $data;
      $version =~ s/-[^-]+$//;
    } elsif ($tag eq 'ARCHITECTURE') {
      my @archs = split('\s+', $data);
      map { s/\Q$os\E-//; s/any-// } @archs;
      next if grep { $_ eq "any" || $_ eq "all" } @archs;
      @exclarch = map { obsarch($_) } @archs;
      # unify
      my %exclarch = map {$_ => 1} @exclarch;
      @exclarch = sort keys %exclarch;
    } elsif ($tag eq 'SOURCE') {
      $name = $data;
    } elsif ($tag eq 'BUILD-DEPENDS' || $tag eq 'BUILD-CONFLICTS' || $tag eq 'BUILD-IGNORE' ||
        $tag eq 'BUILD-DEPENDS-INDEP' || $tag eq 'BUILD-DEPENDS-ARCH' || $tag eq 'BUILD-CONFLICTS-ARCH' ) {
      my @d = split(/\s*,\s*/, $data);
      for my $d (@d) {
        my @alts = split('\s*\|\s*', $d);
        my @needed;
        for my $c (@alts) {
          if ($c =~ /\s+<[^>]+>$/) {
            my @build_profiles;  # Empty for now
            my $bad = 1;
            while ($c =~ s/\s+<([^>]+)>$//) {
              next if (!$bad);
              my $list_valid = 1;
              for my $term (split(/\s+/, $1)) {
                my $isneg = ($term =~ s/^\!//);
                my $profile_match = grep(/^$term$/, @build_profiles);
                if (( $profile_match &&  $isneg) ||
                    (!$profile_match && !$isneg)) {
                  $list_valid = 0;
                  last;
                }
              }
              $bad = 0 if ($list_valid);
            }
            next if ($bad);
          }
          if ($c =~ /^(.*?)\s*\[(.*)\]$/) {
            $c = $1;
            my $isneg = 0;
            my $bad;
            for my $q (split('[\s,]', $2)) {
              $isneg = 1 if $q =~ s/^\!//;
              $bad = 1 if !defined($bad) && !$isneg;
              if ($isneg) {
                if ($q eq $arch || $q eq 'any' || $q eq "$os-$arch" || $q eq "$os-any" || $q eq "any-$arch") {
                  $bad = 1;
                  last;
                }
              } elsif ($q eq $arch || $q eq 'any' || $q eq "$os-$arch" || $q eq "$os-any" || $q eq "any-$arch") {
                $bad = 0;
              }
            }
            next if ($bad);
          }
          $c =~ s/^([^:\s]*):(any|native)(.*)$/$1$3/;
          push @needed, $c;
        }
        next unless @needed;
        $d = join(' | ', @needed);
	$d =~ s/ \(([^\)]*)\)/ $1/g;
	$d =~ s/>>/>/g;
	$d =~ s/<</</g;
	if ($tag eq 'BUILD-DEPENDS' || $tag eq 'BUILD-DEPENDS-INDEP' || $tag eq 'BUILD-DEPENDS-ARCH') {
	  push @deps, $d;
	} else {
	  push @deps, "-$d";
	}
      }
    }
  }
  $ret->{'name'} = $name;
  $ret->{'version'} = $version;
  $ret->{'deps'} = \@deps;
  $ret->{'exclarch'} = \@exclarch if @exclarch;
  return $ret;
}

sub uncompress {
  my ($data, $tool) = @_;
  return $data if $tool eq 'cat';
  return Compress::Zlib::memGunzip($data) if $have_zlib && $tool eq 'gunzip';
  local (*TMP, *TMP2);
  open(TMP, "+>", undef) or die("could not open tmpfile\n");
  syswrite TMP, $data;
  my $pid = open(TMP2, "-|");
  die("fork: $!\n") unless defined $pid;
  if (!$pid) {
    open(STDIN, "<&TMP");
    seek(STDIN, 0, 0);    # these two lines are a workaround for a perl bug mixing up FD
    sysseek(STDIN, 0, 0);
    exec($tool);
    die("$tool: $!\n");
  }
  close(TMP);
  $data = '';
  1 while sysread(TMP2, $data, 1024, length($data)) > 0;
  if (!close(TMP2)) {
    warn("$tool error: $?\n");
    return undef;
  }
  return $data;
}

sub control2res {
  my ($control) = @_;
  my %res;
  my @control = split("\n", $control);
  while (@control) {
    my $c = shift @control;
    last if $c eq '';   # new paragraph
    my ($tag, $data) = split(':', $c, 2);
    next unless defined $data;
    $tag = uc($tag);
    while (@control && $control[0] =~ /^\s/) {
      $data .= "\n".substr(shift @control, 1);
    }
    $data =~ s/^\s+//s;
    $data =~ s/\s+$//s;
    $res{$tag} = $data;
  }
  return %res;
}

sub debq {
  my ($fn) = @_;

  local *DEBF;
  if (ref($fn) eq 'GLOB') {
      *DEBF = *$fn;
  } elsif (!open(DEBF, '<', $fn)) {
    warn("$fn: $!\n");
    return ();
  }
  my $data = '';
  sysread(DEBF, $data, 4096);
  if (length($data) < 8+60) {
    warn("$fn: not a debian package - header too short\n");
    close DEBF unless ref $fn;
    return ();
  }
  if (substr($data, 0, 8+16) ne "!<arch>\ndebian-binary   " &&
      substr($data, 0, 8+16) ne "!<arch>\ndebian-binary/  ") {
    close DEBF unless ref $fn;
    return ();
  }
  my $len = substr($data, 8+48, 10);
  $len += $len & 1;
  if (length($data) < 8+60+$len+60) {
    my $r = 8+60+$len+60 - length($data);
    $r -= length($data);
    if ((sysread(DEBF, $data, $r < 4096 ? 4096 : $r, length($data)) || 0) < $r) {
      warn("$fn: unexpected EOF\n");
      close DEBF unless ref $fn;
      return ();
    }
  }
  $data = substr($data, 8 + 60 + $len);
  my $controlname = substr($data, 0, 16);
  my $decompressor;
  if ($controlname eq 'control.tar.gz  ' || $controlname eq 'control.tar.gz/ ') {
    $decompressor = 'gunzip';
  } elsif ($controlname eq 'control.tar.xz  ' || $controlname eq 'control.tar.xz/ ') {
    $decompressor = 'unxz';
  } elsif ($controlname eq 'control.tar     ' || $controlname eq 'control.tar/    ') {
    $decompressor = 'cat';
  } else {
    warn("$fn: control.tar is not second ar entry\n");
    close DEBF unless ref $fn;
    return ();
  }
  $len = substr($data, 48, 10);
  if (length($data) < 60+$len) {
    my $r = 60+$len - length($data);
    if ((sysread(DEBF, $data, $r, length($data)) || 0) < $r) {
      warn("$fn: unexpected EOF\n");
      close DEBF unless ref $fn;
      return ();
    }
  }
  close DEBF unless ref($fn);
  $data = substr($data, 60, $len);
  my $controlmd5 = Digest::MD5::md5_hex($data);	# our header signature
  $data = uncompress($data, $decompressor);
  if (!$data) {
    warn("$fn: corrupt control.tar file\n");
    return ();
  }
  my $control;
  while (length($data) >= 512) {
    my $n = substr($data, 0, 100);
    $n =~ s/\0.*//s;
    my $len = oct('00'.substr($data, 124,12));
    my $blen = ($len + 1023) & ~511;
    if (length($data) < $blen) {
      warn("$fn: corrupt control.tar file\n");
      return ();
    }
    if ($n eq './control' || $n eq "control") {
      $control = substr($data, 512, $len);
      last;
    }
    $data = substr($data, $blen);
  }
  my %res = control2res($control);
  $res{'CONTROL_MD5'} = $controlmd5;
  return %res;
}

sub query {
  my ($handle, %opts) = @_;

  my %res = debq($handle);
  return undef unless %res;
  my $name = $res{'PACKAGE'};
  my $src = $name;
  if ($res{'SOURCE'}) {
    $src = $res{'SOURCE'};
    $src =~ s/\s.*$//;
  }
  my @provides = split(',\s*', $res{'PROVIDES'} || '');
  if ($opts{'addselfprovides'}) {
    push @provides, "$name (= $res{'VERSION'})";
  }
  my @depends = split(',\s*', $res{'DEPENDS'} || '');
  push @depends, split(',\s*', $res{'PRE-DEPENDS'} || '');
  my $data = {
    name => $name,
    hdrmd5 => $res{'CONTROL_MD5'},
    provides => \@provides,
    requires => \@depends,
  };
  if ($opts{'conflicts'}) {
    my @conflicts = split(',\s*', $res{'CONFLICTS'} || '');
    push @conflicts, split(',\s*', $res{'BREAKS'} || '');
    $data->{'conflicts'} = \@conflicts if @conflicts;
  }
  if ($opts{'weakdeps'}) {
    for my $dep ('SUGGESTS', 'RECOMMENDS', 'ENHANCES') {
      $data->{lc($dep)} = [ split(',\s*', $res{$dep} || '') ] if defined $res{$dep};
    }
  }
  $data->{'source'} = $src if $src ne '';
  if ($opts{'evra'}) {
    $res{'VERSION'} =~ /^(?:(\d+):)?(.*?)(?:-([^-]*))?$/s;
    $data->{'epoch'} = $1 if defined $1;
    $data->{'version'} = $2;
    $data->{'release'} = $3 if defined $3;
    $data->{'arch'} = $res{'ARCHITECTURE'};
  }
  if ($opts{'description'}) {
    $data->{'description'} = $res{'DESCRIPTION'};
  }
  if ($opts{'normalizedeps'}) {
    for my $dep (qw{provides requires conflicts suggests enhances recommends}) {
      next unless $data->{$dep};
      for (@{$data->{$dep}}) {
        s/ \(([^\)]*)\)/ $1/g;
        s/<</</g;
        s/>>/>/g;
      }
    }
  }
  return $data;
}

sub queryhdrmd5 {
  my ($bin) = @_;

  local *F;
  open(F, '<', $bin) || die("$bin: $!\n");
  my $data = '';
  sysread(F, $data, 4096);
  if (length($data) < 8+60) {
    warn("$bin: not a debian package - header too short\n");
    close F;
    return undef;
  }
  if (substr($data, 0, 8+16) ne "!<arch>\ndebian-binary   " &&
      substr($data, 0, 8+16) ne "!<arch>\ndebian-binary/  ") {
    warn("$bin: not a debian package - no \"debian-binary\" entry\n");
    close F;
    return undef;
  }
  my $len = substr($data, 8+48, 10);
  $len += $len & 1;
  if (length($data) < 8+60+$len+60) {
    my $r = 8+60+$len+60 - length($data);
    $r -= length($data);
    if ((sysread(F, $data, $r < 4096 ? 4096 : $r, length($data)) || 0) < $r) {
      warn("$bin: unexpected EOF\n");
      close F;
      return undef;
    }
  }
  $data = substr($data, 8 + 60 + $len);
  my $controlname = substr($data, 0, 16);
  if ($controlname ne 'control.tar.gz  ' && $controlname ne 'control.tar.gz/ ' &&
      $controlname ne 'control.tar.xz  ' && $controlname ne 'control.tar.xz/ ' &&
      $controlname ne 'control.tar     ' && $controlname ne 'control.tar/    ') {
    warn("$bin: control.tar is not second ar entry\n");
    close F;
    return undef;
  }
  $len = substr($data, 48, 10);
  if (length($data) < 60+$len) {
    my $r = 60+$len - length($data);
    if ((sysread(F, $data, $r, length($data)) || 0) < $r) {
      warn("$bin: unexpected EOF\n");
      close F;
      return undef;
    }
  }
  close F;
  $data = substr($data, 60, $len);
  return Digest::MD5::md5_hex($data);
}

sub verscmp_part {
  my ($s1, $s2) = @_;
  return 0 if $s1 eq $s2;
  $s1 =~ s/([0-9]+)/substr("00000000000000000000000000000000$1", -32, 32)/ge;
  $s2 =~ s/([0-9]+)/substr("00000000000000000000000000000000$1", -32, 32)/ge;
  $s1 .= "\0";
  $s2 .= "\0";
  $s1 =~ tr[\176\000-\037\060-\071\101-\132\141-\172\040-\057\072-\100\133-\140\173-\175][\000-\176];
  $s2 =~ tr[\176\000-\037\060-\071\101-\132\141-\172\040-\057\072-\100\133-\140\173-\175][\000-\176];
  return $s1 cmp $s2;
}

sub verscmp {
  my ($s1, $s2) = @_;
  my ($e1, $v1, $r1) = $s1 =~ /^(?:(\d+):)?(.*?)(?:-([^-]*))?$/s;
  $e1 = 0 unless defined $e1;
  my ($e2, $v2, $r2) = $s2 =~ /^(?:(\d+):)?(.*?)(?:-([^-]*))?$/s;
  $e2 = 0 unless defined $e2;
  if ($e1 ne $e2) {
    my $r = verscmp_part($e1, $e2);
    return $r if $r;
  }
  my $r = verscmp_part($v1, $v2);
  return $r if $r;
  $r1 = '' unless defined $r1;
  $r2 = '' unless defined $r2;
  return verscmp_part($r1, $r2);
}

sub queryinstalled {
  my ($root, %opts) = @_;

  $root = '' if !defined($root) || $root eq '/';
  my @pkgs;
  local *F;
  if (open(F, '<', "$root/var/lib/dpkg/status")) {
    my $ctrl = '';
    while(<F>) {
      if ($_ eq "\n") {
	my %res = control2res($ctrl);
	if (defined($res{'PACKAGE'})) {
	  my $data = {'name' => $res{'PACKAGE'}};
	  $res{'VERSION'} =~ /^(?:(\d+):)?(.*?)(?:-([^-]*))?$/s;
	  $data->{'epoch'} = $1 if defined $1;
	  $data->{'version'} = $2;
	  $data->{'release'} = $3 if defined $3;
	  $data->{'arch'} = $res{'ARCHITECTURE'};
	  push @pkgs, $data;
	}
        $ctrl = '';
	next;
      }
      $ctrl .= $_;
    }
    close F;
  }
  return \@pkgs;
}

1;
