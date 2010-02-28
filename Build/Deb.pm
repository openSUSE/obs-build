package Build::Deb;

use strict;
use Digest::MD5;

my $have_zlib;
eval {
  require Compress::Zlib;
  $have_zlib = 1;
};

sub parse {
  my ($bconf, $fn) = @_;
  my $ret;
  my @control;

  # get arch and os from macros
  my ($arch, $os);
  for (@{$bconf->{'macros'} || []}) {
    $arch = $1 if /^%define _target_cpu (\S+)/;
    $os = $1 if /^%define _target_os (\S+)/;
  }
  # map to debian names
  $os = 'linux' if !defined($os);
  $arch = 'all' if !defined($arch) || $arch eq 'noarch';
  $arch = 'i386' if $arch =~ /^i[456]86$/;
  $arch = 'powerpc' if $arch eq 'ppc';
  $arch = 'amd64' if $arch eq 'x86_64';

  if (ref($fn) eq 'ARRAY') {
    @control = @$fn;
  } else {
    local *F;
    if (!open(F, '<', $fn)) {
      $ret->{'error'} = "$fn: $!";
      return $ret;
    }
    @control = <F>;
    close F;
    chomp @control;
  }
  splice(@control, 0, 3) if @control > 3 && $control[0] =~ /^-----BEGIN/;
  my $name;
  my $version;
  my @deps;
  while (@control) {
    my $c = shift @control;
    last if $c eq '';   # new paragraph
    my ($tag, $data) = split(':', $c, 2);
    next unless defined $data;
    $tag = uc($tag);
    while (@control && $control[0] =~ /^\s/) {
      $data .= "\n".substr(shift @control, 1);
    }
    $data =~ s/^\s+//s;
    $data =~ s/\s+$//s;
    if ($tag eq 'VERSION') {
      $version = $data;
      $version =~ s/-[^-]+$//;
    } elsif ($tag eq 'SOURCE') {
      $name = $data;
    } elsif ($tag eq 'BUILD-DEPENDS' || $tag eq 'BUILD-CONFLICTS' || $tag eq 'BUILD-IGNORE' || $tag eq 'BUILD-DEPENDS-INDEP') {
      my @d = split(/,\s*/, $data);
      for my $d (@d) {
        my @alts = split('\s*\|\s*', $d);
        my @needed;
        for my $c (@alts) {
          if ($c =~ /^(.*?)\s*\[(.*)\]$/) {
            $c = $1;
            my $isneg = 0;
            my $bad;
            for my $q (split('[\s,]', $2)) {
              $isneg = 1 if $q =~ s/^\!//;
              $bad = 1 if !defined($bad) && !$isneg;
              if ($isneg) {
                if ($q eq $arch || $q eq "$os-$arch") {
                  $bad = 1;
                  last;
                }
              } elsif ($q eq $arch || $q eq "$os-$arch") {
                $bad = 0;
              }
            }
            push @needed, $c unless $bad;
          } else {
            push @needed, $c;
          }
        }
        next unless @needed;
        $d = join(' | ', @needed);
	$d =~ s/ \(([^\)]*)\)/ $1/g;
	$d =~ s/>>/>/g;
	$d =~ s/<</</g;
	if ($tag eq 'BUILD-DEPENDS' || $tag eq 'BUILD-DEPENDS-INDEP') {
	  push @deps, $d;
	} else {
	  push @deps, "-$d";
	}
      }
    }
  }
  $ret->{'name'} = $name;
  $ret->{'version'} = $version;
  $ret->{'deps'} = \@deps;
  return $ret;
}

sub ungzip {
  my $data = shift;
  local (*TMP, *TMP2);
  open(TMP, "+>", undef) or die("could not open tmpfile\n");
  syswrite TMP, $data;
  sysseek(TMP, 0, 0);
  my $pid = open(TMP2, "-|");
  die("fork: $!\n") unless defined $pid;
  if (!$pid) {
    open(STDIN, "<&TMP");
    exec 'gunzip';
    die("gunzip: $!\n");
  }
  close(TMP);
  $data = '';
  1 while sysread(TMP2, $data, 1024, length($data)) > 0;
  close(TMP2) || die("gunzip error");
  return $data;
}

