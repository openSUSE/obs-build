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

package Build::ELF;

use strict;

sub doread {
  my ($fh, $size, $pos) = @_;
  my $b;
  seek($fh, $pos, 0) || die("seek: $!\n") if defined $pos;
  die("Unexpeced EOF\n") if read($fh, $b, $size) != $size;
  return $b;
}

sub elf64 {
  my ($buf, $off, $le, $sz) = @_;
  $sz = 4 unless defined $sz;
  if ($sz == 8) {
    my ($d1, $d2);
    if ($le) {
      ($d2, $d1) = unpack("\@${off}VV", $buf);
    } else {
      ($d1, $d2) = unpack("\@${off}NN", $buf);
    }
    die("oversized 64bit value\n") if $d1 >= 0x10000;
    return $d1 * 4294967296 + $d2;
  } elsif ($sz == 4) {
    return unpack("\@${off}V", $buf) if $le;
    return unpack("\@${off}N", $buf);
  } elsif ($sz == 2) {
    return unpack("\@${off}v", $buf) if $le;
    return unpack("\@${off}n", $buf);
  } elsif ($sz == 1) {
    return unpack("\@${off}C", $buf);
  }
  die("unsuported size in elf64: $sz\n");
}

sub findsect {
  my ($elf, $name, $type) = @_;
  if (defined($type)) {
    return (grep {$_->{'name'} eq $name && $_->{'type'} == $type} @{$elf->{'sects'}})[0] if defined $name;
    return (grep {$_->{'type'} == $type} @{$elf->{'sects'}})[0];
  }
  return (grep {$_->{'name'} eq $name} @{$elf->{'sects'}})[0];
}

sub findprog {
  my ($elf, $type, $flagsmask, $flags) = @_;
  return (grep {$_->{'type'} == $type && ($_->{'flags'} & $flagsmask) == $flags } @{$elf->{'progs'}})[0];
}

sub readsect {
  my ($elf, $sect, $off, $len) = @_;
  $off ||= 0;
  $len = $sect->{'size'} - $off if !defined($len) || $off + $len > $sect->{'size'};
  return $len > 0 ? doread($elf->{'fh'}, $len, $sect->{'offset'} + $off) : '';
}

sub readprog {
  return readsect(@_);
}

sub readmem {
  my ($elf, $off, $len) = @_;
  $off ||= 0;
  return '' unless defined($len) && $len > 0;
  my $ret = '';
  my $l;
  for my $prog (@{$elf->{'loadprogs'}}) {
    next if $prog->{'addr_end'} < $off;
    $l = $prog->{'addr'} - $off;
    if ($l > 0) {
      $l = $len if $len < $l;
      my $r = '';
      vec($r, $l - 1, 8) = 0;
      $ret .= $r;
      $len -= length($r);
      $off += length($r);
      return $ret if $len <= 0;
    }
    die if $prog->{'addr'} > $off;
    $l = $prog->{'size'} - ($off - $prog->{'addr'});
    if ($len > 0 && $l > 0) {
      $l = $len if $len < $l;
      my $r = doread($elf->{'fh'}, $l, $prog->{'offset'} + ($off - $prog->{'addr'}));
      $ret .= $r;
      $len -= length($r);
      $off += length($r);
    }
    $l = $prog->{'msize'} - ($off - $prog->{'addr'});
    if ($len > 0 && $l > 0) {
      $l = $len if $len < $l;
      my $r = '';
      vec($r, $l - 1, 8) = 0;
      $ret .= $r;
      $len -= length($r);
      $off += length($r);
    }
    last if $len <= 0;
  }
  return $ret;
}

sub getsymbols {
  my ($elf) = @_;
  my $sect = (grep {$_->{'type'} == 2} @{$elf->{'sects'}})[0];
  my @syms;
  return \@syms unless $sect && $sect->{'size'};
  my $d = readsect($elf, $sect);
  my ($is64, $le) = ($elf->{'is64'}, $elf->{'le'});
  my $sysize = $elf->{'is64'} ? 24 : 16;
  if (!defined($elf->{'strtab'})) {
    my $strtab = (grep {$_->{'name'} eq '.strtab'} @{$elf->{'sects'}})[0];
    die("no strtab section\n") unless $strtab;
    $elf->{'strtab'} = readsect($elf, $strtab);
  }
  while (length($d) >= $sysize) {
    my $s = substr($d, 0, $sysize, '');
    my $nm = elf64($s, 0, $le);
    my $va = elf64($s, $is64 ? 8 : 4, $le, $is64);
    my $sz = elf64($s, $is64 ? 16 : 8, $le, $is64);
    my $sidx = elf64($s, $is64 ? 6 : 14, $le, 2);
    my $info = elf64($s, $is64 ? 4 : 12, $le, 1);
    my $oth  = elf64($s, $is64 ? 5 : 13, $le, 1);
    push @syms, {
      'name' => $nm ? unpack("\@${nm}Z*", $elf->{'strtab'}) : undef,
      'value' => $va, 
      'size' => $sz, 
      'section' => $sidx, 
      'info' => $info, 
      'other' => $oth, 
    };
  }
  return \@syms;
}

