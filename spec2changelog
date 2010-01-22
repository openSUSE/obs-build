#!/usr/bin/perl
#
# Tiny perl script that parses a .spec file (STDIN), extracts
# its %changelog entries and prints (STDOUT) them in the
# format of a .changes file, ordered.
#
# Usage: cat foo.spec | spec2changes.pl > foo.changes
#
# Copyright 2009 by Pascal Bleser <pascal.bleser@opensuse.org>
# This script is licensed under the GNU General Public License version 2
# http://www.gnu.org/licenses/gpl-2.0.html
#

use warnings;
use strict;
use Date::Language;
use POSIX qw(strftime setlocale LC_ALL);

# make sure date printed in correct locale
$ENV{'TZ'} = 'UTC';
setlocale(LC_ALL, 'C');

my $sep = "-" x 67;
my @days   = qw{Mon Tue Wed Thu Fri Sat Sun};
my @months = qw{Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec};

#----------------------------------------------------------------------
#
my %dh = map { $_ => 1 } @days;
my %mh = map { $_ => 1 } @months;

my $date_parser = Date::Language->new('English');

my %items = ();
my $current_block = undef;
my $time = undef;
while (<>) {
    if (/^%changelog/ .. eof()) {
        next if /^%/;
        next if /^\s*#/;

        chomp;
        s/\s+$//;

        if (/^\*\s+(([A-Z][a-z]{2})\s+([A-Z][a-z]{2})\s+\d{1,2}\s+\d{4})(\s+(.*)\s*)$/ and exists $dh{$2} and exists $mh{$3}) {
            $items{$time} = $current_block if defined $current_block and defined $time;
            $time = $date_parser->str2time($1);
            $current_block = [];
            $_ = $4;
        } elsif (/^\*/) {
            warn("not matching a headline: \"$_\"\n");
        }
        push(@$current_block, $_);
    }
}
$items{$time} = $current_block if defined $current_block and defined $time;

foreach my $time (sort { $b <=> $a } (keys(%items))) {
    print $sep, "\n";
    my $item = $items{$time};
    my $head = shift(@$item);
    $head =~ s/^\s+//;
    $head =~ s/^\-\s+//;
    if ($head =~ m/^(.+?)\s*<(.+?\@.+?\..+?)>(\s*.*)$/) {
        $head = $2;
    } elsif ($head =~ m/^<(.+?\@.+?\..+?)>(\s*.*)$/) {
        $head = $1;
    }
    if ($head =~ m/^\s*-\s*(.+)$/) {
        $head = $1;
    }

    print strftime("%a %b %e %H:%M:%S %Z %Y", localtime($time)), " - ", $head, "\n";
    my $first = shift(@$item);
    print "\n" unless defined($first) && ($first eq '');
    print $first, "\n";
    print join("\n", @$item), "\n" if @$item;
    print "\n";
}
