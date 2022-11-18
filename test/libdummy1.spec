Name:		libdummy1
Version:	0
Release:	0
Group:		None
Summary:	Dummy
License:	MIT

%build
gcc --version
echo "int dummy(void) {}" | gcc -shared -Wl,-soname=libdummy.so.1 -o libdummy.so.1 -x c -
%install
mkdir -p %buildroot%_libdir
install libdummy.so.1 %buildroot%_libdir

%description
target_cpu %_target_cpu
arch       %_arch
build_arch %_build_arch

%files
%_libdir/libdummy.so.1

%changelog
