################################################################
#
# Copyright (c) 2024 SUSE Linux LLC
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

package Build::Apk;

use strict;

use Digest::MD5;

eval { require Archive::Tar };
*Archive::Tar::new = sub {die("Archive::Tar is not available\n")} unless defined &Archive::Tar::new;
eval { require Compress::Raw::Zlib };
*Compress::Raw::Zlib::Inflate::new = sub {die("Compress::Raw::Zlib is not available\n")} unless defined &Compress::Raw::Zlib::Inflate::new;


# can only do numeric + and - for now
sub expandvars_expr {
  my ($v, $vars) = @_;
  my $l = '+' . expandvars($v, $vars);
  my $r = 0;
  my $op = '';
  while ($l ne '') {
    next if $l =~ s/^\s+//;
    my $num;
    if ($l =~ s/^([0-9]+)//) {
      $num = $1;
    } elsif ($l =~ s/^([_a-zA-Z]+)//) {
      $num = $vars->{$1};
    } elsif ($l =~ s/^([\+\-])//) {
      $op = $1;
      next;
    } else {
      last;
    }
    $r += $num if $op eq '+';
    $r -= $num if $op eq '-';
    $op = '';
  }
  return $r;
}

sub expandvars_sh {
  my ($v, $vars) = @_;
  $v =~ s/%25/%/g;
  return expandvars_expr($1, $vars) if $v =~ /^\((.*)\)$/;
  my @l = unquotesplit($v, $vars);
  #print "SH ".join(', ', @l)."\n";
  if ($l[0] eq 'printf') {
    return sprintf $l[1], $l[2] if $l[1] =~ /^%[0-9]*d$/;
  }
  return '';
}

