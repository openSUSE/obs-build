################################################################
#
# Copyright (c) 2021 SUSE LLC
#
# This program is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License version 2 or 3 as
# published by the Free Software Foundation.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program (see the file COPYING); if not, write to the
# Free Software Foundation, Inc.,
# 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301, USA
#
################################################################

package PBuild::BuildResult;

use strict;
use Digest::MD5 ();

use Build;
use Build::SimpleXML;
use PBuild::Util;
use PBuild::Verify;
use PBuild::Container;
use PBuild::Mkosi;

my @binsufs = qw{rpm deb pkg.tar.gz pkg.tar.xz pkg.tar.zst};
my $binsufsre = join('|', map {"\Q$_\E"} @binsufs);

#
# create the .bininfo file that contains information about all binaries
# in the build artifacts
#
sub read_bininfo {
  my ($dir, $withid) = @_;
  my $bininfo;
  my @bininfo_s;
  local *BI;
  if (open(BI, '<', "$dir/.bininfo")) {
    @bininfo_s = stat(BI);
    $bininfo = PBuild::Util::retrieve(\*BI, 1) if @bininfo_s && $bininfo_s[7];
    close BI;
    if ($bininfo) {
      $bininfo->{'.bininfo'} = {'id' => "$bininfo_s[9]/$bininfo_s[7]/$bininfo_s[1]"} if $withid;
      return $bininfo;
    }
  }
  $bininfo = {};
  @bininfo_s = ();
  for my $file (PBuild::Util::ls($dir)) {
    $bininfo->{'.nosourceaccess'} = {} if $file eq '.nosourceaccess';
    if ($file !~ /\.(?:$binsufsre)$/) {
      if ($file eq '.channelinfo' || $file eq 'updateinfo.xml') {
        $bininfo->{'.nouseforbuild'} = {};
      } elsif ($file =~ /\.obsbinlnk$/) {
        my @s = stat("$dir/$file");
        my $d = PBuild::Util::retrieve("$dir/$file", 1);
        next unless @s && $d;
        my $r = {%$d, 'filename' => $file, 'id' => "$s[9]/$s[7]/$s[1]"};
        $bininfo->{$file} = $r;
      } elsif ($file =~ /[-.]appdata\.xml$/) {
        local *F;
        open(F, '<', "$dir/$file") || next;
        my @s = stat(F);
        next unless @s;
        my $ctx = Digest::MD5->new;
        $ctx->addfile(*F);
        close F;
        $bininfo->{$file} = {'md5sum' => $ctx->hexdigest(), 'filename' => $file, 'id' => "$s[9]/$s[7]/$s[1]"};
      }
      next;
    }
    my @s = stat("$dir/$file");
    next unless @s;
    my $id = "$s[9]/$s[7]/$s[1]";
    my $data;
    eval {
      my $leadsigmd5;
      die("$dir/$file: no hdrmd5\n") unless Build::queryhdrmd5("$dir/$file", \$leadsigmd5);
      $data = Build::query("$dir/$file", 'evra' => 1, 'conflicts' => 1, 'weakdeps' => 1, 'addselfprovides' => 1, 'filedeps' => 1, 'normalizedeps' => 1);
      die("$dir/$file: query failed\n") unless $data;
      PBuild::Verify::verify_nevraquery($data);
      $data->{'leadsigmd5'} = $leadsigmd5 if $leadsigmd5;
    };
    if ($@) {
      warn($@);
      next;
    }
    $data->{'filename'} = $file;
    $data->{'id'} = $id;
    $bininfo->{$file} = $data;
  }
  eval {
    PBuild::Util::store("$dir/.bininfo.new", "$dir/.bininfo", $bininfo);
    @bininfo_s = stat("$dir/.bininfo");
    $bininfo->{'.bininfo'} = {'id' => "$bininfo_s[9]/$bininfo_s[7]/$bininfo_s[1]"} if @bininfo_s && $withid;
  };
  warn($@) if $@;
  return $bininfo;
}

