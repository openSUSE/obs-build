#!/usr/bin/perl -w

use strict;
use Test::More tests => 12;

require 't/testlib.pm';

my $repo = <<'EOR';
P: a = 1-1
R: b
P: b = 1-1
R: /file
s: e
P: c = 1-1
P: d = 1-1
r: b
P: e = 1-1
EOR

my $config = setuptest($repo);
my @r;

@r = expand($config, 'a');
is_deeply(\@r, [1, 'a', 'b'], 'ignored file requires');

$config = setuptest($repo, "FileProvides: /file c");
@r = expand($config, 'a');
is_deeply(\@r, [1, 'a', 'b', 'c'], 'honoured file requires');

$config = setuptest($repo, "ExpandFlags: keepfilerequires");
@r = expand($config, 'a');
is_deeply(\@r, [undef, 'nothing provides /file needed by b'], 'missing file provides');

$config = setuptest($repo, "ExpandFlags: keepfilerequires\nFileProvides: /file c");
@r = expand($config, 'a');
is_deeply(\@r, [1, 'a', 'b', 'c'], 'honoured file requires');

$config = setuptest($repo, "ExpandFlags: dorecommends");
@r = expand($config, 'd');
is_deeply(\@r, [1, 'b', 'd'], 'ignored file requires');

$config = setuptest($repo, "ExpandFlags: dorecommends\nFileProvides: /file c");
@r = expand($config, 'd');
is_deeply(\@r, [1, 'b', 'c', 'd'], 'honoured file requires');

$config = setuptest($repo, "ExpandFlags: dorecommends keepfilerequires");
@r = expand($config, 'd');
# This should rather just ignore b
# is_deeply(\@r, [1, 'd'], 'missing file provides');
is_deeply(\@r, [undef, 'nothing provides /file needed by b'], 'missing file provides');

$config = setuptest($repo, "ExpandFlags: dorecommends keepfilerequires\nFileProvides: /file c");
@r = expand($config, 'd');
is_deeply(\@r, [1, 'b', 'c', 'd'], 'honoured file requires');

$config = setuptest($repo, "ExpandFlags: dosupplements");
@r = expand($config, 'e');
is_deeply(\@r, [1, 'b', 'e'], 'ignored file requires');

$config = setuptest($repo, "ExpandFlags: dosupplements\nFileProvides: /file c");
@r = expand($config, 'e');
is_deeply(\@r, [1, 'b', 'c', 'e'], 'honoured file requires');

$config = setuptest($repo, "ExpandFlags: dosupplements keepfilerequires");
@r = expand($config, 'e');
# This should rather just ignore b
# is_deeply(\@r, [1, 'e'], 'missing file provides');
is_deeply(\@r, [undef, 'nothing provides /file needed by b'], 'missing file provides');

$config = setuptest($repo, "ExpandFlags: dosupplements keepfilerequires\nFileProvides: /file c");
@r = expand($config, 'e');
is_deeply(\@r, [1, 'b', 'c', 'e'], 'honoured file requires');