sub debq {
  my ($fn) = @_;

  local *DEBF;
  if (ref($fn) eq 'GLOB') {
      *DEBF = *$fn;
  } elsif (!open(DEBF, '<', $fn)) {
    warn("$fn: $!\n");
    return ();
  }
  my $data = '';
  sysread(DEBF, $data, 4096);
  if (length($data) < 8+60) {
    warn("$fn: not a debian package\n");
    close DEBF unless ref $fn;
    return ();
  }
  if (substr($data, 0, 8+16) ne "!<arch>\ndebian-binary   ") {
    close DEBF unless ref $fn;
    return ();
  }
  my $len = substr($data, 8+48, 10);
  $len += $len & 1;
  if (length($data) < 8+60+$len+60) {
    my $r = 8+60+$len+60 - length($data);
    $r -= length($data);
    if ((sysread(DEBF, $data, $r < 4096 ? 4096 : $r, length($data)) || 0) < $r) {
      warn("$fn: unexpected EOF\n");
      close DEBF unless ref $fn;
      return ();
    }
  }
  $data = substr($data, 8 + 60 + $len);
  if (substr($data, 0, 16) ne 'control.tar.gz  ') {
    warn("$fn: control.tar.gz is not second ar entry\n");
    close DEBF unless ref $fn;
    return ();
  }
  $len = substr($data, 48, 10);
  if (length($data) < 60+$len) {
    my $r = 60+$len - length($data);
    if ((sysread(DEBF, $data, $r, length($data)) || 0) < $r) {
      warn("$fn: unexpected EOF\n");
      close DEBF unless ref $fn;
      return ();
    }
  }
  close DEBF unless ref($fn);
  $data = substr($data, 60, $len);
  my $controlmd5 = Digest::MD5::md5_hex($data);	# our header signature
  if ($have_zlib) {
    $data = Compress::Zlib::memGunzip($data);
  } else {
    $data = ungzip($data);
  }
  if (!$data) {
    warn("$fn: corrupt control.tar.gz file\n");
    return ();
  }
  my $control;
  while (length($data) >= 512) {
    my $n = substr($data, 0, 100);
    $n =~ s/\0.*//s;
    my $len = oct('00'.substr($data, 124,12));
    my $blen = ($len + 1023) & ~511;
    if (length($data) < $blen) {
      warn("$fn: corrupt control.tar.gz file\n");
      return ();
    }
    if ($n eq './control') {
      $control = substr($data, 512, $len);
      last;
    }
    $data = substr($data, $blen);
  }
  my %res;
  my @control = split("\n", $control);
  while (@control) {
    my $c = shift @control;
    last if $c eq '';   # new paragraph
    my ($tag, $data) = split(':', $c, 2);
    next unless defined $data;
    $tag = uc($tag);
    while (@control && $control[0] =~ /^\s/) {
      $data .= "\n".substr(shift @control, 1);
    }
    $data =~ s/^\s+//s;
    $data =~ s/\s+$//s;
    $res{$tag} = $data;
  }
  $res{'CONTROL_MD5'} = $controlmd5;
  return %res;
}

