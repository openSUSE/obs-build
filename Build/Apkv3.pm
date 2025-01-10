################################################################
#
# Copyright (c) 2025 SUSE Linux LLC
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

package Build::Apkv3;

eval { require Compress::Raw::Zlib };
*Compress::Raw::Zlib::Inflate::new = sub {die("Compress::Raw::Zlib is not available\n")} unless defined &Compress::Raw::Zlib::Inflate::new;

use POSIX;

use Digest::MD5 ();
use Digest::SHA ();

use strict;

sub Build::Apkv3::decomp::TIEHANDLE {
  my ($class, $fd, $decomp) = @_;
  my $self = bless { 'fd' => $fd, 'decomp' => $decomp }, $class;
  if ($decomp eq 'deflate') {
    my $z = new Compress::Raw::Zlib::Inflate(-WindowBits => -15);
    $self->{'z'} = $z;
  } elsif ($decomp eq 'zstd') {
    my $z = new Compress::Stream::Zstd::Decompressor;
    $self->{'z'} = $z;
  } else {
    die("unknown decompressor $decomp\n");
  }
  $self->{'inbuf'} = '';
  $self->{'buf'} = '';
  return $self;
}

sub Build::Apkv3::decomp::READ {
  my $self = $_[0];
  my $l = $_[2];
  my $off = $_[3];
  $off = 0 unless defined $off;
  substr($_[1], $off) = '';
  return 0 unless $l > 0;
  my $r = 0;
  while ($l > 0) {
    my $bl = length($self->{'buf'});
    if ($bl) {
      $bl = $l if $bl > $l;
      substr($_[1], $off, 0, substr($self->{'buf'}, 0, $bl, ''));
      $off += $bl;
      $r += $bl;
      $l -= $bl;
      next;
    }
    if (!length($self->{'inbuf'})) {
      my $rr = read($self->{'fd'}, $self->{'inbuf'}, 4096);
      return undef unless defined $rr;
      return $r if $rr == 0;
    }
    my $new;
    if ($self->{'decomp'} eq 'zstd') {
      $new = $self->{'z'}->decompress($self->{'inbuf'});
      $self->{'inbuf'} = '';
      return undef unless defined $new;
    } else {
      my $rr = $self->{'z'}->inflate($self->{'inbuf'}, $new);
      return unless $rr == Compress::Raw::Zlib::Z_STREAM_END() || $rr == Compress::Raw::Zlib::Z_OK();
    }
    $self->{'buf'} = $new;
  }
  return $r;
}

sub Build::Apkv3::decomp::CLOSE {
  my ($self) = @_;
  delete $self->{'z'};
}

my @dep_ops = ( undef, '=', '<', '<=', '>', '>=', undef, undef,
               '~', '~', undef, '<~', undef, '>~', undef, undef);

sub dep_postprocess {
  my ($v) = @_;
  my $evr = $v->{'evr'};
  return $v->{'name'} unless defined $evr;
  my $match = $v->{'match'};
  $match = defined($match) ? ($dep_ops[$match] || '?') : '=';
  return "$v->{'name'}$match$evr";
}

sub hash_postprocess {
  unpack('H*', $_[0]);
}

my $dep_schema = [
  [ 'b', 'name' ],
  [ 'b', 'evr' ],
  [ 'i', 'match' ],
];

my $pkg_info_schema = [
  [ 'b', 'pkgname' ],
  [ 'b', 'pkgver' ],
  [ 'b', 'apkchksum', undef, \&hash_postprocess ],
  [ 'b', 'pkgdesc' ],
  [ 'b', 'arch' ],
  [ 'b', 'license' ],
  [ 'b', 'origin' ],
  [ 'b', 'maintainer' ],
  [ 'b', 'url' ],
  [ 'b', 'commit', undef, \&hash_postprocess ],
  [ 'i', 'builddate' ],
  [ 'i', 'size' ], 
  [ 'i', 'filesize' ], 
  [ 'i', 'provider_priority'],
  [ 'o*', 'depend', $dep_schema, \&dep_postprocess ],
  [ 'o*', 'provides', $dep_schema, \&dep_postprocess ],
  [ 'o*', 'replaces', $dep_schema, \&dep_postprocess ],
  [ 'o*', 'install_if', $dep_schema, \&dep_postprocess ],
  [ 'o*', 'recommends', $dep_schema, \&dep_postprocess ],
  [ 'i', 'layer' ],
];

my $acl_schema = [
  [ 'i', 'mode' ],
  [ 'b', 'user' ],
  [ 'b', 'group' ],
];

