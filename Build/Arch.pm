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
      while ($val !~ s/\)\s*$//s) {
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
  push @{$ret->{'deps'}}, @{$vars{'depends'} || []};
  $ret->{'source'} = $vars{'source'} if $vars{'source'};
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
  if ($vars->{'pkgname'}) {
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
  # arch packages don't seem to have a source :(
  # fake it so that the package isn't confused with a src package
  $ret->{'source'} = $ret->{'name'} if defined $ret->{'name'};
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
    }
  }
  return $d;
}

1;
