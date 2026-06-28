#!/usr/bin/perl -w

use strict;
use Test::More tests => 6;

use Build;
use Build::Deb;

my $dsc = [
  'Format: 3.0 (quilt)',
  'Source: testpkg',
  'Build-Depends: debhelper-compat (= 13), always-dep, test-dep <!nocheck>, stage1-dep <stage1>, cross-dep <cross !nocheck>',
];

sub parsedeps {
  my ($profiles) = @_;
  my @conf;
  @conf = ('Macros:', "%deb_build_profiles $profiles", ':Macros') if defined $profiles;
  my $conf = Build::read_config('x86_64', [ @conf ]);
  my $d = Build::Deb::parse($conf, $dsc);
  return join(', ', @{$d->{'deps'} || []});
}

# no build profiles active: dependencies restricted to <!nocheck> are pulled
# in (nocheck is not active), <stage1> and <cross> ones are not
is(parsedeps(undef), 'debhelper-compat = 13, always-dep, test-dep', 'no build profiles');
is(parsedeps(''), 'debhelper-compat = 13, always-dep, test-dep', 'empty build profiles');

# nocheck active: the <!nocheck> dependency is dropped
is(parsedeps('nocheck'), 'debhelper-compat = 13, always-dep', 'nocheck profile');

# stage1 active: the <stage1> dependency is pulled in additionally
is(parsedeps('stage1'), 'debhelper-compat = 13, always-dep, test-dep, stage1-dep', 'stage1 profile');

# cross active: the <cross !nocheck> dependency is pulled in additionally
is(parsedeps('cross'), 'debhelper-compat = 13, always-dep, test-dep, cross-dep', 'cross profile');

# cross and nocheck active: cross-dep is dropped again because of !nocheck
is(parsedeps('cross nocheck'), 'debhelper-compat = 13, always-dep', 'cross and nocheck profiles');