my $file_schema = [
  [ 'b', 'name' ],
  [ 'o', '', $acl_schema ],
  [ 'i', 'size' ],
  [ 'i', 'mtime' ],
  [ 'b', 'hash', undef, \&hash_postprocess ],
  [ 'b', 'target', undef, \&hash_postprocess ],
];

my $dir_schema = [
  [ 'b', 'name' ],
  [ 'o', '', $acl_schema ],
  [ 'o*', 'files', $file_schema ],
];

my $scripts_schema = [
  [ 'b', 'trigger' ],
  [ 'b', 'preinstall' ],
  [ 'b', 'postinstall' ],
  [ 'b', 'preuninstall' ],
  [ 'b', 'postuninstall' ],
  [ 'b', 'preupgrade' ],
  [ 'b', 'postupgrade' ],
];

my $pkg_schema_justinfo = [
  [ 'o', '', $pkg_info_schema ],
];

my $pkg_schema = [
  [ 'o', '', $pkg_info_schema ],
  [ 'o*', 'dirs', $dir_schema ],
  [ 'o', '', $scripts_schema ],
  [ 'b*', 'pkg_triggers' ],
  [ 'i', 'replaces_prio' ],
];

my $index_schema = [
  [ 'b', 'description' ],
  [ 'o*', 'packages', $pkg_info_schema ],
];

sub walk {
  #my ($adb, $data, $schema, $vals, $multi) = @_;
  my @s = @{$_[2]};
  my @vals = @{$_[3]};
  my $multi = $_[4];
  while (@vals && @s) {
    my $s = shift @s;
    my $v = shift @vals;
    next if !defined($s) || !defined($s->[0]);
    my $t = ($v >> 28) & 0x0f;
    $v &= 0xfffffff;
    next if $t == 0 && $v == 0;	# NULL
    my ($st, $name, $oschema, $cvt) = @$s;
    next unless defined $st && defined $name;
    if ($st =~ s/\*$// && !$multi) {
      my $num = unpack("\@${v}V", $_[0]);
      my @v = unpack("\@${v}V$num", $_[0]);
      die unless @v && @v == $num;
      shift @v;
      walk($_[0], $_[1], [ ($s) x ($num - 1) ], \@v, 1);
      next;
    }
    if ($st eq 'b') {
      die("wrong type for blob ($t)\n") if $t != 8 && $t != 9 && $t != 10;
      my $l;
      $l = unpack("\@${v}C", $_[0]) if $t == 8;
      $l = unpack("\@${v}v", $_[0]) if $t == 9;
      $l = unpack("\@${v}V", $_[0]) if $t == 10;
      $v = substr($_[0], $v + $t - 7 + ($t == 10 ? 1 : 0), $l);
    } elsif ($st eq 'i') {
      die("wrong type for int ($t)\n") if $t != 1 && $t != 2 && $t != 3;
      $v = unpack("\@${v}V", $_[0]) if $t == 2;
      $v = unpack("\@${v}V", $_[0]) + (unpack("\@${v}VV", $_[0]))[1] * 65536 * 65536 if $t == 3;
    } elsif ($st eq 'o') {
      die("wrong type for obj ($t)\n") if $t != 14;
      my $num = unpack("\@${v}V", $_[0]);
      my @v = unpack("\@${v}V$num", $_[0]);
      die unless @v && @v == $num;
      shift @v;
      $v = $name eq '' ? $_[1]: {};
      walk($_[0], $v, $s->[2], \@v);
      next if $name eq '';
    } else {
      die("unsupported type $st in schema\n");
    }
    $v = $s->[3]->($v) if $cvt;
    if ($multi) {
      push @{$_[1]->{$name}}, $v;
    } else {
      $_[1]->{$name} = $v;
    }
  }
}

sub walk_root {
  #my ($adb, $schema) = @_;
  my $schema = $_[1];
  my $data = {};
  my $v = unpack('@4V', $_[0]);
  walk($_[0], $data, [[ 'o', '', $schema ]], [ $v ]);
  return $data;
}

sub doread {
  my ($fd, $l) = @_;
  my $buf = '';
  while ($l > 0) {
    my $r = read($fd, $buf, $l, length($buf));
    next if !defined($r) && $! == POSIX::EINTR;
    die("read: $!\n") unless defined $r;
    die("read: unexpected EOF\n") unless $r;
    $l -= $r;
  }
  return $buf;
}

sub read_file_header {
  my ($fd) = @_;
  my $hdr = doread($fd, 8);
  die("not a apkv3 file\n") unless substr($hdr, 0, 4, '') eq 'ADB.';
  return $hdr;
}

