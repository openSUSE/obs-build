
use Build;

sub expand {
  my ($c, @r) = Build::expand(@_);
  return ($c, sort(@r));
}

sub setuptest {
  my ($repo, $conf) = @_;
  my $l = '';
  my $id = '';
  for (split("\n", $repo)) {
    $id = "$1.noarch-0/0/0:" if /^P: (\S+)/;
    s/:/:$id/;
    $l .= "$_\n";
  }
  local *F;
  open(F, '<', \$l);
  my $config = Build::read_config('noarch', [ split("\n", $conf || '') ]);
  Build::readdeps($config, undef, \*F);
  close F;
  return $config;
}

1;
