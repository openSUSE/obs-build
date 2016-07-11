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

sub quote {
  my ($str, $q, $vars) = @_;
  if ($q ne "'" && $str =~ /\$/) {
    $str =~ s/\$([a-zA-Z0-9_]+|\{([^\}]+)\})/$vars->{$2 || $1} ? join(' ', @{$vars->{$2 || $1}}) : "\$$1"/ge;
  }
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
  if ($str =~ /\$/) {
    $str =~ s/\$([a-zA-Z0-9_]+|\{([^\}]+)\})/$vars->{$2 || $1} ? join(' ', @{$vars->{$2 || $1}}) : "\$$1"/ge;
  }
  my @args = split(/[ \t]+/, $str);
  for (@args) {
    s/%([a-fA-F0-9]{2})/chr(hex($1))/ge
  }
  return @args;
}

sub parse {
  my ($config, $pkgbuild) = @_;
  my $ret;
  local *PKG;
  if (!open(PKG, '<', $pkgbuild)) {
    $ret->{'error'} = "$pkgbuild: $!";
    return $ret;
  }
  my %vars;
  while (<PKG>) {
    chomp;
    next if /^\s*$/;
    next if /^\s*#/;
    last unless /^([a-zA-Z0-9_]*)=(\(?)(.*?)$/;
    my $var = $1;
    my $val = $3;
    if ($2) {
      while ($val !~ s/\)\s*(?:#.*)?$//s) {
	my $nextline = <PKG>;
	last unless defined $nextline;
	chomp $nextline;
	$val .= ' ' . $nextline;
      }
    }
    $vars{$var} = [ unquotesplit($val, \%vars) ];
  }
  close PKG;
  $ret->{'name'} = $vars{'pkgname'}->[0] if $vars{'pkgname'};
  $ret->{'version'} = $vars{'pkgver'}->[0] if $vars{'pkgver'};
  $ret->{'deps'} = $vars{'makedepends'} || [];
  push @{$ret->{'deps'}}, @{$vars{'checkdepends'} || []};
  push @{$ret->{'deps'}}, @{$vars{'depends'} || []};
  # Add to depends packages also architecture-dependent ones
  # Suggestion of how to check architecture here are welcome
  push @{$ret->{'deps'}}, @{$vars{'makedepends_i686'} || []};
  push @{$ret->{'deps'}}, @{$vars{'depends_i686'} || []};
  push @{$ret->{'deps'}}, @{$vars{'checkdepends_i686'} || []};
  push @{$ret->{'deps'}}, @{$vars{'makedepends_x86_64'} || []};
  push @{$ret->{'deps'}}, @{$vars{'checkdepends_x86_64'} || []};
  push @{$ret->{'deps'}}, @{$vars{'depends_x86_64'} || []};
  $ret->{'source'} = $vars{'source'} if $vars{'source'};
  # Maintain architecture-specific sources for officially supported architectures
  $ret->{'source_x86_64'} = $vars{'source_x86_64'} if $vars{'source_x86_64'};
  $ret->{'source_i686'} = $vars{'source_i686'} if $vars{'source_i686'};
  return $ret;
}

sub islzma {
  my ($fn) = @_;
  local *F;
  return 0 unless open(F, '<', $fn);
  my $h;
  return 0 unless read(F, $h, 5) == 5;
  close F;
  return $h eq "\3757zXZ";
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

sub queryvars {
  my ($handle) = @_;

  if (ref($handle)) {
    die("arch pkg query not implemented for file handles\n");
  }
  if ($handle =~ /\.xz$/ || islzma($handle)) {
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
  if ($handle =~ /\.xz$/ || islzma($handle)) {
    $handle = lzmadec($handle);
  }
  my @files;
  my $tar = Archive::Tar->new;
  # we use filter_cb here so that Archive::Tar skips the file contents
  $tar->read($handle, 1, {'filter_cb' => sub {
    my ($entry) = @_;
    push @files, $entry->name unless $entry->is_longlink || (@files && $files[-1] eq $entry->name);
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
  if ($handle =~ /\.xz$/ || islzma($handle)) {
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
  local *D;
  local *F;
  opendir(D, "$root/var/lib/pacman/local") || return [];
  my @pn = sort(grep {!/^\./} readdir(D));
  closedir(D);
  my @pkgs;
  for my $pn (@pn) {
    next unless open(F, '<', "$root/var/lib/pacman/local/$pn/desc");
    my $data = '';
    1 while sysread(F, $data, 8192, length($data));
    close F;
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
