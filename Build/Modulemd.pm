################################################################
#
# Copyright (c) 2021 SUSE Linux Products GmbH
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

package Build::Modulemd;

use Build::SimpleYAML;

use strict;

# This module provides a modulemd data to yaml converter. It supports
# both the 'modulemd' and 'modulemd-defaults' formats.

my $mdtemplate = {
  '_order' => [ 'document', 'version', 'data' ],
  'version' => 'number',
  'data' => {
    '_order' => [ 'name', 'stream', 'version', 'context', 'arch', 'summary', 'description', 'license', 'xmd', 'dependencies', 'references', 'profiles', 'api', 'filter', 'buildopts', 'components', 'artifacts' ],
    'version' => 'number',
    'description' => 'folded',
    'license' => {
      '_order' => [ 'module', 'content' ],
    },
    'components' => {
      'rpms' => {
        '*' => {
          '_order' => [ 'rationale', 'ref', 'buildorder', 'arches' ],
          'buildorder' => 'number',
          'arches' => 'inline',
        },
      },
    },
    'buildopts' => {
      'rpms' => {
        'macros' => 'literal',
      },
    },
    'dependencies' => {
      'requires' => {
        '*' => 'inline',
      },
      'buildrequires' => {
        '*' => 'inline',
      },
    },
  },
};

my $mddefaultstemplate = {
  '_order' => [ 'document', 'version', 'data' ],
  'version' => 'number',
  'data' => {
    '_order' => [ 'module', 'modified', 'stream', 'profiles', 'intents' ],
    'modified' => 'number',
    'profiles' => {
      '*' => 'inline',
    },
    'intents' => {
      '*' => {
        '_order' => [ 'stream', 'profiles' ],
        'profiles' => {
          '*' => 'inline',
        },
      },
    },
  },
};

sub mdtoyaml {
  my ($md) = @_;
  my $template = $md && $md->{'document'} eq 'modulemd-defaults' ? $mddefaultstemplate : $mdtemplate;
  return Build::SimpleYAML::unparse($md, 'template' => $template);
}

1;
