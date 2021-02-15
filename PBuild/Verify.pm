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

package PBuild::Verify;

use strict;

sub verify_simple {
  my $name = $_[0];
  die("illegal characters\n") if $name =~ /[^\-+=\.,0-9:%{}\@#%A-Z_a-z~\200-\377]/s;
}

sub verify_filename {
  my $filename = $_[0];
  die("filename is empty\n") unless defined($filename) && $filename ne '';
  die("filename '$filename' is illegal\n") if $filename =~ /[\/\000-\037]/;
  die("filename '$filename' is illegal\n") if $filename =~ /^\./;
}

sub verify_arch {
  my $arch = $_[0];
  die("arch is empty\n") unless defined($arch) && $arch ne '';
  die("arch '$arch' is illegal\n") if $arch =~ /[\/:\.\000-\037]/;
  die("arch '$arch' is illegal\n") unless $arch;
  die("arch '$arch' is too long\n") if length($arch) > 200;
  verify_simple($arch);
}

sub verify_packid {
  my $packid = $_[0];
  die("packid is empty\n") unless defined($packid) && $packid ne '';
  die("packid '$packid' is too long\n") if length($packid) > 200;
  if ($packid =~ /(?<!^_product)(?<!^_patchinfo):./) {
    # multibuild case: first part must be a vaild package, second part simple label
    die("packid '$packid' is illegal\n") unless $packid =~ /\A([^:]+):([^:]+)\z/s;
    my ($p1, $p2) = ($1, $2);
    die("packid '$packid' is illegal\n") if $p1 eq '_project' || $p1 eq '_pattern';
    verify_packid($p1);
    die("packid '$packid' is illegal\n") unless $p2 =~ /\A[^_\.\/:\000-\037][^\/:\000-\037]*\z/;
    return;
  }
  return if $packid =~ /\A(?:_product|_pattern|_project|_patchinfo)\z/;
  return if $packid =~ /\A(?:_product:|_patchinfo:)[^_\.\/:\000-\037][^\/:\000-\037]*\z/;
  die("packid '$packid' is illegal\n") if $packid =~ /[\/:\000-\037]/;
  die("packid '$packid' is illegal\n") if $packid =~ /^[_\.]/;
  die("packid '$packid' is illegal\n") unless $packid;
}

sub verify_digest {
  my $digest = $_[0];
  die("digest is empty\n") unless defined($digest) && $digest ne '';
  die("digest '$digest' is illegal\n") unless $digest =~ /^(?:[a-zA-Z0-9]+:)?[a-fA-F0-9]+$/s;
}

sub verify_nevraquery {
  my ($q) = @_;
  verify_arch($q->{'arch'});
  die("binary has no name\n") unless defined $q->{'name'};
  die("binary has no version\n") unless defined $q->{'version'};
  my $f = "$q->{'name'}-$q->{'version'}";
  $f .= "-$q->{'release'}" if defined $q->{'release'};
  verify_filename($f);
  verify_simple($f);
}

sub verify_multibuild {
  my ($mb) = @_;
  die("multibuild cannot have both package and flavor elements\n") if $mb->{'package'} && $mb->{'flavor'};
  for my $packid (@{$mb->{'package'} || []}) {
    verify_packid($packid);
    die("packid $packid is illegal in multibuild\n") if $packid =~ /:/;
  }
  for my $packid (@{$mb->{'flavor'} || []}) {
    verify_packid($packid);
    die("flavor $packid is illegal in multibuild\n") if $packid =~ /:/;
  }
}

1;
