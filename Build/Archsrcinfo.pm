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

package Build::Archsrcinfo;

use strict;
use warnings;

sub _get_srcinfo_assets {
    my ($vars, $asuf) = @_;

    my @sources = @{ $vars->{"source$asuf"} || [] };
    return () unless @sources;

    my @digests;
    for my $digest_type ('sha512', 'sha384', 'sha256', 'sha224', 'sha1', 'md5') {
        my $sums_key = "${digest_type}sums$asuf";
        if (exists $vars->{$sums_key} && @{$vars->{$sums_key}}) {
            @digests = map { $_ eq 'SKIP' ? $_ : "$digest_type:$_" } @{ $vars->{$sums_key} };
            last;
        }
    }

    my @assets;
    for my $i (0 .. $#sources) {
        my $source_entry = $sources[$i];

        # parse filename::URL formats
        my $url = $source_entry;
        if ($source_entry =~ /::/) {
            ($url) = (split /::/, $source_entry, 2)[1];
        }

        # parse http/https/ftp protocols only
        next unless $url =~ /^(https?|ftp):\/\//;

        my $asset = { 'url' => $url };
        my $digest = $digests[$i];

        if ($digest && $digest ne 'SKIP') {
            $asset->{'digest'} = $digest;
        }

        push @assets, $asset;
    }

    return @assets;
}

sub parse {
    my ($config, $srcinfo_file) = @_;

    my $ret = {};
    my $fh;
    unless (open($fh, '<', $srcinfo_file)) {
        $ret->{'error'} = "$srcinfo_file: $!";
        return $ret;
    }

    my %vars;
    while (my $line = <$fh>) {
        chomp $line;
        # newline / comment
        next if $line =~ /^\s*(#.*)?$/;

        if ($line =~ /^\s*([^=\s]+)\s*=\s*(.*)\s*$/) {
            my ($key, $value) = ($1, $2);
            push @{ $vars{$key} }, $value;
        }
    }
    close $fh;

    $ret->{'name'} = $vars{'pkgname'}->[0] if exists $vars{'pkgname'};
    if (exists $vars{'pkgver'} && exists $vars{'pkgrel'}) {
      $ret->{'version'} = $vars{'pkgver'}->[0] . '-' . $vars{'pkgrel'}->[0];
    } elsif (exists $vars{'pkgver'}) {
      $ret->{'version'} = $vars{'pkgver'}->[0];
    }

    $ret->{'deps'} = [];
    my @dep_types = qw(depends makedepends checkdepends);
    foreach my $dep_type (@dep_types) {
        push @{ $ret->{'deps'} }, @{ $vars{$dep_type} || [] };
    }

    # i*86
    my ($arch) = Build::gettargetarchos($config);
    $arch = 'i686' if $arch =~ /^i[345]86$/;
    foreach my $dep_type (@dep_types) {
        my $arch_dep_key = "${dep_type}_$arch";
        push @{ $ret->{'deps'} }, @{ $vars{$arch_dep_key} || [] };
    }

    # extract remote assets
    $ret->{'remoteassets'} = [];
    for my $asuf ('', "_$arch") {
        my @assets = _get_srcinfo_assets(\%vars, $asuf);
        push @{ $ret->{'remoteassets'} }, @assets if @assets;
    }

    if (exists $vars{'arch'} && !grep { $_ eq 'any' } @{ $vars{'arch'} }) {
        my %supported_arches = map { $_ => 1 } @{ $vars{'arch'} };

        if (exists $supported_arches{'i686'}) {
            $supported_arches{'i386'} = $supported_arches{'i486'} = $supported_arches{'i586'} = 1;
        }

        $ret->{'exclarch'} = [ sort keys %supported_arches ];
    }

    return $ret;
}


1;
