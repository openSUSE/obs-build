#!/usr/bin/perl -w

use strict;
use Test::More tests => 11;
use File::Temp ();
use Cwd ();

my $runservices = Cwd::abs_path('./runservices');
# runservices loads its modules from BUILD_DIR
$ENV{'BUILD_DIR'} = Cwd::getcwd();

# Run runservices in $dir; returns (exit code, stdout, stderr)
sub run {
  my ($dir, @args) = @_;
  my $errfile = File::Temp->new();
  my $cmd = join(' ', map {"'$_'"} $runservices, @args);
  my $out = `cd '$dir' && $cmd 2>$errfile`;
  my $code = $? >> 8;
  local $/;
  open(my $fh, '<', $errfile) || die("$errfile: $!\n");
  my $err = <$fh>;
  close $fh;
  return ($code, $out, $err);
}

# A package directory whose _service would fail if it was run
my $pkgdir = File::Temp::tempdir('CLEANUP' => 1);
open(my $fh, '>', "$pkgdir/_service") || die("_service: $!\n");
print $fh "<services>\n  <service name=\"runservices-test-missing\" mode=\"buildtime\"/>\n</services>\n";
close $fh;

for my $opt ('--help', '-h') {
  my ($code, $out, $err) = run($pkgdir, $opt);
  is($code, 0, "$opt exits with 0");
  like($out, qr/^Usage: runservices /, "$opt prints usage on stdout");
  is($err, '', "$opt runs no services");
}

{
  my ($code, $out, $err) = run($pkgdir, '--buildroot', '/', '--help');
  is($code, 0, "--help after other options exits with 0");
  like($out, qr/^Usage: runservices /, "--help after other options prints usage");
}

{
  my ($code, $out, $err) = run($pkgdir, '--bogus');
  isnt($code, 0, "unknown option fails");
  like($err, qr/unknown option '--bogus'/, "unknown option is reported");
  like($err, qr/Usage: runservices /, "unknown option prints usage on stderr");
}