sub readelf {
  my ($fh) = @_;
  my $header = doread($fh, 64, 0);
  die("not an elf file\n") unless unpack('N', $header) == 0x7f454c46;
  my ($is64, $le) = unpack('@4CC', $header);
  $is64 = $is64 == 2 ? 8 : undef;
  $le = $le != 2 ? 1 : 0;
  my $poff  = elf64($header, $is64 ? 32 : 28, $le, $is64);
  my $soff  = elf64($header, $is64 ? 40 : 32, $le, $is64);
  my $psize = elf64($header, $is64 ? 54 : 42, $le, 2);
  my $pnum  = elf64($header, $is64 ? 56 : 44, $le, 2);
  my $ssize = elf64($header, $is64 ? 58 : 46, $le, 2);
  my $snum  = elf64($header, $is64 ? 60 : 48, $le, 2);
  my $sidx  = elf64($header, $is64 ? 62 : 50, $le, 2);

  if ($snum == 0 && $soff > 0) {
    my $s = doread($fh, $ssize, $soff);
    my $type = elf64($s, 4, $le);
    die("bad sect0 type\n") unless $type == 0;
    $snum = elf64($s, $is64 ? 32 : 20, $le, $is64);
    die("bad sect0 size\n") unless $snum >= 0xff00;
    if ($sidx == 0xffff) {
      $sidx = elf64($s, $is64 ? 40 : 24, $le, $is64);
      die("bad sect0 link\n") unless $sidx >= 0xff00;
    }
  }

  my $sects = doread($fh, $snum * $ssize, $soff);
  my @sects;
  push @sects, substr($sects, 0, $ssize, '') while $ssize && length($sects) >= $ssize;
  my $strsect = $sects[$sidx];
  die("no string section\n") unless defined $strsect;
  my $str = doread($fh, elf64($strsect, $is64 ? 32 : 20, $le, $is64), elf64($strsect, $is64 ? 24 : 16, $le, $is64));
  for my $s (@sects) {
    my $nm = elf64($s, 0, $le);
    $nm = unpack("\@${nm}Z*", $str);
    my $type = elf64($s, 4, $le);
    my $ad = elf64($s, $is64 ? 16 : 12, $le, $is64);
    my $of = elf64($s, $is64 ? 24 : 16, $le, $is64);
    my $sz = elf64($s, $is64 ? 32 : 20, $le, $is64);
    $s = { 'name' => $nm, 'type' => $type, 'offset' => $of, 'size' => $sz, 'addr' => $ad };
  }

  my $progs = doread($fh, $pnum * $psize, $poff);
  my @progs;
  push @progs, substr($progs, 0, $psize, '') while $psize && length($progs) >= $psize;
  for my $p (@progs) {
    my $type = elf64($p, 0, $le);
    my $flags = elf64($p, $is64 ? 4 : 24, $le);
    my $of    = elf64($p, $is64 ? 8 : 4, $le, $is64);
    my $ad    = elf64($p, $is64 ? 16 : 8, $le, $is64);
    my $sz    = elf64($p, $is64 ? 32 : 16, $le, $is64);
    my $msz   = elf64($p, $is64 ? 40 : 20, $le, $is64);
    $p = { 'type' => $type, 'flags' => $flags, 'offset' => $of, 'size' => $sz, 'addr' => $ad, 'msize' => $msz, 'addr_end' => $ad + $msz };
  }

  my $elf = {
    'fh' => $fh,
    'is64' => $is64,
    'le' => $le,
    'shstrtab' => $str,
    'sects' => \@sects,
    'progs' => \@progs,
    'loadprogs' => [ grep {$_->{'type'} == 1} @progs ],
  };
  return bless $elf;
}

1;
