################################################################
#
# Copyright (c) 2024 SUSE LLC
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

package Build::IntrospectGolang;

use strict;

use Build::ELF;

sub unpackgoaddr {
  my ($d, $le, $sz) = @_;
  my $addr;
  if ($sz == 4) {
    $addr = unpack($le ? 'V' : 'N', $d);
  } elsif ($sz == 8) {
    my $addr2;
    ($addr, $addr2) = unpack($le ? '@4V@0V' : 'NN', $d);
    $addr = $addr * 4294967296 + $addr2;
  } else {
    die("unpackgoaddr: unsupported size $sz\n");
  }
  return ($addr, substr($d, $sz));
}

sub unpackgovarstr {
  my ($d) = @_;
  my ($l, $x) = (0, 1);
  while (length($d)) {
    my $b = ord(substr($d, 0, 1, ''));
    $l += ($b & 127) * $x;
    $x *= 128;
    last if $b < 128;
  }
  return if $x == 1 || $l > length($d);
  my $s = substr($d, 0, $l, '');
  return ($s, $d);
}

sub readgostr {
  my ($elf, $addr, $le, $sz) = @_;
  my $d = $elf->readmem($addr, $sz * 2);
  ($addr, $d) = unpackgoaddr($d, $le, $sz);
  my ($len) = unpackgoaddr($d, $le, $sz);
  return $elf->readmem($addr, $len);
}

sub unpackgostr {
  my ($elf, $d, $le, $sz) = @_;
  my ($addr, $d2) = unpackgoaddr($d, $le, $sz);
  my $s = readgostr($elf, $addr, $le, $sz);
  return ($s, $d2);
}

sub rawbuildinfo {
  my ($fh) = @_;
  my $elf = Build::ELF::readelf($fh);
  if (0) {
    my $notesect = $elf->findsect('.note.package');
    print $elf->readsect($notesect);
  }
  if (0) {
    my $sym = $elf->getsymbols();
    for my $sy (@{$sym || []}) {
      if (($sy->{'name'} || '') eq 'runtime.buildVersion' && $sy->{'size'} == ($elf->{'is64'} ? 16 : 8)) {
        my $s = readgostr($elf, $sy->{'value'}, $elf->{'le'}, $elf->{'is64'} || 4);
        print "goversion_sym: $s\n";
      }
    }
  }
  my ($off, $len);
  my $bi = $elf->findsect('.go.buildinfo');
  if ($bi) {
    ($off, $len) = ($bi->{'addr'}, $bi->{'size'});
  } else {
    my $prog = $elf->findprog(1, 3, 2);	# PT_LOAD, PF_W|PF_X, PF_W
    ($off, $len) = ($prog->{'addr'}, $prog->{'msize'} > $prog->{'size'} + 32 ? $prog->{'size'} + 32 : $prog->{'msize'}) if $prog;
    $len = 1024 * 1024 if $len > 1024 * 1024;
  }
  return unless defined $off;
  my $d = $elf->readmem($off, $len);

  while (length($d) > 0) {
    my $idx = index($d, "\377 Go buildinf:");
    if ($idx == -1) {
      $d = '';
    } elsif ($idx % 16 == 0) {
      substr($d, 0, $idx, '');
      last;
    } else {
      $idx += 16 - ($idx % 16);
      substr($d, 0, $idx, '');
    }
  }
  return unless length($d) >= 32;

  my ($vers, $mod);
  my $flags = unpack('@15C', $d);
  if ($flags & 2) {
    $d = substr($d, 32);
    ($vers, $d) = unpackgovarstr($d);
    ($mod, $d) = unpackgovarstr($d);
  } else {
    my $ptrsize = unpack('@14C', $d);
    my $le = $flags & 1 ? 0 : 1;
    substr($d, 0, 16, '');
    ($vers, $d) = unpackgostr($elf, $d, $le, $ptrsize);
    ($mod, $d) = unpackgostr($elf, $d, $le, $ptrsize);
  }
  $mod = substr($mod, 16, -16) if length($mod) > 32 && substr($mod, -17, 1) eq "\n";
  return ($vers, $mod);
}

my %parsequoted_special = (
  'a' => "\a",
  'b' => "\b",
  'f' => "\f",
  'n' => "\n",
  'r' => "\r",
  't' => "\t",
  'v' => "\013",
  '"' => '"',
  "\\" => "\\",
);

sub parsequoted_special {
  my ($s) = @_;
  return pack('C0U', oct($s)) if $s =~ /^[0-7]+/;
  return pack('C0U', hex(substr($s, 1)));
}

sub parsequoted {
  my ($d) = @_;
  if ($d =~ /\A`(.*?)`/s) {
    my $s = $1;
    substr($d, 0, length($s) + 2, '');
    $s =~ s/\r//g;
    return ($s, $d);
  }
  die unless $d =~ /\A"/;
  $d =~ s/\\(.)/sprintf("\\x%02X", ord($1))/ge;
  return if $d !~ /\A\"(.*?)\"/s;
  my $s = $1;
  substr($d, 0, length($s) + 2, '');
  $d =~ s/\\x(..)/'\\'.chr(hex($1))/ge;
  $s =~ s/\\x(..)/'\\'.chr(hex($1))/ge;
  $s =~ s/\\([abfnrtv"\\]|[0-7]{3}|x[0-9a-fA-F]{2}|u[0-9a-fA-F]{4}|u[0-9a-fA-F]{8})/$parsequoted_special{$1} || parsequoted_special($1)/ge;
  return ($s, $d);
}

sub buildinfo  {
  my ($fh) = @_;
  my ($vers, $mod) = rawbuildinfo($fh);
  return undef unless defined $vers;
  $vers =~ s/^go(.*)/\1/;

  my $buildinfo = { 'goversion' => $vers };
  my $lastmod;
  for my $l (split("\n", $mod || '')) {
    my @s = split("\t", $l, 2);
    next unless @s >= 2;
    my ($s, $d) = @s;
    if ($s eq 'path') {
      $buildinfo->{'path'} = $d;
    } elsif ($s eq 'mod' || $s eq 'dep') {
      @s = split("\t", $d);
      next unless @s == 2 || @s == 3;
      $lastmod = { 'path' => $s[0], 'version' => $s[1] };
      $lastmod->{'sum'} = $s[2] if @s == 3;
      $buildinfo->{'main'} = $lastmod if $s eq 'mod';
      push @{$buildinfo->{'deps'}}, $lastmod if $s eq 'dep';
    } elsif ($s eq '=>') {
      @s = split("\t", $d);
      next unless @s == 3 && $lastmod;
      $lastmod->{'rep'} = { 'path' => $s[0], 'version' => $s[1], 'sum' => $s[2] };
      $lastmod = undef;
    } elsif ($s eq 'build') {
      my $k;
      if ($d =~ /\A[\"`]/s) {
	($k, $d) = parsequoted($d);
      } else {
	next unless $d =~ /\A(.*?)=/s;
	($k, $d) = ($1, substr($d, length($1)));
        next if $k eq '' || $k =~ /[ \t\r\n\"`]/;
      }
      next unless $d =~ s/\A=//;
      if ($d =~ /\A[\"`]/s) {
        ($d) = parsequoted($d);
      } else {
	next if $d =~ /[ \t\r\n\"`]/;
      }
      push @{$buildinfo->{'settings'}}, [ $k, $d ];
    }
  }
  return $buildinfo;
}

1;
