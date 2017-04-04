
use Build;

sub expand {
  my ($c, @r) = Build::expand(@_);
  return ($c, sort(@r));
}

sub setuptest {
  my ($repo, $conf) = @_;
  my $l = '';
  local *F;
  open(F, '<', $repo) || die("$repo: $!\n");
  my $id = '';
  while (<F>) {
    $id = "$1.noarch-0/0/0:" if /^P: (\S+)/;
    s/:/:$id/;
    $l .= $_;
  }
  close F;
  open(F, '<', \$l);
  my $config = Build::read_config('noarch', [ split("\n", $conf || '') ]);
  Build::readdeps($config, undef, \*F);
  close F;
  return $config;
}

1;
