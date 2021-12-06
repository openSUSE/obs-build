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

package PBuild::Cpio;

use PBuild::Util;

use strict;

# cpiotype: 1=pipe 2=char 4=dir 6=block 8=file 10=symlink 12=socket
sub cpio_make {
  my ($ent, $s) = @_;
  return ("07070100000000000000000000000000000000000000010000000000000000000000000000000000000000000000000000000b00000000TRAILER!!!\0\0\0\0") if !$ent;
  my $name = $ent->{'name'};
  my $mode = $ent->{'mode'} || 0x81a4;
  if (defined($ent->{'cpiotype'})) {
    $mode = ($mode & ~0xf000) | ($ent->{'cpiotype'} << 12);
  } else {
    $mode |= 0x8000 unless $mode & 0xf000;
  }
  my $mtime = defined($ent->{'mtime'}) ? $ent->{'mtime'} : $s->[9];
  my $ino = defined($ent->{'inode'}) ? $ent->{'inode'} : 0;
  $ino &= 0xffffffff if $ino > 0xffffffff;
  my $h = sprintf("070701%08x%08x000000000000000000000001%08x", $ino, $mode, $mtime);
  my $size = $s->[7];
  if ($size >= 0xffffffff) {
    # build service extension, size is in rmajor/rminor
    my $top = int($s->[7] / 4294967296);
    $size -= $top * 4294967296;
    $h .= sprintf("ffffffff0000000000000000%08x%08x", $top, $size);
  } else {
    $h .= sprintf("%08x00000000000000000000000000000000", $size);
  }
  $h .= sprintf("%08x", length($name) + 1);
  $h .= "00000000$name\0";
  $h .= substr("\0\0\0\0", (length($h) & 3)) if length($h) & 3;
  my $pad = $size % 4 ? substr("\0\0\0\0", $size % 4) : '';
  return ($h, $pad);
}

sub cpio_create {
  my ($fd, $dir, $mtime) = @_;
  my @todo;
  unshift @todo, sort(PBuild::Util::ls($dir));
  my $ino = 0;
  while (@todo) {
    my $name = shift @todo;
    my @s;
    if (!ref($name)) {
      @s = lstat("$dir/$name");
      die("$dir/$name: $!\n") unless @s;
    }
    my $ent;
    if (ref($name)) {
      $ent = { 'cpiotype' => 4 };
      ($name, @s) = @$name;
    } elsif (-l _) {
      my $lnk = readlink("$dir/$name");
      die("readlink $dir/$name: $!\n") unless defined $lnk;
      $s[7] = length($lnk);
      $ent = { 'cpiotype' => 10, 'data' => $lnk };
    } elsif (-d _) {
      $s[7] = 0;
      unshift @todo, [ $name, @s ];
      unshift @todo, map {"$name/$_"} sort(PBuild::Util::ls("$dir/$name"));
      next;
    } elsif (-f _) {
      $ent = { 'cpiotype' => 8 };
    } else {
      die("unsupported file type $s[2]: $dir/$name\n");
    }
    $ent->{'name'} = $name;
    $ent->{'mtime'} = $mtime if defined $mtime;
    $ent->{'inode'} = $ino++;
    my ($h, $pad) = cpio_make($ent, \@s);
    print $fd $h;
    print $fd $ent->{'data'} if defined $ent->{'data'};
    if ($ent->{'cpiotype'} == 8 && $s[7]) {
      my $if;
      open($if, '<', "$dir/$name") || die("$dir/$name: $!\n");
      while ($s[7] > 0) {
	my $d;
	sysread($if, $d, $s[7] > 8192 ? 8192 : $s[7], 0);
	die("$dir/$name: unexpected EOF\n") unless length($d);
	print $fd $d;
	$s[7] -= length($d);
      }
      close($if);
    }
    print $fd $pad;
  }
  print $fd cpio_make();
}

sub cpio_read {
  my ($fd, $l) = @_;
  my $r = '';
  die("bad cpio file\n") unless !$l || (read($fd, $r, $l) || 0) == $l;
  return $r;
}

sub cpio_parse {
  my ($cpiohead) = @_; 
  die("not a 'SVR4 no CRC ascii' cpio\n") unless substr($cpiohead, 0, 6) eq '070701';
  my $mode = hex(substr($cpiohead, 14, 8));
  my $mtime = hex(substr($cpiohead, 46, 8));
  my $size  = hex(substr($cpiohead, 54, 8));
  my $pad = (4 - ($size % 4)) % 4;
  my $namesize = hex(substr($cpiohead, 94, 8));
  my $namepad = (6 - ($namesize % 4)) % 4;
  if ($size == 0xffffffff) {
    # build service extension, size is in rmajor/rminor
    $size = hex(substr($cpiohead, 86, 8));
    $pad = (4 - ($size % 4)) % 4;
    $size += hex(substr($cpiohead, 78, 8)) * 4294967296;
    die("bad size extension\n") if $size < 0xffffffff;
  }
  die("ridiculous long filename\n") if $namesize > 8192;
  my $ent = { 'namesize' => $namesize , 'size' => $size, 'mtime' => $mtime, 'mode' => $mode, 'cpiotype' => ($mode >> 12 & 0xf) };
  return ($ent, $namesize, $namepad, $size, $pad);
}

sub cpio_extract {
  my ($cpiofile, $extract, $outfile) = @_;
  my $fd;
  open($fd, '<', $cpiofile) || die("$cpiofile: $!\n");
  while (1) {
    my $cpiohead = cpio_read($fd, 110);
    my ($ent, $namesize, $namepad, $size, $pad) = cpio_parse($cpiohead);
    my $name = substr(cpio_read($fd, $namesize + $namepad), 0, $namesize);
    $name =~ s/\0.*//s;
    if (!$size && $name eq 'TRAILER!!!') {
      die("$cpiofile: no '$extract' entry\n") if defined($extract);
      last;
    }
    $name =~ s/^\.\///s;
    my $real_outfile;
    if (!defined($extract) || $name eq $extract) {
      $real_outfile = $outfile;
      $real_outfile = $outfile->($name, undef) if ref($outfile) eq 'CODE';
    }
    if (!defined($real_outfile)) {
      $size += $pad;
      while ($size > 0) {
        my $chunk = cpio_read($fd, $size > 65536 ? 65536 : $size);
        $size -= length($chunk);
      }
      next;
    }
    my $outfd;
    open ($outfd, '>', $real_outfile) || die("$real_outfile: $!\n");
    while ($size > 0) {
      my $chunk = cpio_read($fd, $size > 65536 ? 65536 : $size);
      print $outfd $chunk or die("$outfile:$!\n");
      $size -= length($chunk);
    }
    close($outfd) || die("$real_outfile: $!\n");
    if (ref($outfile) eq 'CODE') {
      last if $outfile->($name, $real_outfile);
    }
    last if defined($extract);		# found the file we wanted
    cpio_read($fd, $pad) if $pad;
  }
  close($fd);
}

1;
