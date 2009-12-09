Name:		dummy
Version:	0
Release:	0
Group:		None
Summary:	Dummy
License:	GPL
BuildRoot:	%_tmppath/%name-%version-build

%build
gcc --version
%install
mkdir -p %buildroot/etc
cp /etc/shells %buildroot/etc/foo

%description
%_target_cpu
%_arch
%_build_arch

%files
%defattr(-,root,root)
/etc/foo

%changelog
