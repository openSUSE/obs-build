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

use strict;

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
    die("$cpiofile: no '$name' entry\n") if !$size && $name eq 'TRAILER!!!';
    $name =~ s/^\.\///s;
    if ($name ne $extract) {
      $size += $pad;
      while ($size > 0) {
        my $chunk = cpio_read($fd, $size > 65536 ? 65536 : $size);
        $size -= length($chunk);
      }
      next;
    }
    my $outfd;
    open ($outfd, '>', $outfile) || die("$outfile: $!\n");
    while ($size > 0) {
      my $chunk = cpio_read($fd, $size > 65536 ? 65536 : $size);
      print $outfd $chunk or die("$outfile:$!\n");
      $size -= length($chunk);
    }
    close($outfd) || die("$outfile: $!\n");
    last;
  }
  close($fd);
}

1;
