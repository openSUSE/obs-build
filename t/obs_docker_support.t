#!/usr/bin/perl -w

use strict;
use Test::More tests => 17;

my @t = (
    [ 'zypper', 'rm', 'zypper' ]
	=> '/usr/bin/zypper "--no-refresh" "-D" "/etc/repos_obs_dockersupport.d/" "rm" "zypper"',
    [ 'zypper', 'in', 'foo', 'bar' ]
	=> '/usr/bin/zypper "--no-refresh" "-D" "/etc/repos_obs_dockersupport.d/" "in" "foo" "bar"',
    [ 'zypper', '--root', '/tmp/root', 'ar', 'https://xx.foo/zz.repo', 'zz' ]
	=> '/usr/bin/zypper "--root" "/tmp/root" "ar" "-C" "https://xx.foo" "zz"',
    [ 'zypper', 'ref' ]
	=> 'skipping zypper refresh',
    [ 'zypper', 'al', 'xx' ]
	=> '/usr/bin/zypper "al" "xx"',

    [ 'apt-get', 'install', 'screen' ]
	=> '/usr/bin/apt-get "-o" "Dir::Etc::SourceList=/etc/aptrepos_obs_dockersupport.d//obssource" "-o" "Dir::Etc::SourceParts=/etc/aptrepos_obs_dockersupport.d/" "--allow-unauthenticated" "install" "screen"',
    [ 'apt-get', 'remove', 'bash' ]
	=> '/usr/bin/apt-get "remove" "bash"',

    [ 'dnf', 'install', 'xterm' ]
	=> '/usr/bin/dnf "--setopt=reposdir=/etc/repos_obs_dockersupport.d/" "install" "xterm"',
    [ 'dnf', 'remove', 'systemd' ]
	=> '/usr/bin/dnf "remove" "systemd"',

    [ 'apk', 'add', 'bash' ]
	=> '/sbin/apk "--repositories-file" "../../../..//etc/apkrepos_obs_dockersupport" "--allow-untrusted" "add" "bash"',
    [ 'apk', 'del', 'busybox' ]
	=> '/sbin/apk "--repositories-file" "../../../..//etc/apkrepos_obs_dockersupport" "--allow-untrusted" "del" "busybox"',
    [ 'apk', 'update' ]
	=> '/sbin/apk "update"',

    [ 'curl', 'https://localhost/etc/passwd' ]
	=> '/usr/bin/curl "localhost:80/build-webcache/7278874b7b1d5162d96b7ad842122d26c50d05924a3e6efa6634c28578fe4dfd"',
    [ 'curl', '-O', 'https://localhost/etc/passwd' ]
	=> '/usr/bin/curl "localhost:80/build-webcache/7278874b7b1d5162d96b7ad842122d26c50d05924a3e6efa6634c28578fe4dfd" "-o" "passwd"',
    [ 'curl', '-o', 'pw', 'https://localhost/etc/passwd' ]
	=> '/usr/bin/curl "-o" "pw" "localhost:80/build-webcache/7278874b7b1d5162d96b7ad842122d26c50d05924a3e6efa6634c28578fe4dfd"',

    [ 'wget', 'https://localhost/etc/passwd' ]
	=> '/usr/bin/wget "localhost:80/build-webcache/7278874b7b1d5162d96b7ad842122d26c50d05924a3e6efa6634c28578fe4dfd" "-O" "passwd"',
    [ 'wget', '-O', 'pw', 'https://localhost/etc/passwd' ]
	=> '/usr/bin/wget "-O" "pw" "localhost:80/build-webcache/7278874b7b1d5162d96b7ad842122d26c50d05924a3e6efa6634c28578fe4dfd"',
);

while (@t) {
  my ($t, $expected) = splice(@t, 0, 2);
  my $result = `./obs-docker-support --testmode @$t`;
  chomp($result);
  is($result, $expected, "@$t");
}