#
# copy build artifacts from the build root to the destination
#
sub integrate_build_result {
  my ($p, $result, $dst) = @_;
  # delete old files
  for my $file (sort(PBuild::Util::ls($dst))) {
    next if $file eq '_meta' || $file eq '_meta.success' || $file eq '_meta.fail';
    next if $file eq '_log' || $file eq '_log.success';
    next if $file eq '_repository';
    unlink("$dst/$file") || PBuild::Util::rm_rf("$dst/$file");
  }
  # copy new stuff over
  for my $file (sort keys %$result) {
    next if $file =~ /\.obsbinlnk$/s;
    if ($file =~ /(.*)\.containerinfo$/) {
      # create an obsbinlnk file from the containerinfo
      my $prefix = $1;
      die unless $result->{$file} =~ /^(.*)\/([^\/]+)$/;
      my $obsbinlnk = PBuild::Container::containerinfo2obsbinlnk($1, $2, $p->{'pkg'});
      PBuild::Util::store("$dst/$prefix.obsbinlnk", undef, $obsbinlnk) if $obsbinlnk;
    }
    if ($p->{'buildtype'} eq 'productcompose' && -d $result->{$file}) {
      PBuild::Util::cp_a($result->{$file}, "$dst/$file");
      next;
    }
    if ($p->{'buildtype'} eq 'mkosi' && $file =~ /(.*)\.manifest(?:\.(?:gz|bz2|xz|zst|zstd))?$/) {
      # create an obsbinlnk file from the mkosi manifest
      my $prefix = $1;
      die unless $result->{$file} =~ /^(.*)\/([^\/]+)$/;
      my $obsbinlnk = PBuild::Mkosi::manifest2obsbinlnk($1, $2, $prefix, $p->{'pkg'});
      PBuild::Util::store("$dst/$prefix.obsbinlnk", undef, $obsbinlnk) if $obsbinlnk;
    }
    PBuild::Util::cp($result->{$file}, "$dst/$file");
  }
  # create new bininfo
  my $bininfo = read_bininfo($dst, 1);
  return $bininfo;
}

#
# process a finished build job: copy artifacts, write extra
# information
#
sub integrate_job {
  my ($builddir, $job, $code, $result) = @_;
  my $p = $job->{'pdata'};
  my $packid = $p->{'pkg'};
  my $dst = "$builddir/$packid";
  PBuild::Util::mkdir_p($dst);
  unlink("$dst/_meta");
  unlink("$dst/_log");
  my $bininfo;
  if ($code eq 'succeeded') {
    $bininfo = integrate_build_result($p, $result, $dst);
    PBuild::Util::writestr("$dst/._meta.$$", "$dst/_meta", join("\n", @{$job->{'meta'}})."\n");
    unlink("$dst/_log.success");
    unlink("$dst/_meta.success");
    unlink("$dst/_meta.success");
    link("$dst/_log", "$dst/_log.success");
    link("$dst/_meta", "$dst/_meta.success");
    unlink("$dst/_meta.fail");
  } else {
    PBuild::Util::cp($result->{'_log'}, "$dst/_log");
    PBuild::Util::writestr("$dst/._meta.$$", "$dst/_meta", join("\n", @{$job->{'meta'}})."\n");
    unlink("$dst/_meta.fail");
    link("$dst/_meta", "$dst/_meta.fail");
  }
  unlink("$dst/_reason");
  my $reason = $job->{'reason'};
  if ($reason) {
    $reason = PBuild::Util::clone($reason);
    $reason->{'time'} =  $job->{'readytime'};
    $reason->{'_order'} = [ 'explain', 'time', 'oldsource', 'packagechange' ];
    for (qw{explain time oldsource}) {
      $reason->{$_} = [ $reason->{$_} ] if exists $reason->{$_};
    }
    my $reasonxml = Build::SimpleXML::unparse( { 'reason' => [ $reason ] });
    PBuild::Util::writestr("$dst/._reason.$$", "$dst/_reason", $reasonxml);
  }
  return $bininfo;
}

#
# Create job data
#
sub makejobhist {
  my ($p, $code, $readytime, $starttime, $endtime, $reason, $hostarch) = @_;
  my $jobhist = {};
  $jobhist->{'package'} = $p->{'pkg'};
  $jobhist->{'code'} = $code;
  $jobhist->{'readytime'} = $readytime;
  $jobhist->{'starttime'} = $starttime;
  $jobhist->{'endtime'} = $endtime;
  $jobhist->{'srcmd5'} = $p->{'srcmd5'};
  $jobhist->{'verifymd5'} = $p->{'verifymd5'} if $p->{'verifymd5'} && $p->{'verifymd5'} ne $p->{'srcmd5'};
  $jobhist->{'reason'} = $reason->{'explain'} if $reason && $reason->{'explain'};
  $jobhist->{'hostarch'} = $hostarch if $hostarch;
  return $jobhist;
}

#
# Add job data to the _jobhistory file
#
sub addjobhist {
  my ($builddir, $jobhist) = @_;
  my $fd;
  local $jobhist->{'_order'} = [ qw{package rev srcmd5 versrel bcnt readytime starttime endtime code uri workerid hostarch reason verifymd5} ];
  my $jobhistxml = Build::SimpleXML::unparse({ 'jobhistlist' => [ { 'jobhist' => [ $jobhist ] } ] });
  if (-s "$builddir/_jobhistory") {
    open($fd, '+<', "$builddir/_jobhistory") || die("$builddir/_jobhistory: $!\n");
    seek($fd, -15, 2);
    print $fd substr($jobhistxml, 14);
    close($fd);
  } else {
    PBuild::Util::writestr("$builddir/_jobhistory", undef, $jobhistxml);
  }
}

1;
