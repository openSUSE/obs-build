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

package Build::Arch;

use strict;
use Digest::MD5;

eval { require Archive::Tar; };
*Archive::Tar::new = sub {die("Archive::Tar is not available\n")} unless defined &Archive::Tar::new;


# Archlinux support, based on the GSoC work of Nikolay Rysev <mad.f3ka@gmail.com>

# parse a PKGBUILD file

sub expandvars {
  my ($str, $vars) = @_;
  $str =~ s/\$([a-zA-Z0-9_]+|\{([^\}]+)\})/join(' ', @{$vars->{$2 || $1} || []})/ge;
  return $str;
}

sub quote {
  my ($str, $q, $vars) = @_;
  $str = expandvars($str, $vars) if $q ne "'" && $str =~ /\$/;
  $str =~ s/([ \t\"\'\$])/sprintf("%%%02X", ord($1))/ge;
  return $str;
}

sub unquotesplit {
  my ($str, $vars) = @_;
  $str =~ s/%/%25/g;
  $str =~ s/^[ \t]+//;
  while ($str =~ /([\"\'])/) {
    my $q = $1;
    last unless $str =~ s/$q(.*?)$q/quote($1, $q, $vars)/e;
  }
  $str = expandvars($str, $vars) if $str =~ /\$/;
  my @args = split(/[ \t]+/, $str);
  for (@args) {
    s/%([a-fA-F0-9]{2})/chr(hex($1))/ge
  }
  return @args;
}

sub get_assets {
  my ($vars, $asuf) = @_;
  my @digests;
  for my $digesttype ('sha512', 'sha256', 'sha1', 'md5') {
    @digests = map {$_ eq 'SKIP' ? $_ : "$digesttype:$_"} @{$vars->{"${digesttype}sums$asuf"} || []};
    last if @digests;
  }
  # work around bug in source parser
  my @sources;
  for (@{$vars->{"source$asuf"} || []}) {
    push @sources, $_;
    splice(@sources, -1, 1, $1, "$1.sig") if /(.*)\{,\.sig\}$/;
  }
  my @assets;
  for my $s (@sources) {
    my $digest = shift @digests;
    next unless $s =~ /^https?:\/\/.*\/([^\.\/][^\/]+)$/s;
    my $asset = { 'url' => $s };
    $asset->{'digest'} = $digest if $digest && $digest ne 'SKIP';
    push @assets, $asset;
  }
  return @assets;
}

sub parse {
  my ($config, $pkgbuild) = @_;
  my $ret;
  my $pkgfd;
  if (!open($pkgfd, '<', $pkgbuild)) {
    $ret->{'error'} = "$pkgbuild: $!";
    return $ret;
  }
  my %vars;
  my @ifs;
  while (<$pkgfd>) {
    chomp;
    next if /^\s*$/;
    next if /^\s*#/;
    s/^\s+//;
    if (/^(el)?if\s+(?:(?:test|\[)\s+(-n|-z)\s+)?(.*?)\s*\]?\s*;\s*then\s*$/) {
      if ($1) {
        $ifs[-1] += 1;
        next if $ifs[-1] != 1;
        pop @ifs;
      }
      my $flag = $2 || '-n';
      my $t = join('', unquotesplit($3, \%vars));
      $t = $t eq '' ? 'true' : '' if $flag eq '-z';
      push @ifs, $t ne '' ? 1 : 0;
      next;
    }
    if (@ifs) {
      if (/^fi\s*$/) {
        pop @ifs;
        next;
      } elsif (/^else\s*$/) {
        $ifs[-1] += 1;
        next;
      }
      next if grep {$_ != 1} @ifs;
    }
    last unless /^([a-zA-Z0-9_]*)(\+?)=(\(?)(.*?)$/;
    my $var = $1;
    my $app = $2;
    my $val = $4;
    if ($3) {
      while ($val !~ s/\)\s*(?:#.*)?$//s) {
	my $nextline = <$pkgfd>;
	last unless defined $nextline;
	chomp $nextline;
	$val .= ' ' . $nextline;
      }
    }
    if ($app) {
      push @{$vars{$var}}, unquotesplit($val, \%vars);
    } else {
      $vars{$var} = [ unquotesplit($val, \%vars) ];
    }
  }
  close $pkgfd;
  $ret->{'name'} = $vars{'pkgname'}->[0] if $vars{'pkgname'};
  $ret->{'version'} = $vars{'pkgver'}->[0] if $vars{'pkgver'};
  $ret->{'deps'} = [];
  push @{$ret->{'deps'}}, @{$vars{$_} || []} for qw{makedepends checkdepends depends};
  # get arch from macros
  my ($arch) = Build::gettargetarchos($config);
  # map to arch linux name and add arch dependent
  $arch = 'i686' if $arch =~ /^i[345]86$/;
  push @{$ret->{'deps'}}, @{$vars{"${_}_$arch"} || []} for qw{makedepends checkdepends depends};
  # Maintain architecture-specific sources for officially supported architectures
  for my $asuf ('', '_i686', '_x86_64') {
    $ret->{"source$asuf"} = $vars{"source$asuf"} if $vars{"source$asuf"};
  }
  # find remote assets
  for my $asuf ('', "_$arch") {
    next unless @{$vars{"source$asuf"} || []};
    my @assets = get_assets(\%vars, $asuf);
    push @{$ret->{'remoteassets'}}, @assets if @assets;
  }
  my %exclarch = map {$_ => 1} @{$vars{'arch'} || []};
  if (%exclarch && !$exclarch{'any'}) {
    # map to obs scheduler names
    $exclarch{'i386'} = $exclarch{'i486'} = $exclarch{'i586'} = $exclarch{'i686'} = 1 if $exclarch{'i386'} || $exclarch{'i486'} || $exclarch{'i586'} || $exclarch{'i686'};
    $ret->{'exclarch'} = [ sort keys %exclarch ];
  }
  return $ret;
}

sub islzma {
  my ($fn) = @_;
  return 0 unless open(my $fd, '<', $fn);
  my $h;
  return 0 unless read($fd, $h, 5) == 5;
  close $fd;
  return $h eq "\3757zXZ";
}

sub iszstd {
  my ($fn) = @_;
  return 0 unless open(my $fd, '<', $fn);
  my $h;
  return 0 unless read($fd, $h, 4) == 4;
  close $fd;
  return $h eq "(\265\057\375";
}

sub lzmadec {
  my ($fn) = @_;
  my $nh;
  my $pid = open($nh, '-|');
  return undef unless defined $pid;
  if (!$pid) {
    $SIG{'PIPE'} = 'DEFAULT';
    exec('xzdec', '-dc', $fn);
    die("xzdec: $!\n");
  }
  return $nh;
}

sub zstddec {
  my ($fn) = @_;
  my $nh;
  my $pid = open($nh, '-|');
  return undef unless defined $pid;
  if (!$pid) {
    $SIG{'PIPE'} = 'DEFAULT';
    exec('zstdcat', $fn);
    die("zstdcat $!\n");
  }
  return $nh;
}

sub queryvars {
  my ($handle) = @_;

  if (ref($handle)) {
    die("arch pkg query not implemented for file handles\n");
  }
  if ($handle =~ /\.zst$/ || iszstd($handle)) {
    $handle = zstddec($handle);
  } elsif ($handle =~ /\.xz$/ || islzma($handle)) {
    $handle = lzmadec($handle);
  }
  my $tar = Archive::Tar->new;
  my @read = $tar->read($handle, 1, {'filter' => '^\.PKGINFO$', 'limit' => 1});
  die("$handle: not an arch package file\n") unless @read ==  1;
  my $pkginfo = $read[0]->get_content;
  die("$handle: not an arch package file\n") unless $pkginfo;
  my %vars;
  $vars{'_pkginfo'} = $pkginfo;
  for my $l (split('\n', $pkginfo)) {
    next unless $l =~ /^(.*?) = (.*)$/;
    push @{$vars{$1}}, $2;
  }
  return \%vars;
}

sub queryfiles {
  my ($handle) = @_;
  if (ref($handle)) {
    die("arch pkg query not implemented for file handles\n");
  }
  if ($handle =~ /\.zst$/ || iszstd($handle)) {
    $handle = zstddec($handle);
  } elsif ($handle =~ /\.xz$/ || islzma($handle)) {
    $handle = lzmadec($handle);
  }
  my @files;
  my $tar = Archive::Tar->new;
  # we use filter_cb here so that Archive::Tar skips the file contents
  $tar->read($handle, 1, {'filter_cb' => sub {
    my ($entry) = @_;
    push @files, $entry->full_path unless $entry->is_longlink || (@files && $files[-1] eq $entry->full_path);
    return 0;
  }});
  shift @files if @files && $files[0] eq '.PKGINFO';
  return \@files;
}

sub query {
  my ($handle, %opts) = @_;
  my $vars = queryvars($handle);
  my $ret = {};
  $ret->{'name'} = $vars->{'pkgname'}->[0] if $vars->{'pkgname'};
  $ret->{'hdrmd5'} = Digest::MD5::md5_hex($vars->{'_pkginfo'});
  $ret->{'provides'} = $vars->{'provides'} || [];
  $ret->{'requires'} = $vars->{'depend'} || [];
  if ($vars->{'pkgname'} && $opts{'addselfprovides'}) {
    my $selfprovides = $vars->{'pkgname'}->[0];
    $selfprovides .= "=$vars->{'pkgver'}->[0]" if $vars->{'pkgver'};
    push @{$ret->{'provides'}}, $selfprovides unless @{$ret->{'provides'} || []} && $ret->{'provides'}->[-1] eq $selfprovides;
  }
  if ($opts{'evra'}) {
    if ($vars->{'pkgver'}) {
      my $evr = $vars->{'pkgver'}->[0];
      if ($evr =~ /^([0-9]+):(.*)$/) {
	$ret->{'epoch'} = $1;
	$evr = $2;
      }
      $ret->{'version'} = $evr;
      if ($evr =~ /^(.*)-(.*?)$/) {
	$ret->{'version'} = $1;
	$ret->{'release'} = $2;
      }
    }
    $ret->{'arch'} = $vars->{'arch'}->[0] if $vars->{'arch'};
  }
  if ($opts{'description'}) {
    $ret->{'description'} = $vars->{'pkgdesc'}->[0] if $vars->{'pkgdesc'};
  }
  if ($opts{'conflicts'}) {
    $ret->{'conflicts'} = $vars->{'conflict'} if $vars->{'conflict'};
    $ret->{'obsoletes'} = $vars->{'replaces'} if $vars->{'replaces'};
  }
  if ($opts{'weakdeps'}) {
    my @suggests = @{$vars->{'optdepend'} || []};
    s/:.*// for @suggests;
    $ret->{'suggests'} = \@suggests if @suggests;
  }
  # arch packages don't seem to have a source :(
  # fake it so that the package isn't confused with a src package
  $ret->{'source'} = $ret->{'name'} if defined $ret->{'name'};
  $ret->{'buildtime'} = $vars->{'builddate'}->[0] if $opts{'buildtime'} && $vars->{'builddate'};
  return $ret;
}

sub queryhdrmd5 {
  my ($handle) = @_;
  if (ref($handle)) {
    die("arch pkg query not implemented for file handles\n");
  }
  if ($handle =~ /\.zst$/ || iszstd($handle)) {
    $handle = zstddec($handle);
  } elsif ($handle =~ /\.xz$/ || islzma($handle)) {
    $handle = lzmadec($handle);
  }
  my $tar = Archive::Tar->new;
  my @read = $tar->read($handle, 1, {'filter' => '^\.PKGINFO$', 'limit' => 1});
  die("$handle: not an arch package file\n") unless @read ==  1;
  my $pkginfo = $read[0]->get_content;
  die("$handle: not an arch package file\n") unless $pkginfo;
  return Digest::MD5::md5_hex($pkginfo);
}

sub parserepodata {
  my ($d, $data) = @_;
  $d ||= {};
  $data =~ s/^\n+//s;
  my @parts = split(/\n\n+/s, $data);
  for my $part (@parts) {
    my @p = split("\n", $part);
    my $p = shift @p;
    if ($p eq '%NAME%') {
      $d->{'name'} = $p[0];
    } elsif ($p eq '%VERSION%') {
      $d->{'version'} = $p[0];
    } elsif ($p eq '%ARCH%') {
      $d->{'arch'} = $p[0];
    } elsif ($p eq '%BUILDDATE%') {
      $d->{'buildtime'} = $p[0];
    } elsif ($p eq '%FILENAME%') {
      $d->{'filename'} = $p[0];
    } elsif ($p eq '%PROVIDES%') {
      push @{$d->{'provides'}}, @p;
    } elsif ($p eq '%DEPENDS%') {
      push @{$d->{'requires'}}, @p;
    } elsif ($p eq '%OPTDEPENDS%') {
      push @{$d->{'suggests'}}, @p;
    } elsif ($p eq '%CONFLICTS%') {
      push @{$d->{'conflicts'}}, @p;
    } elsif ($p eq '%REPLACES%') {
      push @{$d->{'obsoletes'}}, @p;
    } elsif ($p eq '%MD5SUM%') {
      $d->{'checksum_md5'} = $p[0];
    } elsif ($p eq '%SHA256SUM%') {
      $d->{'checksum_sha256'} = $p[0];
    }
  }
  return $d;
}

sub queryinstalled {
  my ($root, %opts) = @_; 

  $root = '' if !defined($root) || $root eq '/';
  opendir(my $dirfd, "$root/var/lib/pacman/local") || return [];
  my @pn = sort(grep {!/^\./} readdir($dirfd));
  closedir($dirfd);
  my @pkgs;
  for my $pn (@pn) {
    next unless open(my $fd, '<', "$root/var/lib/pacman/local/$pn/desc");
    my $data = '';
    1 while sysread($fd, $data, 8192, length($data));
    close $fd;
    my $d = parserepodata(undef, $data);
    next unless defined $d->{'name'};
    my $q = {};
    for (qw{name arch buildtime version}) {
      $q->{$_} = $d->{$_} if defined $d->{$_};
    }
    $q->{'epoch'} = $1 if $q->{'version'} =~ s/^(\d+)://s;
    $q->{'release'} = $1 if $q->{'version'} =~ s/-([^-]*)$//s;
    push @pkgs, $q;
  }
  return \@pkgs;
}


1;
