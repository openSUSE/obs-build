#!/usr/bin/perl -w

use strict;
use Test::More tests => 20;

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
%{foo:%{bar}}}			=> 'world',
q{%[1 + %[2 * 3]]}		=> '7',
);

while (@tests) {
  my ($in, $expected) = splice(@tests, 0, 2);
  $in =~ s/^\n//s;
  my %macros = ( 'nil' => '' );
  my %macros_args;
  my $actual = '';
  $actual .= Build::Rpm::expandmacros({}, $_, undef, \%macros, \%macros_args) for split("\n", $in);
  is($actual, $expected, $in);
}

