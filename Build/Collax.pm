#
# Copyright 2015  Zarafa B.V. and its licensors
#
# This program is free software; you can redistribute it and/or modify it under
# the terms of the GNU General Public License as published by the Free Software
# Foundation; either version 2 or (at your option) any later version.
#
# This program is distributed in the hope that it will be useful, but WITHOUT
# ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS
# FOR A PARTICULAR PURPOSE. See the GNU General Public License for more
# details.
#
package Build::Collax;
use strict;
use warnings;
use parent "Build::Deb";

sub parse
{
	my($buildconf, $fn) = @_;
	my @bscript;

	if (ref($fn) eq "ARRAY") {
		@bscript = @$fn;
		$fn = undef;
	} elsif (ref($fn) ne "") {
		die "Unhandled ref type in collax";
	} else {
		local *FH;
		if (!open(FH, "<", $fn)) {
			return {"error" => "$fn: $!"};
		}
		@bscript = <FH>;
		chomp(@bscript);
		close(FH);
	}

	my $ret = {"deps" => []};
	for (my $i = 0; $i <= $#bscript; ++$i) {
		next unless $bscript[$i] =~ m{^\w+=};
		my $key = lc(substr($&, 0, -1));
		my $value = $';
		if ($value =~ m{^([\'\"])}) {
			$value = substr($value, 1);
			while ($value !~ m{[\'\"]}) {
				my @cut = splice(@bscript, $i + 1, 1);
				$value .= $cut[0];
			}
			$value =~ s{[\'\"]}{}s;
			$value =~ s{\n}{ }gs;
		}
		if ($key eq "name" || $key eq "version") {
			$ret->{$key} = $value;
		} elsif ($key eq "builddepends" || $key eq "extradepends") {
			$value =~ s{^\s+}{}gs;
			$value =~ s{\s+$}{}gs;
			$value =~ s{,}{ }gs;
			push(@{$ret->{"deps"}}, split(/\s+/, $value));
		}
	}
	return $ret;
}
