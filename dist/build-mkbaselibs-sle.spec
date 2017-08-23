#
# spec file for package build-mkbaselibs-sle
#
# Copyright (c) 2017 SUSE LINUX GmbH, Nuernberg, Germany.
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


Name:           build-mkbaselibs-sle
Summary:        Tools to generate base lib packages
License:        GPL-2.0+
Group:          Development/Tools/Building
Version:        20170720
Release:        0
#!BuildIgnore:  build-mkbaselibs
Provides:       build-mkbaselibs
Conflicts:      otherproviders(build-mkbaselibs)
Source:         obs-build-%{version}.tar.gz
BuildRoot:      %{_tmppath}/%{name}-%{version}-build
BuildArch:      noarch

%description
This package contains the parts which may be installed in the inner build system
for generating base lib packages.

This is the SLE variant including IA64 binary generation.

%prep
%setup -q -n obs-build-%{version}

%build

%install
install -m 0755 -d $RPM_BUILD_ROOT/usr/lib/build
install -m 0755 mkbaselibs \
                $RPM_BUILD_ROOT/usr/lib/build/mkbaselibs
install -m 0644 baselibs_configs/baselibs_global-deb.conf \
                $RPM_BUILD_ROOT/usr/lib/build/baselibs_global-deb.conf
install -m 0644 baselibs_configs/baselibs_global.conf \
                $RPM_BUILD_ROOT/usr/lib/build/baselibs_global.conf

%files
%defattr(-,root,root)
%dir /usr/lib/build
/usr/lib/build/mkbaselibs
/usr/lib/build/baselibs*

%changelog
