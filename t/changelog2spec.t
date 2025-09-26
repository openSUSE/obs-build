#!/usr/bin/perl -w

use strict;
use Test::More tests => 15;

sub onetest1(@)
{
  my $expected = shift;
  my $actual = `./changelog2spec @_`;
  is($actual, $expected, "changelog2spec @_");
}
sub onetest(@)
{
  my $expected = shift;
  onetest1($expected, "--selftest", @_);
}

my @tests=(
  # format is 1:specfile 2:expected-changes 3++:list-of-changes-files
  [qw"rpm rpm python-rpm rpm"],
  [qw"python-rpm python-rpm python-rpm rpm"],
  [qw"antlr antlr antlr antlr-bootstrap"],
  [qw"antlr anyunrelated anyunrelated"],
  [qw"antlr-bootstrap antlr-bootstrap antlr antlr-bootstrap"],
  [qw"antlr-bootstrap antlr antlr"],
  [qw"antlr-bootstrap antlr antlr antlr-other"],
  [qw"foo _service:obs_scm:foo foo _service:obs_scm:foo"],
  [qw"_service:obs_scm:foo _service:obs_scm:foo foo _service:obs_scm:foo"],
  [qw"_service:obs_scm:foo foo foo foo-bar"],
  [qw"_service:obs_scm:foo-bar foo foo foo-other"],
);
for my $t (@tests) {
  my @tmp=@$t;
  my $file=shift(@tmp);
  foreach(0..$#tmp) {$tmp[$_].=".changes"}
  my $expected=shift(@tmp);
  onetest($expected, $file, @tmp);
}

my @fulltests=glob("t/data/changelog2spec/*.changes");
for my $t (@fulltests) {
  my $spec = $t; $spec=~s/\.changes$/.spec/;
  my $expected = `cat $spec`;
  onetest1($expected, $t);

  my $specfull = $t; $specfull=~s/\.changes$/-full.spec/;
  my $expectedfull = `cat $specfull`;
  onetest1($expectedfull, '--fulltimestamps', $t);
}
