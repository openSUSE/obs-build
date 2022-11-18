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
  my $mode = $ent->{'mode'};
  my $cpiotype = $ent->{'cpiotype'};
  my $ino = $ent->{'inode'};
  my $mtime = $ent->{'mtime'};
  my $size = $ent->{'size'};
  $cpiotype = (($mode || 0) >> 12) || 8 unless defined $cpiotype;
  $mode = $cpiotype == 4 ? 0x1ed : 0x1a4 unless defined $mode;
  $mode = ($mode & ~0xf000) | ($cpiotype << 12);
  $mtime = $s ? $s->[9] : time() unless defined $mtime;
  $size = $s ? $s->[7] : 0 unless defined $size;
  $ino = ($ino || 0) & 0xffffffff;
  my $h = sprintf("070701%08x%08x000000000000000000000001%08x", $ino, $mode, $mtime);
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

sub copyout {
  my ($ofd, $file, $size) = @_;
  my $fd;
  open($fd, '<', $file) || die("$file: $!\n");
  while ($size > 0) {
    my $d;
    sysread($fd, $d, $size > 8192 ? 8192 : $size, 0);
    die("$file: unexpected EOF\n") unless length($d);
    print $ofd $d or die("cpio write: $!\n");
    $size -= length($d);
  }
  close($fd);
}

sub copyin {
  my ($ifd, $file, $size) = @_;
  my $fd;
  open($fd, '>', $file) || die("$file: $!\n");
  while ($size > 0) {
    my $chunk = cpio_read($ifd, $size > 65536 ? 65536 : $size);
    print $fd $chunk or die("$file write: $!\n");
    $size -= length($chunk);
  }
  close($fd) || die("$file: $!\n");
}

sub skipin {
  my ($ifd, $size) = @_;
  while ($size > 0) {
    my $chunk = cpio_read($ifd, $size > 65536 ? 65536 : $size);
    $size -= length($chunk);
  }
}

sub cpio_create {
  my ($fd, $dir, %opts) = @_;
  my @todo;
  my $prefix = defined($opts{'prefix'}) ? $opts{'prefix'} : '';
  my $prefixdir;
  if ($prefix =~ /(.+)\/$/) {
    $prefixdir = $1;
    my @s = stat("$dir/.");
    die("$dir: $!\n") unless @s;
    $s[7] = 0;
    unshift @todo, [ '', @s ];
  }
  if ($opts{'dircontent'}) {
    unshift @todo, @{$opts{'dircontent'}};
  } else {
    unshift @todo, sort(PBuild::Util::ls($dir));
  }
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
      $ent = { 'cpiotype' => 4, 'size' => 0 };
      ($name, @s) = @$name;
    } elsif (-l _) {
      my $lnk = readlink("$dir/$name");
      die("readlink $dir/$name: $!\n") unless defined $lnk;
      $ent = { 'cpiotype' => 10, 'size' => length($lnk), 'data' => $lnk };
    } elsif (-d _) {
      unshift @todo, [ $name, @s ];
      unshift @todo, map {"$name/$_"} sort(PBuild::Util::ls("$dir/$name"));
      next;
    } elsif (-f _) {
      $ent = { 'cpiotype' => 8, 'size' => $s[7] };
    } else {
      die("unsupported file type $s[2]: $dir/$name\n");
    }
    $ent->{'mode'} = $s[2] & 0xfff;
    $ent->{'name'} = $name eq '' ? $prefixdir : "$prefix$name";
    $ent->{'mtime'} = $opts{'mtime'} if defined $opts{'mtime'};
    $ent->{'inode'} = $ino++;
    my ($h, $pad) = cpio_make($ent, \@s);
    print $fd $h;
    print $fd $ent->{'data'} if defined $ent->{'data'};
    copyout($fd, "$dir/$name", $ent->{'size'}) if $ent->{'cpiotype'} == 8 && $ent->{'size'};
    print $fd $pad or die("cpio write: $!\n");
  }
  print $fd cpio_make() or die("cpio write: $!\n");
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

sub set_mode_mtime {
  my ($ent, $outfile, $opts) = @_;
  if ($opts->{'set_mode'}) {
    chmod($ent->{'mode'} & 07777, $outfile);
  }
  if ($opts->{'set_mtime'}) {
    utime($ent->{'mtime'}, $ent->{'mtime'}, $outfile);
  }
}

sub cpio_extract {
  my ($cpiofile, $out, %opts) = @_;
  my $fd;
  my $extract = $opts{'extract'};
  open($fd, '<', $cpiofile) || die("$cpiofile: $!\n");
  my %symlinks;
  while (1) {
    my $cpiohead = cpio_read($fd, 110);
    my ($ent, $namesize, $namepad, $size, $pad) = cpio_parse($cpiohead);
    my $name = substr(cpio_read($fd, $namesize + $namepad), 0, $namesize);
    $name =~ s/\0.*//s;
    if (!$size && $name eq 'TRAILER!!!') {
      die("$cpiofile: no $extract entry\n") if defined($extract) && !$opts{'missingok'};
      last;
    }
    $name =~ s/^\.\///s;
    $ent->{'name'} = $name;
    my $outfile = "$out/$name";
    $outfile = $ent->{'cpiotype'} == 8 && $name eq $extract ? $out : undef if defined $extract;
    $outfile = $out->($ent, undef) if defined($outfile) && ref($out) eq 'CODE';
    if (!defined($outfile)) {
      skipin($fd, $size + $pad);
      next;
    }
    PBuild::Util::mkdir_p($1) if $name =~ /\// && $outfile =~ /(.*)\//;
    if ($ent->{'cpiotype'} == 4) {
      if (-l $outfile || ! -d _) {
        mkdir($outfile, 0755) || die("mkdir $outfile: $!\n");
      }
    } elsif ($ent->{'cpiotype'} == 10) {
      die("illegal symlink size\n") if $size > 65535;
      my $lnk = cpio_read($fd, $size);
      unlink($outfile);
      if ($opts{'postpone_symlinks'}) {
	$symlinks{$outfile} = $lnk;
      } else {
        symlink($lnk, $outfile) || die("symlink $lnk $outfile: $!\n");
      }
    } elsif ($ent->{'cpiotype'} == 8) {
      unlink($outfile);
      copyin($fd, $outfile, $size);
    } else {
      die("unsupported cpio type $ent->{'cpiotype'}\n");
    }
    set_mode_mtime($ent, $outfile, \%opts) if $ent->{'cpiotype'} != 10;
    if (ref($out) eq 'CODE') {
      last if $out->($ent, $outfile);
    }
    last if defined $extract;
    cpio_read($fd, $pad) if $pad;
  }
  for my $outfile (sort {$b cmp $a} keys %symlinks) {
    unlink($outfile);
    symlink($symlinks{$outfile}, $outfile) || die("symlink $symlinks{$outfile} $outfile: $!\n");
  }
  close($fd);
}

1;
