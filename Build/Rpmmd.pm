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

sub generic_parse {
  my ($how, $in, $res, %options) = @_;
  $res ||= [];
  my @cursor = ([undef, $how, undef, $res, undef, \%options]);
  my $p = new XML::Parser(Handlers => {
    Start => sub {
      my ($p, $el) = @_;
      my $h = $cursor[-1]->[1];
      return unless exists $h->{$el};
      $h = $h->{$el};
      push @cursor, [$el, $h];
      $cursor[-1]->[2] = '' if $h->{'_text'};
      $h->{'_start'}->($h, \@cursor, @_) if exists $h->{'_start'};
    },
    End => sub {
      my ($p, $el) = @_;
      if ($cursor[-1]->[0] eq $el) {
	my $h = $cursor[-1]->[1];
	$h->{'_end'}->($h, \@cursor, @_) if exists $h->{'_end'};
	pop @cursor;
      }
    },
    Char => sub {
      my ($p, $text) = @_;
      $cursor[-1]->[2] .= $text if defined $cursor[-1]->[2];
    },
  }, ErrorContext => 2);
  if (ref($in)) {
    $p->parse($in);
  } else {
    $p->parsefile($in);
  }
  return $res;
}

sub generic_store_text {
  my ($h, $c, $p, $el) = @_;
  my $data = $c->[0]->[4];
  $data->{$h->{'_tag'}} = $c->[-1]->[2] if defined $c->[-1]->[2];
}

sub generic_store_attr {
  my ($h, $c, $p, $el, %attr) = @_;
  my $data = $c->[0]->[4];
  $data->{$h->{'_tag'}} = $attr{$h->{'_attr'}} if defined $attr{$h->{'_attr'}};
}

sub generic_new_data {
  my ($h, $c, $p, $el, %attr) = @_;
  $c->[0]->[4] = {};
  generic_store_attr(@_) if $h->{'_attr'};
}

sub generic_add_result {
  my ($h, $c, $p, $el) = @_;
  my $data = $c->[0]->[4];
  return unless $data;
  my $res = $c->[0]->[3];
  if (ref($res) eq 'CODE') {
    $res->($data);
  } else {
    push @$res, $data;
  }
  undef $c->[0]->[4];
}

my $repomdparser = {
  repomd => {
    data => {
      _start => \&generic_new_data,
      _attr => 'type',
      _tag => 'type',
      _end => \&generic_add_result,
      location => { _start => \&generic_store_attr, _attr => 'href', _tag => 'location'},
      size => { _text => 1, _end => \&generic_store_text, _tag => 'size'},
    },
  },
};

my $primaryparser = {
  metadata => {
    'package' => {
      _start => \&generic_new_data,
      _attr => 'type',
      _tag => 'type',
      _end => \&generic_add_result,
      name => { _text => 1, _end => \&generic_store_text, _tag => 'name' },
      arch => { _text => 1, _end => \&generic_store_text, _tag => 'arch' },
      version => { _start => \&primary_handle_version },
      'time' => { _start => \&primary_handle_time },
      format => {
        'rpm:provides' =>    { 'rpm:entry' => { _start => \&primary_handle_dep , _tag => 'provides' }, },
        'rpm:requires' =>    { 'rpm:entry' => { _start => \&primary_handle_dep , _tag => 'requires' }, },
        'rpm:conflicts' =>   { 'rpm:entry' => { _start => \&primary_handle_dep , _tag => 'conflicts' }, },
        'rpm:recommends' =>  { 'rpm:entry' => { _start => \&primary_handle_dep , _tag => 'recommends' }, },
        'rpm:suggests' =>    { 'rpm:entry' => { _start => \&primary_handle_dep , _tag => 'suggests' }, },
        'rpm:supplements' => { 'rpm:entry' => { _start => \&primary_handle_dep , _tag => 'supplements' }, },
        'rpm:enhances' =>    { 'rpm:entry' => { _start => \&primary_handle_dep , _tag => 'enhances' }, },
        'rpm:obsoletes' =>   { 'rpm:entry' => { _start => \&primary_handle_dep , _tag => 'obsoletes' }, },
        'rpm:buildhost' => { _text => 1, _end => \&generic_store_text, _tag => 'buildhost' },
        'rpm:sourcerpm' => { _text => 1, _end => \&primary_handle_sourcerpm , _tag => 'source' },
### currently commented out, as we ignore file provides in createrpmdeps
#       file => { _text => 1, _end => \&primary_handle_file_end, _tag => 'provides' },
      },
      location => { _start => \&generic_store_attr, _attr => 'href', _tag => 'location'},
    },
  },
};

sub primary_handle_sourcerpm {
  my ($h, $c, $p, $el, %attr) = @_;
  my $data = $c->[0]->[4];
  return unless defined $c->[-1]->[2];
  $c->[-1]->[2] =~ s/-[^-]*-[^-]*\.[^\.]*\.rpm$//;
  $data->{$h->{'_tag'}} = $c->[-1]->[2];
}

sub primary_handle_version {
  my ($h, $c, $p, $el, %attr) = @_;
  my $data = $c->[0]->[4];
  $data->{'epoch'} = $attr{'epoch'} if $attr{'epoch'};
  $data->{'version'} = $attr{'ver'};
  $data->{'release'} = $attr{'rel'};
}

sub primary_handle_time {
  my ($h, $c, $p, $el, %attr) = @_;
  my $data = $c->[0]->[4];
  $data->{'filetime'} = $attr{'file'} if $attr{'file'};
  $data->{'buildtime'} = $attr{'build'} if $attr{'build'};
}

sub primary_handle_file_end {
  my ($h, $c, $p, $el) = @_;
  primary_handle_dep($h, $c, $p, $el, 'name', $c->[-1]->[2]);
}

my %flagmap = ( EQ => '=', LE => '<=', GE => '>=', GT => '>', LT => '<', NE => '!=' );

sub primary_handle_dep {
  my ($h, $c, $p, $el, %attr) = @_;
  my $dep = $attr{'name'};
  return if $dep =~ /^rpmlib\(/;
  if(exists $attr{'flags'}) {
    my $evr = $attr{'ver'};
    return unless defined($evr) && exists($flagmap{$attr{'flags'}});
    $evr = "$attr{'epoch'}:$evr" if $attr{'epoch'};
    $evr .= "-$attr{'rel'}" if defined $attr{'rel'};
    $dep .= " $flagmap{$attr{'flags'}} $evr";
  }
  my $data = $c->[0]->[4];
  push @{$data->{$h->{'_tag'}}}, $dep;
}

sub parse_repomd {
  return generic_parse($repomdparser, @_);
}

sub parse_primary {
  return generic_parse($primaryparser, @_);
}

