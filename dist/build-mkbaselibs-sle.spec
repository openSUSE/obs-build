#
# spec file for package build-mkbaselibs-sle
#
# Copyright (c) 2011 SUSE LINUX Products GmbH, Nuernberg, Germany.
#
# All modifications and additions to the file contributed by third parties
# remain the property of their copyright owners, unless otherwise agreed
# upon. The license for this file, and modifications and additions to the
# file, is the same license as for the pristine package itself (unless the
# license for the pristine package is not an Open Source License, in which
# case the license is the MIT License). An "Open Source License" is a
# license that conforms to the Open Source Definition (Version 1.9)
# published by the Open Source Initiative.

# Please submit bugfixes or comments via http://bugs.opensuse.org/
#

# norootforbuild


Name:           build-mkbaselibs-sle
License:        GPLv2+
Group:          Development/Tools/Building
AutoReqProv:    on
Summary:        Tools to generate base lib packages
Version:        2011.07.01
Release:        1
#!BuildIgnore:  build-mkbaselibs
Provides:       build-mkbaselibs
Source:         build-%{version}.tar.gz
BuildRoot:      %{_tmppath}/%{name}-%{version}-build
BuildArch:      noarch

%description
This package contains the parts which may be installed in the inner build system
for generating base lib packages.

This is the SLE variant including IA64 binary generation.

%prep
%setup -q -n build-%{version}

%build

%install
install -m 0755 -d $RPM_BUILD_ROOT/usr/lib/build
install -m 0755 mkbaselibs \
                $RPM_BUILD_ROOT/usr/lib/build/mkbaselibs
install -m 0644 baselibs_global-deb.conf \
                $RPM_BUILD_ROOT/usr/lib/build/baselibs_global-deb.conf
install -m 0644 baselibs_global-sle.conf \
                $RPM_BUILD_ROOT/usr/lib/build/baselibs_global.conf

%files
%defattr(-,root,root)
%dir /usr/lib/build
/usr/lib/build/mkbaselibs
/usr/lib/build/baselibs*

%changelog
