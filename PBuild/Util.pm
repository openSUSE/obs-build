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

package PBuild::Util;

use strict;
use POSIX;
use Storable ();

sub unify {
  my %h = map {$_ => 1} @_;
  return grep(delete($h{$_}), @_);
}

sub clone {
  return Storable::dclone($_[0]);
}

sub writestr {
  my ($fn, $fnf, $d) = @_;
  my $f;
  open($f, '>', $fn) || die("$fn: $!\n");
  if (length($d)) {
    (syswrite($f, $d) || 0) == length($d) || die("$fn write: $!\n");
  }
  close($f) || die("$fn close: $!\n");
  return unless defined $fnf;
  rename($fn, $fnf) || die("rename $fn $fnf: $!\n");
}

sub readstr {
  my ($fn, $nonfatal) = @_;
  my $f;
  if (!open($f, '<', $fn)) {
    die("$fn: $!\n") unless $nonfatal;
    return undef;
  }
  my $d = '';
  1 while sysread($f, $d, 8192, length($d));
  close $f;
  return $d;
}

sub ls {
  my $d;
  opendir($d, $_[0]) || return ();
  my @r = grep {$_ ne '.' && $_ ne '..'} readdir($d);
  closedir $d;
  return @r;
}

sub mkdir_p {
  my ($dir) = @_;

  return 1 if -d $dir;
  my $pdir;
  if ($dir =~ /^(.+)\//) {
    $pdir = $1;
    mkdir_p($pdir) || return undef;
  }
  while (!mkdir($dir, 0777)) {
    my $e = $!;
    return 1 if -d $dir;
    if (defined($pdir) && ! -d $pdir) {
      mkdir_p($pdir) || return undef;
      next;
    }
    $! = $e;
    warn("mkdir: $dir: $!\n");
    return undef;
  }
  return 1;
}

sub cleandir {
  my ($dir) = @_;

  my $ret = 1;
  return 1 unless -d $dir;
  for my $c (ls($dir)) {
    if (! -l "$dir/$c" && -d _) {
      cleandir("$dir/$c");
      $ret = undef unless rmdir("$dir/$c");
    } else {
      $ret = undef unless unlink("$dir/$c");
    }
  }
  return $ret;
}

sub rm_rf {
  my ($file) = @_;
  my @s = lstat($file);
  if (@s && -d _) {
    cleandir($file);
    die("rmdir $file: $!\n") unless rmdir($file);
  } elsif (@s) {
    unlink($file) || die("unlink $file: $!\n");
  }
}

sub xfork {
  while (1) {
    my $pid = fork();
    return $pid if defined $pid;
    die("fork: $!\n") if $! != POSIX::EAGAIN;
    sleep(5);
  }
}

sub cp {
  my ($from, $to, $tof) = @_;
  my ($f, $t);
  open($f, '<', $from) || die("$from: $!\n");
  open($t, '>', $to) || die("$to: $!\n");
  my $buf;
  while (sysread($f, $buf, 8192)) {
    (syswrite($t, $buf) || 0) == length($buf) || die("$to write: $!\n");
  }
  close($f);
  close($t) || die("$to: $!\n");
  if (defined($tof)) {
    rename($to, $tof) || die("rename $to $tof: $!\n");
  }
}

sub cp_a {
  my ($from, $to, $tof) = @_;
  rm_rf($to);
  system('cp', '-a', '--', $from, $to) && die("cp $from $to: $?\n");
  if (defined($tof)) {
    rename($to, $tof) || die("rename $to $tof: $!\n");
  }
}

sub store {
  my ($fn, $fnf, $dd) = @_;
  if (!Storable::nstore($dd, $fn)) {
    die("nstore $fn: $!\n");
  }
  return unless defined $fnf;
  $! = 0;
  rename($fn, $fnf) || die("rename $fn $fnf: $!\n");
}

sub retrieve {
  my ($fn, $nonfatal) = @_;
  my $dd;
  if (!$nonfatal) {
    $dd = ref($fn) ? Storable::fd_retrieve($fn) : Storable::retrieve($fn);
    die("retrieve $fn: $!\n") unless $dd;
  } else {
    eval {
      $dd = ref($fn) ? Storable::fd_retrieve($fn) : Storable::retrieve($fn);
    };
    if (!$dd && $nonfatal == 2) {
      if ($@) {
        warn($@);
      } else {
        warn("retrieve $fn: $!\n");
      }
    }
  }
  return $dd;
}

sub identical {
  my ($d1, $d2, $except, $subexcept) = @_;

  if (!defined($d1)) {
    return defined($d2) ? 0 : 1;
  }
  return 0 unless defined($d2);
  my $r = ref($d1);
  return 0 if $r ne ref($d2);
  if ($r eq '') {
    return 0 if $d1 ne $d2;
  } elsif ($r eq 'HASH') {
    my %k = (%$d1, %$d2);
    for my $k (keys %k) {
      next if $except && $except->{$k};
      return 0 unless identical($d1->{$k}, $d2->{$k}, $subexcept, $subexcept);
    }
  } elsif ($r eq 'ARRAY') {
    return 0 unless @$d1 == @$d2;
    for (my $i = 0; $i < @$d1; $i++) {
      return 0 unless identical($d1->[$i], $d2->[$i], $subexcept, $subexcept);
    }
  } else {
    return 0;
  }
  return 1;
}

sub store_unless_identical {
  my ($fn, $fnf, $dd, $olddd) = @_;
  $olddd ||= retrieve(defined($fnf) ? $fnf : $fn, 1);
  store($fn, $fnf, $dd) unless identical($dd, $olddd);
}

sub isotime {
  my ($t) = @_;
  my @lt = localtime($t || time());
  return sprintf "%04d-%02d-%02d %02d:%02d:%02d", $lt[5] + 1900, $lt[4] + 1, @lt[3,2,1,0];
}

sub urlencode {
  my ($str, $iscgi) = @_;
  if ($iscgi) {
    $str =~ s/([\000-\037<>;\"#\?&\+=%[\177-\377])/sprintf("%%%02X",ord($1))/sge;
    $str =~ tr/ /+/;
  } else {
    $str =~ s/([\000-\040<>;\"#\?&\+=%[\177-\377])/sprintf("%%%02X",ord($1))/sge;
  }
  return $str;
}

sub urldecode {
  my ($str, $iscgi) = @_;
  $str =~ tr/+/ / if $iscgi;
  $str =~ s/%([a-fA-F0-9]{2})/chr(hex($1))/sge;
  return $str;
}

sub plural {
  my ($n, $what) = @_;
  return "$n $what" if $n == 1;
  return "$n ${what}ies" if $what =~ s/y$//;
  return "$n ${what}s";
}

1;