sub query {
  my ($handle, %opts) = @_;

  my %res = debq($handle);
  return undef unless %res;
  my $name = $res{'PACKAGE'};
  my $src = $name;
  if ($res{'SOURCE'}) {
    $src = $res{'SOURCE'};
    $src =~ s/\s.*$//;
  }
  my @provides = split(',\s*', $res{'PROVIDES'} || '');
  push @provides, "$name = $res{'VERSION'}";
  my @depends = split(',\s*', $res{'DEPENDS'} || '');
  my @predepends = split(',\s*', $res{'PRE-DEPENDS'} || '');
  push @depends, @predepends;
  s/ \(([^\)]*)\)/ $1/g for @provides;
  s/ \(([^\)]*)\)/ $1/g for @depends;
  s/>>/>/g for @provides;
  s/<</</g for @provides;
  s/>>/>/g for @depends;
  s/<</</g for @depends;
  my $data = {
    name => $name,
    hdrmd5 => $res{'CONTROL_MD5'},
    provides => \@provides,
    requires => \@depends,
  };
  $data->{'source'} = $src if $src ne '';
  if ($opts{'evra'}) {
    $res{'VERSION'} =~ /^(?:(\d+):)?(.*?)(?:-([^-]*))?$/s;
    $data->{'epoch'} = $1 if defined $1;
    $data->{'version'} = $2;
    $data->{'release'} = $3 if defined $3;
    $data->{'arch'} = $res{'ARCHITECTURE'};
  }
  if ($opts{'description'}) {
    $data->{'description'} = $res{'DESCRIPTION'};
  }
  return $data;
}

sub queryhdrmd5 {
  my ($bin) = @_;

  local *F;
  open(F, '<', $bin) || die("$bin: $!\n");
  my $data = '';
  sysread(F, $data, 4096);
  if (length($data) < 8+60) {
    warn("$bin: not a debian package\n");
    close F;
    return undef;
  }
  if (substr($data, 0, 8+16) ne "!<arch>\ndebian-binary   ") {
    warn("$bin: not a debian package\n");
    close F;
    return undef;
  }
  my $len = substr($data, 8+48, 10);
  $len += $len & 1;
  if (length($data) < 8+60+$len+60) {
    my $r = 8+60+$len+60 - length($data);
    $r -= length($data);
    if ((sysread(F, $data, $r < 4096 ? 4096 : $r, length($data)) || 0) < $r) {
      warn("$bin: unexpected EOF\n");
      close F;
      return undef;
    }
  }
  $data = substr($data, 8 + 60 + $len);
  if (substr($data, 0, 16) ne 'control.tar.gz  ') {
    warn("$bin: control.tar.gz is not second ar entry\n");
    close F;
    return undef;
  }
  $len = substr($data, 48, 10);
  if (length($data) < 60+$len) {
    my $r = 60+$len - length($data);
    if ((sysread(F, $data, $r, length($data)) || 0) < $r) {
      warn("$bin: unexpected EOF\n");
      close F;
      return undef;
    }
  }
  close F;
  $data = substr($data, 60, $len);
  return Digest::MD5::md5_hex($data);
}

sub verscmp_part {
  my ($s1, $s2) = @_;
  return 0 if $s1 eq $s2;
  $s1 =~ s/([0-9]+)/substr("00000000000000000000000000000000$1", -32, 32)/ge;
  $s2 =~ s/([0-9]+)/substr("00000000000000000000000000000000$1", -32, 32)/ge;
  $s1 .= "\0";
  $s2 .= "\0";
  $s1 =~ tr[\176\000-\037\060-\071\101-\132\141-\172\040-\057\072-\100\133-\140\173-\175][\000-\176];
  $s2 =~ tr[\176\000-\037\060-\071\101-\132\141-\172\040-\057\072-\100\133-\140\173-\175][\000-\176];
  return $s1 cmp $s2;
}

sub verscmp {
  my ($s1, $s2) = @_;
  my ($e1, $v1, $r1) = $s1 =~ /^(?:(\d+):)?(.*?)(?:-([^-]*))?$/s;
  $e1 = 0 unless defined $e1;
  my ($e2, $v2, $r2) = $s2 =~ /^(?:(\d+):)?(.*?)(?:-([^-]*))?$/s;
  $e2 = 0 unless defined $e2;
  if ($e1 ne $e2) {
    my $r = verscmp_part($e1, $e2);
    return $r if $r;
  }
  my $r = verscmp_part($v1, $v2);
  return $r if $r;
  $r1 = '' unless defined $r1;
  $r2 = '' unless defined $r2;
  return verscmp_part($r1, $r2);
}

1;