sub expandvars_cplx {
  my ($v, $vars) = @_;
  $v =~ s/%([a-fA-F0-9]{2})/$1 ne '00' ? chr(hex($1)) : ''/ge;
  return $vars->{$v} if defined $vars->{$v};
  $v = expandvars($v, $vars) if $v =~ /\$/;
  if ($v =~ /^([^\/#%]+):(\d+):(\d+)$/) {
    my ($v1, $v2, $v3) = ($vars->{$1}, $2, $3);
    return defined($v1) ? substr($v1, $v2, $v3) : '';
  }
  if ($v =~ /^([^\/#%]+):(\d+)$/) {
    my ($v1, $v2) = ($vars->{$1}, $2);
    return defined($v1) ? substr($v1, $v2) : '';
  }
  if ($v =~ /^([^\/#%]+)\/\/(.*)\/(.*)$/) {
    my ($v1, $v2, $v3) = ($vars->{$1}, $2, $3);
    return '' unless defined $v1;
    $v2 = glob2re($v2);
    $v1 =~ s/$v2/$v3/g;
    return $v1;
  }
  if ($v =~ /^([^\/#%]+)\/(.*)\/(.*)$/) {
    my ($v1, $v2, $v3) = ($vars->{$1}, $2, $3);
    return '' unless defined $v1;
    $v2 = glob2re($v2);
    $v1 =~ s/$v2/$v3/;
    return $v1;
  }
  if ($v =~ /^([^\/#%]+)%%(.*)$/) {
    my ($v1, $v2) = ($vars->{$1}, $2);
    return '' unless defined $v1;
    $v2 = glob2re($v2);
    $v1 =~ s/$v2$//;
    return $v1;
  }
  if ($v =~ /^([^\/#%]+)%(.*)$/) {
    my ($v1, $v2) = ($vars->{$1}, $2);
    return '' unless defined $v1;
    $v2 = glob2re($v2, 1);
    $v1 =~ s/(.*)$v2$/$1/;
    return $v1;
  }
  if ($v =~ /^([^\/#%]+)##(.*)$/) {
    my ($v1, $v2) = ($vars->{$1}, $2);
    return '' unless defined $v1;
    $v2 = glob2re($v2);
    $v1 =~ s/^$v2//;
    return $v1;
  }
  if ($v =~ /^([^\/#%]+)#(.*)$/) {
    my ($v1, $v2) = ($vars->{$1}, $2);
    return '' unless defined $v1;
    $v2 = glob2re($v2, 1);
    $v1 =~ s/^$v2//;
    return $v1;
  }
  if ($v =~ /^([^:]+):-(.*)$/) {
    my ($v1, $v2) = ($vars->{$1}, $2);
    $v1 = $v2 if !defined($v1) || $v1 eq '';
    return $v1;
  }
  return '';
}

sub expandvars {
  my ($str, $vars) = @_;
  $str =~ s/\$([a-zA-Z0-9_]+|\{(.+?)\}(?!\})|\((.+?)\)(?!\)))/defined($3) ? expandvars_sh($3, $vars) : defined($vars->{$2 || $1}) ? $vars->{$2 || $1} : expandvars_cplx($2 || $1, $vars)/ge;
  return $str;
}

sub quote {
  my ($str, $q, $vars) = @_;
  $str = expandvars($str, $vars) if $q ne "'" && $str =~ /\$/;
  $str =~ s/([ \n\t\"\'\$#])/sprintf("%%%02X", ord($1))/ge;
  $str = "%00" if $str eq '';	# so that split sees something
  return $str;
}

sub unquotesplit {
  my ($str, $vars, $unbalanced) = @_;
  $str =~ s/%/%25/g;
  $str =~ s/^[ \t]+//;
  my $re = $unbalanced ? qr{([\"\'\#])} : qr{([\"\'])}; 
  while ($str =~ /$re/) {
    last if $1 eq '#';
    my $q = $1;
    if ($str !~ s/$q(.*?)$q/quote($1, $q, $vars)/se) {
      return (undef) if $unbalanced;
      last;
    }
  }
  $str = expandvars($str, $vars) if $str =~ /\$/;
  my @args = split(/[ \t\n]+/, $str);
  for (@args) {
    s/%([a-fA-F0-9]{2})/$1 ne '00' ? chr(hex($1)) : ''/ge;
  }
  return @args;
}

sub get_assets {
  my ($vars) = @_;
  my @digests;
  for my $digesttype ('sha512', 'sha256') {
    next unless $vars->{"${digesttype}sums"};
    for (split("\n", $vars->{"${digesttype}sums"})) {
      push @digests, "$digesttype:$1" if /^([a-fA-F0-9]{16,})/;
    }
    last if @digests;
  }
  my @sources = split(' ', $vars->{'source'} || '');;
  return unless @sources;
  my @assets; 
  for my $s (@sources) {
    my $url = $s;
    my $file;
    ($file, $url) = ($1, $2) if $url =~ /^([^\/]+)::(.*)$/;
    my $digest = shift @digests;
    next unless $url =~ /^https?:\/\/.*\/([^\.\/][^\/]+)$/s;
    my $asset = { 'url' => $url };
    $asset->{'file'} = $file if defined $file;
    $asset->{'digest'} = $digest if $digest;
    push @assets, $asset;
  }
  return @assets;
}

# just enough for our needs
sub glob2re {
  my ($g, $nogreed) = @_;
  $nogreed = $nogreed ? '?' : '';
  $g = "\Q$g\E";
  $g =~ s/\\\-/-/g;
  $g =~ s/\\\*/.*$nogreed/g;
  $g =~ s/\\\?/./g;
  $g =~ s/\\\[([^\[\]]*?)\\\]/[$1]/g;
  return $g;
}

sub do_test {
  my (@args) = @_;
  my $idx;
  for ($idx = 1; $idx < @args - 1; $idx++) {
    if ($args[$idx] eq '&&' && ($args[$idx + 1] eq '[' || $args[$idx + 1] eq 'test')) {
      my @args1 = splice(@args, 0, $idx);
      pop @args1 if $args1[-1] eq ']';
      return 0 unless do_test(@args1);
      splice(@args, 0, 2);
      $idx = 0;
    }
  }
  my $t = 0;
  if ($args[0] eq '-z' && @args > 1) {
    $t = $args[1] eq '' ? 1 : 0;
  } elsif ($args[0] eq '-n' && @args > 1) {
    $t = $args[1] ne '' ? 1 : 0;
  } elsif (($args[1] eq '=' || $args[1] eq '==') && @args > 2) {
    $t = $args[0] eq $args[2] ? 1 : 0;
  } elsif ($args[1] eq '!=' && @args > 2) {
    $t = $args[0] ne $args[2] ? 1 : 0;
  } elsif (($args[1] eq '-ne') && @args > 2) {
    $t = $args[0] != $args[2] ? 1 : 0;
  } elsif (($args[1] eq '-eq') && @args > 2) {
    $t = $args[0] == $args[2] ? 1 : 0;
  } elsif (($args[1] eq '-lt') && @args > 2) {
    $t = $args[0] < $args[2] ? 1 : 0;
  } elsif (($args[1] eq '-le') && @args > 2) {
    $t = $args[0] <= $args[2] ? 1 : 0;
  } elsif (($args[1] eq '-gt') && @args > 2) {
    $t = $args[0] > $args[2] ? 1 : 0;
  } elsif (($args[1] eq '-ge') && @args > 2) {
    $t = $args[0] >= $args[2] ? 1 : 0;
  } elsif (@args == 1) {
    $t = $args[0] ne '' ? 1 : 0;
  }
  return $t;
}

sub readloopbody {
  my ($fh) = @_;
  my @body;
  while (<$fh>) {
    last if $_ =~ /^\s*done/;
    s/^\s*//;
    push @body, $_;
  }
  push @body, 'done';
  return @body > 1 ? \@body : undef;
}

sub parse {
  my ($config, $recipe) = @_;
  my $ret;
  local *PKG;
  if (!open(PKG, '<', $recipe)) {
    $ret->{'error'} = "$recipe: $!";
    return $ret;
  }
  my %vars;
  my @ifs;
  my $preamble = 1;
  my $incase;
  my $inloop;

  my ($arch, $os) = Build::gettargetarchos($config);
  $arch = 'x86' if $arch =~ /^i[3456]86$/;
  $vars{'CARCH'} = $arch;

  my @pushback;

  while (defined($_ = (@pushback ? shift @pushback : <PKG>))) {
    chomp;

    if ($inloop && !@pushback) {
      if ($inloop->[0]++ < 100) {
	if ($inloop->[1] eq 'for') {
	  if (@{$inloop->[3]}) {
	    $vars{$inloop->[2]} = shift @{$inloop->[3]};
	    push @pushback, @{$inloop->[4]};
	    next;
	  }
	} elsif ($inloop->[1] eq 'while') {
	  if (do_test(unquotesplit($inloop->[3], \%vars))) {
	    push @pushback, @{$inloop->[4]};
	    next;
	  }
	}
      }
      $inloop = undef;
      next;
    }
    
    if (defined $incase) {
      if (/^esac/) {
	undef $incase;
	next;
      }
      if (!ref($incase)) {
        next unless s/^([^\)]*)\)\s*//;
        my @m = grep {$_ ne ''} split(/[ \t\|]+/, $1);
        next unless grep { $incase =~ /^$_$/} map {glob2re($_)} @m;
	$incase = [ 1 ];
      }
      next unless $incase->[0];
      $incase = [ 0 ] if s/;;\s*$//;
    }

    next if /^\s*$/;
    next if /^\s*#/;
    s/^\s+//;
    if ($preamble && /^(el)?if\s+(?:test|\[)\s+(.*?)\s*\]?\s*;\s*then\s*$/) {
      if ($1) {
        $ifs[-1] += 1;
        next if $ifs[-1] != 1;
        pop @ifs;
      }
      my $t = do_test(unquotesplit($2, \%vars));
      push @ifs, $t;
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
    if ($preamble && /^\s*(?:test|\[)(.*?)\]?\s+\&\&\s+(.*)/) {
      $_ = $2;
      my $t = do_test(unquotesplit($1, \%vars));
      next unless $t;
    }
    if ($preamble && /^case /) {
      next unless /^case +(.*?) +in/;
      $incase = (unquotesplit($1, \%vars))[0];
      next;
    }
    if ($preamble && !$inloop && !@pushback && /^for ([a-zA-Z_][a-zA-Z0-9]*) in (.*);\s*do\s*$/) {
      my $var = $1;
      my @vals = unquotesplit($2, \%vars);
      my $body = readloopbody(\*PKG);
      $inloop = [ 0, 'for', $var, \@vals, $body ] if $body && @vals;
      push @pushback, 'done' if $inloop;
      next;
    }
    if ($preamble && !$inloop && !@pushback && /^while\s+\[\s(.+)\s+]\s*;\s*do\s*$/) {
      my $cond = $1;
      my $body = readloopbody(\*PKG);
      $inloop = [ 0, 'while', undef, $cond, $body ] if $body;
      push @pushback, 'done' if $inloop;
      next;
    }

    if (!/^([a-zA-Z0-9_]*)=([\"\']?)(.*?)$/) {
      $preamble = 0 if /^[a-z]+\(\)/;	# preamble ends at first function definition
      next;
    }
    my $var = $1;
    my $val = $3;
    next if !$preamble && !($var eq 'sha256sums' || $var eq 'sha512sums');
    if ($2) {
      $val="$2$val";
      # hack: change weird construct to something simpler
      $val =~ s/\$\{_pyname%\$\{_pyname#\?}}/\$\{_pyname:0:1}/;
      while (1) {
	my @words = unquotesplit($val, \%vars, 1);
	if (@words && !defined($words[0])) {
	  my $nextline = @pushback ? shift @pushback : <PKG>;
	  last unless defined $nextline;
	  chomp $nextline;
	  $val .= "\n" . $nextline;
	  next;
	}
        $vars{$var} = $words[0];
	last;
      }
    } else {
      my @words = unquotesplit($val, \%vars);
      $vars{$var} = $words[0];
    }
  }
  close PKG;
  $ret->{'name'} = $vars{'pkgname'} if defined $vars{'pkgname'};
  $ret->{'version'} = $vars{'pkgver'} if defined $vars{'pkgver'};
  $ret->{'release'} = "r$vars{'pkgrel'}" if defined $vars{'pkgrel'};
  $ret->{'deps'} = [];
  my @dnames = qw{depends makedepends};
  push @dnames, qw{makedepends_build makedepends_host} unless defined $vars{'makedepends'};
  push @dnames, 'checkdepends' unless grep {$_ eq '!check'} split(' ', $vars{'options'} || '');
  for (@dnames) {
    push @{$ret->{'deps'}}, split(" ", $vars{$_} ) if defined $vars{$_};
  }

  if ($vars{'subpackages'}) {
    $ret->{'subpacks'} = [ $ret->{'name'} ];
    for (split(' ', $vars{'subpackages'})) {
      push @{$ret->{'subpacks'}}, /^(.*?):/ ? $1 : $_;
    }
  }

  # convert name~ver to name=~ver
  s/^([a-zA-Z0-9\._+-]+)~/$1=~/ for @{$ret->{'deps'}};

  my @assets = get_assets(\%vars);
  push @{$ret->{'remoteassets'}}, @assets if @assets;

  return $ret;
}

my %pkginfo_array = (
  'depend' => 1,
  'replaces' => 1,
  'provides' => 1,
);

sub queryvars {
  my ($handle, $withhdrmd5) = @_;
  my $tar = Archive::Tar->new;
  my @read = $tar->read($handle, 1, {'filter' => '^\.PKGINFO$', 'limit' => 1});
  die("$handle: not an apk package file\n") unless @read == 1;
  my $pkginfo = $read[0]->get_content;
  die("$handle: not an apk package file\n") unless defined $pkginfo;
  my @lines = split("\n", $pkginfo);
  my %q;
  while (@lines) {
    my $l = shift @lines;
    next if $l eq '' || substr($l, 0, 1) eq '#';
    next unless $l =~ /^(.+?) = (.*)$/;
    if ($pkginfo_array{$1}) {
      push @{$q{$1}}, $2;
    } else {
      $q{$1} = $2;
    }
  }
  $q{'hdrmd5'} = Digest::MD5::md5_hex($pkginfo) if $withhdrmd5;
  $q{'install_if'} = [ split(' ', $q{'install_if'}) ] if $q{'install_if'};
  return \%q;
}

my %pkginfomap = (
  'pkgname' => 'name',
  'pkgver' => 'version',
  'pkgdesc' => 'summary',
  'url' => 'url',
  'builddate' => 'buildtime',
  'arch' => 'arch',
  'license' => 'license',
  'origin' => 'source',
  'depend' => 'requires',
#  'replaces' => 'obsoletes',
  'provides' => 'provides',
  'datahash' => 'apkdatachksum',
  'hdrmd5' => 'hdrmd5',
);

sub is_apkv3 {
  my ($file) = @_;
  my $fd;
  open($fd, '<', $file) || die("$file: $!\n");
  my $first;
  read($fd, $first, 3);
  close $fd;
  return $first && substr($first, 0, 3) eq 'ADB' ? 1 : 0;
}

sub query {
  my ($handle, %opts) = @_;
  my $qq;
  if (is_apkv3($handle)) {
    require Build::Apkv3 unless defined &Build::Apkv3::querypkginfo;
    $qq = Build::Apkv3::querypkginfo($handle, 1, $opts{'verifyapkchksum'}, $opts{'verifyapkdatasection'});
  } else {
    die("$handle: calculated checksum does not match $opts{'verifyapkchksum'}\n") if $opts{'verifyapkchksum'} && !verifyapkchksum($handle, $opts{'verifyapkchksum'});
    $qq = queryvars($handle, 1);
  }
  my %q;
  for (keys %$qq) {
    my $m = $pkginfomap{$_};
    $q{$m} = $qq->{$_} if $m;
  }
  my @conflicts = grep {/^\!/} @{$q{'requires'} || []};
  if (@conflicts) {
    substr($_, 0, 1, '') for @conflicts;
    $q{'conflicts'} = \@conflicts;
    $q{'requires'} = [ grep {!/^\!/} @{$q{'requires'} || []} ];
    delete $q{'requires'} unless @{$q{'requires'}};
  }
  if ($q{'name'} && $opts{'addselfprovides'}) {
    my $selfprovides = $q{'name'};
    $selfprovides .= "=$q{'version'}" if defined $q{'version'};
    push @{$q{'provides'}}, $selfprovides unless @{$q{'provides'} || []} && $q{'provides'}->[-1] eq $selfprovides;
  }
  if ($opts{'normalizedeps'}) {
    s/^([a-zA-Z0-9\._+-]+)~/$1=~/ for @{$q{'requires'} || []}, @{$q{'conflicts'} || []}, @{$qq->{'install_if'} || []};
  }
  $q{'version'} = 0 unless defined $q{'version'};
  $q{'release'} = $1 if $q{'version'} =~ s/-([^-]*)$//;
  $q{'source'} ||= $q{'name'} if defined $q{'name'};
  $q{'supplements'} = [ join(' & ', @{$qq->{'install_if'}}) ] if $opts{'weakdeps'} && $qq->{'install_if'};
  delete $q{'buildtime'} unless $opts{'buildtime'};
  die("$handle: calculated data checksum does not match $q{'apkdatachksum'}\n") if $opts{'verifyapkdatasection'} && $q{'apkdatachksum'} && !verifyapkdatachksum($handle, 'X2'.$q{'apkdatachksum'});
  delete $q{'apkdatachksum'} unless $opts{'apkdatachksum'};
  return \%q;
}

my %idxinfomap = (
  'P' => 'name',
  'V' => 'version',
  'T' => 'summary',
  'U' => 'url',
  't' => 'buildtime',
  'A' => 'arch',
  'L' => 'license',
  'C' => 'apkchksum',
  'o' => 'source',
  'D' => [ 'requires' ],
#  'r' => [ 'obsoletes' ],
  'p' => [ 'provides' ],
  'i' => [ 'install_if' ],
);

sub parseidx {
  my $cb = $_[1];
  for my $pkgidx ($_[0]) {
    my %q;
    while ($pkgidx ne '') {
      my $i = index($pkgidx, "\n");
      last unless $i >= 0;
      my $l = substr($pkgidx, 0, $i, '');
      substr($pkgidx, 0, 1, '');
      if ($l =~ /^(.):(.*)$/) {
	my $m = $idxinfomap{$1};
	if (ref($m)) {
	  $q{$m->[0]} = [ split(' ', $2) ];
	} elsif ($m) {
	  $q{$m} = $2;
	}
      }
      if ($l eq '' || $pkgidx eq '') {
        my @conflicts = grep {/^\!/} @{$q{'requires'} || []};
	if (@conflicts) {
	  substr($_, 0, 1, '') for @conflicts;
	  $q{'conflicts'} = \@conflicts;
	  $q{'requires'} = [ grep {!/^\!/} @{$q{'requires'} || []} ];
	}
	$cb->({ %q }) if $q{'name'} && defined $q{'version'};
	%q = ();
      }
    }
  }
}

sub addinstalledpkg {
  my ($data, $installed, $opts) = @_;
  my %q;
  for (qw{name arch buildtime version}) {
    $q{$_} = $data->{$_} if defined $data->{$_};
  }
  $q{'release'} = $1 if $q{'version'} =~ s/-([^-]*)$//s;
  push @$installed, \%q;
}

sub queryinstalled {
  my ($root, %opts) = @_;
  $root = '' if !defined($root) || $root eq '/';
  my @installed;
  my $fd;
  if (open($fd, '<', "$root/lib/apk/db/installed")) {
    local $/ = undef;     # Perl slurp mode
    my $idx = <$fd>;
    close $fd;
    parseidx($idx, sub {addinstalledpkg($_[0], \@installed, \%opts)});
  }
  return \@installed;
}

sub queryhdrmd5 {
  my ($handle) = @_; 
  if (is_apkv3($handle)) {
    require Build::Apkv3 unless defined &Build::Apkv3::calcapkchksum;
    return Build::Apkv3::calcapkchksum($handle, 'md5', 'ctrl');
  }
  my $tar = Archive::Tar->new;
  my @read = $tar->read($handle, 1, {'filter' => '^\.PKGINFO$', 'limit' => 1});
  die("$handle: not an apk package file\n") unless @read == 1;
  my $pkginfo = $read[0]->get_content;
  die("$handle: not an apk package file\n") unless defined $pkginfo;
  return Digest::MD5::md5_hex($pkginfo);
}

# this calculates the checksum of a compressed section.
sub calcapkchksum {
  my ($handle, $type, $section, $toeof) = @_; 
  if (is_apkv3($handle)) {
    require Build::Apkv3 unless defined &Build::Apkv3::querypkginfo;
    return Build::Apkv3::calcapkchksum(@_);
  }
  $section ||= 'ctrl';
  $type ||= 'Q1';
  die("unsupported apkchksum type $type\n") unless $type eq 'Q1' || $type eq 'Q2' || $type eq 'sha1' || $type eq 'sha256' || $type eq 'sha512' || $type eq 'md5' || $type eq 'raw' || $type eq 'X1' || $type eq 'X2';
  die("unsupported apkchksum section $section\n") unless $section eq 'sig' || $section eq 'ctrl' || $section eq 'data';
  $section = $section eq 'sig' ? 0 : $section eq 'ctrl' ? 1 : 2;
  my $fd;
  open($fd, '<', $handle) or die("$handle: $!\n");
  require Digest::SHA;
  my $ctx;
  $ctx = Digest::SHA->new(1) if $type eq 'Q1' || $type eq 'X1' || $type eq 'sha1';
  $ctx = Digest::SHA->new(256) if $type eq 'Q2' || $type eq 'X2' || $type eq 'sha256';
  $ctx = Digest::SHA->new(512) if $type eq 'sha512';
  $ctx = Digest::MD5->new() if $type eq 'md5';
  $ctx = '' if $type eq 'raw';
  die("unsupported apkchksum type $type\n") unless defined $ctx;
  my $z = new Compress::Raw::Zlib::Inflate(-WindowBits => 15 + Compress::Raw::Zlib::WANT_GZIP_OR_ZLIB(), LimitOutput => 1);
  my $sec = 0;
  my $input = '';
  while (1) {
    if (!length($input)) {
      read($fd, $input, 4096);
      die("unexpected EOF\n") unless length($input);
    }
    my $oldinput = $input;
    my $output;
    my $status = $z->inflate($input, $output);
    while ($status == Compress::Raw::Zlib::Z_BUF_ERROR() && length($output)) {
      undef $output;
      $status = $z->inflate($input, $output);
    }
    if ($type eq 'raw') {
      $ctx .= substr($oldinput, 0, length($oldinput) - length($input)) if $sec == $section;
    } else {
      $ctx->add(substr($oldinput, 0, length($oldinput) - length($input))) if $sec == $section;
    }
    next if $status == Compress::Raw::Zlib::Z_BUF_ERROR();
    if ($status == Compress::Raw::Zlib::Z_STREAM_END()) {
      $sec++;
      last if $sec > $section || ($sec == $section && $toeof);
      $z->inflateReset();
    } elsif ($status != Compress::Raw::Zlib::Z_OK()) {
      die("decompression error\n");
    }
  }
  if ($toeof) {
    $ctx->add($input);
    $ctx->addfile($fd);
  }
  return $ctx if $type eq 'raw';
  return $type.$ctx->b64digest().($type eq 'Q1' ? '=' : '') if $type eq 'Q1' || $type eq 'Q2';
  return $type.$ctx->hexdigest() if $type eq 'X1' || $type eq 'X2';
  return $ctx->hexdigest();
}

sub trunc_apkchksum {
  my ($chk) = @_;
  return 'X1'.substr($chk, 2, 40) if $chk =~ /^X2/;
  if ($chk =~ /^Q2/) {
    substr($chk, 28, 1) =~ tr!BCDFGHJKLNOPRSTVWXZabdefhijlmnpqrtuvxyz1235679+/!AAAEEEIIIMMMQQQUUUYYYcccgggkkkooossswww000444888!;
    return 'Q1'.substr($chk, 2, 27).'=';
  }
  die("trunc_chksum: don't know how to truncate $chk\n");
}

sub verifyapkchksum {
  my ($handle, $chksum) = @_; 
  die("unsupported apk checksum $chksum\n") unless $chksum =~ /^([QX][12])/;
  return 1 if calcapkchksum($handle, $1) eq $chksum;
   # also check for a truncated sha256 sum
  return 1 if $chksum =~ /^([QX])1/ && trunc_apkchksum(calcapkchksum($handle, "${1}2")) eq $chksum;
  return 0;
}

sub verifyapkdatachksum {
  my ($handle, $chksum) = @_; 
  die("unsupported apk data checksum $chksum\n") unless $chksum =~ /^([QX][12])/;
  return 1 if calcapkchksum($handle, $1, 'data', 1) eq $chksum;
  return 0;
}

# return the to-be-signed data of a package
sub gettbsdata {
  my ($handle) = @_;
  return calcapkchksum($handle, 'raw');
}

sub mktar {
  my ($fn, $type, $time, $data) = @_;
  if (length($fn) > 100) {
    my $pe = "path=$fn";
    my $paxdata;
    my $l = length($pe) + 3;
    $l++ while length($paxdata = sprintf("%d %s\n", $l, $pe)) > $l;
    my $ph = mktar(substr("./PaxHeaders/$fn", 0, 100), 'x', $time, $paxdata);
    return $ph . mktar(substr($fn, 0, 100), $type, $time, $data);
  }
  die("oversized tar file name\n") if length($fn) > 100;
  my $size = length($data);
  my $sizestr = sprintf("%011o", $size);
  my $timestr = sprintf("%011o", $time);
  my $h = "\0\0\0\0\0\0\0\0" x 64;
  substr($h, 0, length($fn), $fn);
  substr($h, 100, 7, '0000644');
  substr($h, 108, 15, "0000000\0000000000");	# uid/gid
  substr($h, 124, length($sizestr), $sizestr);
  substr($h, 136, length($timestr), $timestr);
  substr($h, 148, 8, '        ');
  substr($h, 156, 1, $type);
  substr($h, 257, 8, "ustar\00000");
  substr($h, 148, 7, sprintf("%06o\0", unpack("%16C*", $h)));
  return $h . $data . ($size % 512 ? "\0" x (512 - $size % 512) : '');
}

sub getsignatures_cb {
  my ($sigs, $entry) = @_;
  die("end of sigs reached\n") unless $entry->is_file;
  my $name = $entry->name;
  die("end of sigs reached\n") unless $name =~ /^\.SIGN\./;
  my $content = $entry->data;
  return 1 unless $content;
  push @$sigs, { 'signature' => $content, 'algo' => 'rsa', 'hash' => 'sha1', 'keyname' => $1 } if $name =~ /^\.SIGN\.RSA\.(.+)$/;
  push @$sigs, { 'signature' => $content, 'algo' => 'rsa', 'hash' => 'sha256', 'keyname' => $1 } if $name =~ /^\.SIGN\.RSA256\.(.+)$/;
  push @$sigs, { 'signature' => $content, 'algo' => 'rsa', 'hash' => 'sha512', 'keyname' => $1 } if $name =~ /^\.SIGN\.RSA512\.(.+)$/;
  return 1;
}

sub getsignatures {
  my ($handle) = @_;
  if (is_apkv3($handle)) {
    die("getsignatures: apkv3 support is not implemented\n");
  }
  my $tar = Archive::Tar->new;
  my @sigs;
  eval { $tar->read($handle, 1, { 'filter_cb' => sub {getsignatures_cb(\@sigs, @_)} }) };
  return @sigs;
}

sub replacesignature {
  my ($handle, $ohandle, $signature, $time, $algo, $hash, $keyname, $keyid) = @_;
  if (is_apkv3($handle)) {
    die("replacesignature: apkv3 support is not implemented\n");
  }
  my $sigtype;
  $sigtype = 'RSA' if $algo eq 'rsa' && $hash eq 'sha1';
  $sigtype = 'RSA256' if $algo eq 'rsa' && $hash eq 'sha256';
  $sigtype = 'RSA512' if $algo eq 'rsa' && $hash eq 'sha512';
  die("replacesignature: unsupported algo/hash combination: $algo/$hash\n") unless $sigtype;
  # create dummy tar entry
  my $te = mktar(".SIGN.$sigtype.$keyname", '0', $time, $signature);
  # compress
  require Compress::Zlib;
  $te = Compress::Zlib::memGzip($te);
  # get size of old signature
  my $oldsigsize = length(calcapkchksum($handle, 'raw', 'sig'));
  my $h;
  open($h, '<', $handle) || die("$handle: $!\n");
  sysseek($h, $oldsigsize, 0) || die("seek failed\n");
  my $oh;
  open($oh, '>', $ohandle) || die("$ohandle: $!\n");
  print $oh $te or die("write: $!\n");
  my $buf;
  print $oh $buf or die("write: $!\n") while sysread($h, $buf, 65536) > 0;
  close($oh) || die("close: $!\n");
  close($h);
}

my %verscmp_class = ( '.' => 1, 'X' => 2, '_' => 3, '~' => 4, '-' => 5, '$' => 6, '!' => 7 );
my %verscmp_suf = ( 'alpha' => 1, 'beta' => 2, 'pre' => 3, 'rc' => 4, 'cvs' => 5, 'svn' => 6, 'git' => 7, 'hg' => 8, 'p' => 9 );

sub verscmp {
  my ($s1, $s2) = @_;
  my $fuzzy1 = $s1 =~ s/^~// ? 1 : 0;
  my $fuzzy2 = $s2 =~ s/^~// ? 1 : 0;
  return 0 if $s1 eq $s2;
  $s1 = ".$s1";
  $s2 = ".$s2";
  my ($c1, $c2, $p1, $p2);
  my $initial = 1;
  while (1) {
    return 0 if $s1 eq $s2;
    $p1 = $s1 =~ s/^(\.[0-9]+|[a-z]|_[a-z]+[0-9]*|~[0-9a-f]+|-r[0-9]+|$)// ? $1 : '!!';
    $p2 = $s2 =~ s/^(\.[0-9]+|[a-z]|_[a-z]+[0-9]*|~[0-9a-f]+|-r[0-9]+|$)// ? $1 : '!!';
    $c1 = (length($p1) != 1 ? substr($p1, 0, 1, '') : 'X') || '$';
    $c2 = (length($p2) != 1 ? substr($p2, 0, 1, '') : 'X') || '$';
    if ($c1 ne $c2 || $c1 eq '!' || $c1 eq '$') {
      return 0 if $c1 eq $c2;	# both '!' or both '$'
      return 0 if ($fuzzy1 && $c1 eq '$') || ($fuzzy2 && $c2 eq '$');
      # different segment class
      return -1 if $c1 eq '_' && $p1 =~ /^(?:alpha|beta|pre|rc)(?:[0-9]|$)/;
      return 1 if $c2 eq '_' && $p2 =~ /^(?:alpha|beta|pre|rc)(?:[0-9]|$)/;
      return $verscmp_class{$c2} <=> $verscmp_class{$c1};
    }
    $initial = 0;
    next if $p1 eq $p2;
    my $r;
    if ($c1 eq '.' && ($initial || (substr($p1, 0, 1) ne '0' && substr($p2, 0, 1) ne '0'))) {
      $r = $p1 <=> $p2;
    } elsif ($c1 eq '_') {
      $p1 =~ s/^([a-z]+)//;
      my $st1 = $1;
      $p2 =~ s/^([a-z]+)//;
      my $st2 = $1;
      return ($verscmp_suf{$st1} || 99) <=> ($verscmp_suf{$st2} || 99) || $st1 cmp $st2 if $st1 ne $st2;
      $r = ($p1 || 0) <=> ($p2 || 0);
    } elsif ($c1 eq '-') {
      $r = substr($p1, 1) <=> substr($p2, 1);
    } else {
      $r = $p1 cmp $p2;
    }
    return $r if $r;
  }
}

1;
