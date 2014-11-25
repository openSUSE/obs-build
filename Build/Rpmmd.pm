################################################################
#
# Copyright (c) 1995-2014 SUSE Linux Products GmbH
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

package Build::Rpmmd;

use strict;

use XML::Parser;

my @cursor;
my $data;
my $result;

sub generic_handle_start {
  my ($p, $el) = @_;
  my $h = $cursor[-1]->[1];
  if (exists $h->{$el}) {
    $h = $h->{$el};
    push @cursor, [$el, $h];
    $cursor[-1]->[2] = '' if $h->{'_text'};
    $h->{'_start'}->($h, @_) if exists $h->{'_start'};
  }
}

sub generic_handle_char {
  my ($p, $text) = @_;
  $cursor[-1]->[2] .= $text if defined $cursor[-1]->[2];
}

sub generic_handle_end {
  my ($p, $el) = @_;
  if (!defined $cursor[-1]->[0] || $cursor[-1]->[0] eq $el) {
    my $h = $cursor[-1]->[1];
    $h->{'_end'}->($h, @_) if exists $h->{'_end'};
    pop @cursor;
  }
}

sub generic_store_text {
  my ($h, $p, $el) = @_;
  $data->{$h->{'_tag'}} = $cursor[-1]->[2] if defined $cursor[-1]->[2];
}

sub generic_store_attr {
  my ($h, $p, $el, %attr) = @_;
  $data->{$h->{'_tag'}} = $attr{$h->{'_attr'}} if defined $attr{$h->{'_attr'}};
}

sub generic_add_result {
  my ($h, $p, $el, %attr) = @_;
  return unless $data;
  if (ref($result) eq 'CODE') {
    $result->($data);
  } else {
    push @$result, $data;
  }
  undef $data;
}


my $repomdparser = {
  repomd => {
    data => {
      _start => \&repomd_handle_data_start,
      _end => \&generic_add_result,
      location => { _start => \&generic_store_attr, _attr => 'href', _tag => 'location'},
      size => { _text => 1, _end => \&generic_store_text, _tag => 'size'},
    },
  },
};


sub repomd_handle_data_start {
  my ($h, $p, $el, %attr) = @_;
  $data = {'type' => $attr{'type'}};
}

sub parse_repomd {
  my ($fh, $res) = @_;
  my $p = new XML::Parser(
  Handlers => {
    Start => \&generic_handle_start,
    End => \&generic_handle_end,
    Char => \&generic_handle_char
  });
  @cursor = ([undef, $repomdparser]);
  $result = $res;
  $p->parse($fh);
}


my $primaryparser = {
  metadata => {
    'package' => {
      _start => \&primary_handle_package_start,
      _end => \&generic_add_result,
      name => { _text => 1, _end => \&generic_store_text, _tag => 'name' },
      arch => { _text => 1, _end => \&generic_store_text, _tag => 'arch' },
      version => { _start => \&primary_handle_version },
      'time' => { _start => \&primary_handle_time },
      format => {
        'rpm:provides' => { 'rpm:entry' => { _start => \&primary_handle_dep , _tag => 'provides' }, },
        'rpm:requires' => { 'rpm:entry' => { _start => \&primary_handle_dep , _tag => 'requires' }, },
        'rpm:conflicts' => { 'rpm:entry' => { _start => \&primary_handle_dep , _tag => 'conflicts' }, },
        'rpm:obsoletes' => { 'rpm:entry' => { _start => \&primary_handle_dep , _tag => 'obsoletes' }, },
        'rpm:buildhost' => { _text => 1, _end => \&generic_store_text, _tag => 'buildhost' },
        'rpm:sourcerpm' => { _text => 1, _end => \&generic_store_text, _tag => 'sourcerpm' },
### currently commented out, as we ignore file provides in createrpmdeps
#       file => { _text => 1, _end => \&primary_handle_file_end, _tag => 'provides' }
#       },
      },
      location => { _start => \&generic_store_attr, _attr => 'href', _tag => 'location'},
    },
  },
};


sub primary_handle_package_start {
  my ($h, $p, $el, %attr) = @_;
  $data = { type => $attr{'type'} };
}

sub primary_handle_version {
  my ($h, $p, $el, %attr) = @_;
  $data->{'epoch'} = $attr{'epoch'} if $attr{'epoch'};
  $data->{'version'} = $attr{'ver'};
  $data->{'release'} = $attr{'rel'};
}

sub primary_handle_time {
  my ($h, $p, $el, %attr) = @_;
  $data->{'filetime'} = $attr{'file'} if $attr{'file'};
  $data->{'buildtime'} = $attr{'build'} if $attr{'build'};
}

sub primary_handle_file_end {
  my ($h, $p, $el) = @_;
  primary_handle_dep($h, $p, $el, 'name', $h->[2]);
}

my %flagmap = ( EQ => '=', LE => '<=', GE => '>=', GT => '>', LT => '<', NE => '!=' );

sub primary_handle_dep {
  my ($h, $p, $el, %attr) = @_;
  my $dep = $attr{'name'};
  return if $dep =~ /^rpmlib\(/;
  if(exists $attr{'flags'}) {
    my $evr = $attr{'ver'};
    return unless defined($evr) && exists($flagmap{$attr{'flags'}});
    $evr = "$attr{'epoch'}:$evr" if $attr{'epoch'};
    $evr .= "-$attr{'rel'}" if defined $attr{'rel'};
    $dep .= " $flagmap{$attr{'flags'}} $evr";
  }
  push @{$data->{$h->{'_tag'}}}, $dep;
}

sub parse_primary {
  my ($fh, $res) = @_;
  my $p = new XML::Parser(
  Handlers => {
    Start => \&generic_handle_start,
    End => \&generic_handle_end,
    Char => \&generic_handle_char
  });
  @cursor = ([undef, $primaryparser]);
  $result = $res;
  $p->parse($fh);
}

