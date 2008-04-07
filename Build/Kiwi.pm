
package Build::Kiwi;

use strict;
use Digest::MD5;
#use Device::Cdio::ISO9660;
#use Device::Cdio::ISO9660::IFS;

my $have_zlib;
eval {
  require Compress::Zlib;
  $have_zlib = 1;
};

sub parse {
  my ($bconf, $fn) = @_;
  my $ret;
  my @control;

print "Build::Kiwi::parse IS NOT IMPLEMENTED ! \n";
die();

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
    } elsif ($tag eq 'BUILD-DEPENDS' || $tag eq 'BUILD-CONFLICTS' || $tag eq 'BUILD-IGNORE') {
      my @d = split(/,\s*/, $data);
      for my $d (@d) {
        if ($d =~ /^(.*?)\s*\[(.*)\]$/) {
	  $d = $1;
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
	  next if $bad;
	}
	$d =~ s/ \(([^\)]*)\)/ $1/g;
	$d =~ s/>>/>/g;
	$d =~ s/<</</g;
	if ($tag eq 'BUILD-DEPENDS') {
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

sub debq {
  my ($fn) = @_;

  print "Build::Kiwi::debq IS NOT IMPLEMENTED ! \n";
  die();

  return 1;
}

sub queryiso {
  my ($handle, %opts) = @_;

#  $iso = Device::Cdio::ISO9660::IFS->new(-source=>'copying.iso');
  my $src = '';
  my $data = {
    name => "DEFAULT_NAME",
#    hdrmd5 => Digest::MD5::md5_hex($handle); #FIXME create real checksum from iso
  };
#  $data->{'source'} = $src if $src ne '';
  if ($opts{'evra'}) {
#FIXME find out of iso:
    my $arch = "i586";
    $data->{'version'} = "0.1";
    $data->{'release'} = "1";
    $data->{'type'} = "iso";
    $data->{'arch'} = $arch;
  }
  if ($opts{'filelist'}) {
    print ("Build::KIWI query filelist not implemented !\n");
    die();
#    $data->{'filelist'} = $res{'FILENAMES'};
  }
  if ($opts{'description'}) {
    print ("Build::KIWI query description not implemented !\n");
    die();
#    $data->{'summary'} = $res{'SUMMARY'}->[0];
#    $data->{'description'} = $res{'DESCRIPTION'}->[0];
  }
  return $data;
}

sub queryhdrmd5 {
  my ($bin) = @_; 

  print "Build::Kiwi::queryhdrmd5 IS NOT IMPLEMENTED ! \n";
  die();

}

1;
