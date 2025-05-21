#!/usr/bin/perl -w

use strict;
use Test::More tests => 37;

use Build::Rpm;

my @tests = (
q{
%%}				=> '%',
q{
%{%}}				=> '%{%}',
q{
%not_defined}			=> '%not_defined',
q{
%{not_defined}}			=> '%{not_defined}',
q{
%{}}				=> '%{}',
q{
%{ test }}			=> '%{ test }',
q{
%define this that
%{this}} 			=> 'that',
q{
%define this that
%{?this}}			=> 'that',
q{
%define this that
%{?that}}			=> '',
q{
%define this that
%{?!this}}			=> '',
q{
%define this that
%{?!that}}			=> '',
q{
%define this that
%{?this:foo}}			=> 'foo',
q{
%define this that
%{?that:foo}}			=> '',
q{
%define this that
%{?!this:foo}}			=> '',
q{
%define this that
%{?!that:foo}}			=> 'foo',
q{
%define this that
%define that_that foo
%{expand:%%{%{this}_that}}}	=> 'foo',
q{
%define bar() "Bar %#: %{?1} %{?2}"
%define foo() "Foo %#: %{?1} %{?2}" %bar a
%foo 1 2}			=> '"Foo 2: 1 2" "Bar 1: a "',
q{
%define foo hello" + "world
%["%foo"]}			=> 'hello" + "world',
q{
%define foo hello
%define bar world
%{foo:%{bar}}}			=> 'hello',
q{
%define foo hello
%define bar world
%{?foo:%{bar}}}			=> 'world',
q{%[1 + %[2 * 3]]}		=> '7',
q{%[0 && %does_not_exist]}	=> '0',
q{%{shrink: a  b c }}           => 'a b c',
q{%{expr: 1 + 2}}               => '3',
q{%{dirname:foo/bar}}           => 'foo',
q{%{basename:foo/bar}}          => 'bar',
q{%{dirname:foo}}               => 'foo',
q{%{basename:foo}}              => 'foo',
q{%{dirname:foo/bar/}}          => 'foo/bar',
q{%{basename:foo/bar/}}         => '',
q{%{dirname:/}}                 => '',
q{%{basename:/}}                => '',
q{%{dirname}}                   => '',
q{%{basename}}                  => '',
q{
%define foo bar
%define baz foo
%{expand:%%%baz}}		=> 'bar',
q{%{expand %%%%%%%%}}		=> '%%',
q{
%define foo bar
%{defined:foo}/%{defined:oof}}	=> '1/0',
);

while (@tests) {
  my ($in, $expected) = splice(@tests, 0, 2);
  $in =~ s/^\n//s;
  my %macros = ( 'nil' => '' );
  my %macros_args;
  my $actual = '';
  $actual .= Build::Rpm::expandmacros({}, $_, \%macros, \%macros_args) for split("\n", $in);
  is($actual, $expected, $in);
}

