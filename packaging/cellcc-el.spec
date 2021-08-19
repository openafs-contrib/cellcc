Name:           cellcc
Version:        %{cccver}
Release:        1%{?dist}
Summary:        CellCC AFS cross-cell synchronization tool

License:        ISC
URL:            http://www.sinenomine.net/
Source0:        cellcc-v%{cccver}.tar.gz

BuildArch: noarch
BuildRequires:  perl(ExtUtils::MakeMaker)
BuildRequires:  perl-generators
Requires:  perl(:MODULE_COMPAT_%(eval "`%{__perl} -V:version`"; echo $version))
Requires: remctl
Requires: kstart
Requires: perl-DBD-MySQL

%{?perl_default_filter}

%description
The CellCC AFS cross-cell synchronization tool. CellCC is a collection of tools
and daemons to help synchronize volumes across AFS cells.

%prep
%setup -q

%build
%{__perl} Makefile.PL INSTALLDIRS=vendor SYSCONFDIR=%{_sysconfdir} LOCALSTATEDIR=%{_var}/lib
make

%install
rm -rf %{buildroot}
make pure_install DESTDIR=%{buildroot}
./packaging/generate-man %{buildroot}/%{_mandir}
find %{buildroot} -type f -name .packlist -exec rm -f {} ';'
find %{buildroot} -depth -type d -exec rmdir {} 2>/dev/null ';'

mkdir -p %{buildroot}/%{_sysconfdir}/cellcc
install -m 644 doc/example_cellcc.json %{buildroot}/%{_sysconfdir}/cellcc/cellcc.json

mkdir -p %{buildroot}/%{_sysconfdir}/remctl/conf.d
install -m 644 etc/remctl/conf.d/cellcc %{buildroot}/%{_sysconfdir}/remctl/conf.d/cellcc

mkdir -p %{buildroot}/%{_var}/lib/cellcc/dump-scratch
mkdir -p %{buildroot}/%{_var}/lib/cellcc/restore-scratch

%{_fixperms} %{buildroot}/*

%files
%{perl_vendorlib}/*

%config(noreplace) %{_sysconfdir}/cellcc/cellcc.json
%config(noreplace) %{_sysconfdir}/remctl/conf.d/cellcc
%{_bindir}/cellcc
%{_bindir}/ccc-debug
%dir %{_var}/lib/cellcc/dump-scratch
%dir %{_var}/lib/cellcc/restore-scratch
%{_mandir}/man1/*.1*

%doc README
%doc doc/example_picksites
%doc doc/example_volumefilter
%doc doc/example_cellcc.json
%doc doc/example_xinetd.conf
%doc doc/example_inetd.conf
%doc doc/example_remctl.conf

%changelog
* Mon Apr 27 2015  Andrew Deason <adeason@sinenomine.net> 1.0
- First release