sub read_blk_header {
  my ($fd) = @_;
  my $type_size = unpack('V', doread($fd, 4));
  my ($type, $size) = ((($type_size >> 30) & 3), ($type_size & 0x3fffffff));
  my $pad = $size & 7;;
  if ($type == 3) {
    $type = $size;
    my @s = unpack('VVV', doread($fd, 12));
    $size = $s[1] + $s[2] * 65536 * 65536;
    $pad = $s[1] & 7;
    $size -= 12;
  }
  $size -= 4;
  die("bad apkv3 block size\n") if $size < 0;
  return ($type, $size, $pad ? 8 - $pad : 0);
}

my $have_zstd_module;

sub open_apk {
  my ($file) = @_;
  my $fd;
  open($fd, '<', $file) || die("$file: $!\n");
  my $first;
  read($fd, $first, 4) == 4 || die("$file read error: $!\n");
  if ($first eq 'ADB.') {
    seek($fd, 0, 0) || die("$file seek error: $!\n");
    return $fd;
  }
  my $decomp;
  if ($first eq 'ADBd') {
    $decomp = 'deflate';
  } elsif ($first eq 'ADBc') {
    my $algo_level;
    read($fd, $algo_level, 2) == 2 || die("$file read error: $!\n");
    my $algo = unpack('C', $algo_level);
    return $fd if $algo == 0;
    $decomp = 'deflate' if $algo == 1;
    $decomp = 'zstd' if $algo == 2;
    die("open_apk: unknown compression algo $algo\n") unless $decomp;
  }
  if ($decomp eq 'zstd') {
    if (!defined($have_zstd_module)) {
      eval { require Compress::Stream::Zstd };
      $have_zstd_module = defined &Compress::Stream::Zstd::Decompressor::new ? 1 : 0;
    }
    if (!$have_zstd_module) {
      my $h;
      my $pid = open ($h, '-|');
      die("fork: $!\n") unless defined $pid;
      if (!$pid) {
        open(STDIN, '<&', $fd);
        close($fd);
        seek(STDIN, 6, 0) || die("seek\n");
        sysseek(STDIN, 6, 0) || die("sysseek\n");
	exec('zstd', '-dc');
        die("zstd: $!\n");
      }
      return $h;
    }
  }
  my $h = \do { local *F };
  tie(*{$h}, 'Build::Apkv3::decomp', $fd, $decomp);
  return $h;
}

sub querypkginfo {
  my ($file) = @_;
  my $fd = open_apk($file);
  die("nor an apk package file\n") unless read_file_header($fd) eq 'pckg';
  my ($adbtype, $adbsize, $adbpad) = read_blk_header($fd);
  die("bad adb block type\n") unless $adbtype == 0;
  die("oversized adb block\n") if $adbsize > 0x10000000;        # 256 MB
  my $adb = doread($fd, $adbsize);
  close($fd);
  return walk_root($adb, $pkg_schema_justinfo);
}

sub querypkgindex {
  my ($file) = @_;
  my $fd = open_apk($file);
  die("nor an apk index file\n") unless read_file_header($fd) == 'indx';
  my ($adbtype, $adbsize, $adbpad) = read_blk_header($fd);
  die("bad adb block type\n") unless $adbtype == 0;
  die("oversized adb block\n") if $adbsize > 0x80000000;        # 2 GB
  my $adb = doread($fd, $adbsize);
  close($fd);
  return walk_root($adb, $index_schema);
}

sub calcapkchksum {
  my ($file, $type, $section) = @_;
  $section ||= 'ctrl';
  $type ||= 'Q1';
  die("unsupported apkchksum type $type\n") unless $type eq 'Q1' || $type eq 'Q2' || $type eq 'X1' || $type eq 'X2' || $type eq 'md5';
  die("unsupported apkchksum section $section\n") unless $section eq 'ctrl';
  my $fd = open_apk($file);
  die("nor an apk package file\n") unless read_file_header($fd) eq 'pckg';
  my ($adbtype, $adbsize, $adbpad) = read_blk_header($fd);
  die("bad adb block type\n") unless $adbtype == 0;
  die("oversized adb block\n") if $adbsize > 0x10000000;        # 256 MB
  my $adb = doread($fd, $adbsize);
  close($fd);
  return 'Q1'.Digest::SHA::sha1_base64($adb) if $type eq 'Q1';
  return 'Q2'.Digest::SHA::sha256_base64($adb) if $type eq 'Q2';
  return 'X1'.Digest::SHA::sha1_hex($adb) if $type eq 'X1';
  return 'X2'.Digest::SHA::sha256_hex($adb) if $type eq 'X2';
  return Digest::MD5::md5_hex($adb) if $type eq 'md5';
  die("unsupported apkchksum type $type\n");
}

1;
