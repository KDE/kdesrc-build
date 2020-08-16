package ksb::FirstRun 0.10;

use 5.014;
use strict;
use warnings;
use File::Spec qw(splitpath);
use List::Util qw(min max first);

use ksb::BuildException;
use ksb::Debug qw(colorize);
use ksb::OSSupport;
use ksb::Util;

=head1 NAME

ksb::FirstRun

=head1 DESCRIPTION

Performs initial-install setup, implementing the C<--initial-setup> option.

B<NOTE> This module is supposed to be loadable even under minimal Perl
environments as fielded in "minimal Docker container" forms of popular distros.

=head1 SYNOPSIS

    my $exitcode = ksb::FirstRun::setupUserSystem();
    exit $exitcode;

=cut

use constant {
    SHELL_RC_SNIPPET => <<'RC'
# kdesrc-build ##################################################

## Add kdesrc-build to PATH
export PATH="$HOME/kde/src/kdesrc-build:$PATH"

## Run projects built with kdesrc-build
function kdesrc-run
{
  source "$HOME/kde/build/$1/prefix.sh" && "$HOME/kde/usr/bin/$@"
}
#################################################################
RC
};

sub setupUserSystem
{
    my $baseDir = shift;
    my $os = ksb::OSSupport->new;
    my $envShell = $ENV{'SHELL'} // 'undefined';
    my $shellName = (split '/', $envShell)[-1];

    eval {
        _installSystemPackages($os);
        _setupBaseConfiguration($baseDir);
        _setupShellRcFile($shellName);
    };

    if (had_an_exception($@)) {
        my $msg = $@->{message};
        say colorize ("  b[r[*] r[$msg]");
        return 1;
    }

    return 0;
}

# Internal functions

# Reads from the __DATA__ section below and dumps the contents in a hash keyed
# by filename (the @@ part between each resource).
my %packages;
sub _readPackages
{
    return \%packages if %packages;

    my $cur_file;
    my $cur_value;
    my $commit = sub {
        return unless $cur_file;
        $packages{$cur_file} = ($cur_value =~ s/ *$//r);
        $cur_value = '';
    };

    while(my $line = <DATA>) {
        next if $line =~ /^\s*#/ and $cur_file !~ /sample-rc/;
        chomp $line;

        my ($fname) = ($line =~ /^@@ *([^ ]+)$/);
        if ($fname) {
            $commit->();
            $cur_file = $fname;
        }
        else {
            $cur_value .= "$line\n";
        }
    }

    $commit->();
    return \%packages;
}

sub _throw
{
    my $msg = shift;
    die (make_exception('Setup', $msg));
}

sub _installSystemPackages
{
    my $os = shift;
    my $vendor = $os->vendorID;
    my $osVersion = $os->vendorVersion;

    print colorize(<<DONE);
 b[-] Installing b[system packages] for b[$vendor]...
DONE

    my @packages = _findBestVendorPackageList($os);
    if (@packages) {
        my @installCmd = _findBestInstallCmd($os);
        say colorize (" b[*] Running b[" . join(' ', @installCmd) . "]");
        my $result = system (@installCmd, @packages);
        if ($result >> 8 == 0) {
            say colorize (" b[*] b[g[Looks like the necessary packages were successfully installed!]");
        } else {
            say colorize (" r[b[*] Ran into an error with the installer!");
        }
    } else {
        say colorize (" r[b[*] Packages could not be installed, because kdesrc-build does not know your distribution (" . $vendor .")");
    }
}

# Return the highest number of cores we can use based on available memory. Requires
# the number of cores we have available
sub _getNumCoresForLowMemory
{
    my $num_cores = shift;

    # Try to detect the amount of total memory for a corresponding option for
    # heavyweight modules (sorry ade, not sure what's needed for FreeBSD!)
    my $mem_total;
    my $total_mem_line = first { /MemTotal/ } (`cat /proc/meminfo`);

    if ($total_mem_line && $? == 0) {
        ($mem_total) = ($total_mem_line =~ /^MemTotal:\s*([0-9]+) /); # Value in KiB
        $mem_total = int $mem_total;
    }

    # 4 GiB is assumed if no info on memory is available, as this will
    # calculate to 2 cores. sprintf is used since there's no Perl round function
    my $rounded_mem = $mem_total ? (int sprintf("%.0f", $mem_total / 1024000.0)) : 4;
    my $max_cores_for_mem = max(1, int $rounded_mem / 2); # Assume 2 GiB per core
    my $num_cores_low = min($max_cores_for_mem, $num_cores);

    return $num_cores_low;
}

sub _setupBaseConfiguration
{
    my $baseDir = shift;
    my @knownLocations = ("$ENV{PWD}/kdesrc-buildrc", "$ENV{HOME}/.kdesrc-buildrc");
    my $locatedFile = first { -e $_ } @knownLocations;

    if (defined $locatedFile) {
        print colorize(<<DONE);
 b[*] You already have a configuration file: b[y[$locatedFile].
DONE
        return;
    }

    print colorize(<<DONE);
 b[*] Creating b[sample configuration file]: b[y["$ENV{HOME}/.kdesrc-buildrc"]...
DONE

    my $sampleRc = $packages{'sample-rc'} or
        _throw("Embedded sample file missing!");

    my $numCores = `nproc 2>/dev/null` || 4;
    my $numCoresLow = _getNumCoresForLowMemory($numCores);

    $sampleRc =~ s/%\{num_cores}/$numCores/g;
    $sampleRc =~ s/%\{num_cores_low}/$numCoresLow/g;
    $sampleRc =~ s/%\{base_dir}/$baseDir/g;

    open my $sampleFh, '>', "$ENV{HOME}/.kdesrc-buildrc"
        or _throw("Couldn't open new ~/.kdesrc-buildrc: $!");

    print $sampleFh $sampleRc
        or _throw("Couldn't write to ~/.kdesrc-buildrc: $!");

    close $sampleFh
        or _throw("Error closing ~/.kdesrc-buildrc: $!");
}

sub _setupShellRcFile
{
    my $shellName = shift;
    my $rcFilepath = undef;
    my $isAuto = 1;

    if ($shellName eq 'bash') {
        $rcFilepath = "$ENV{'HOME'}/.bashrc";
    } elsif ($shellName eq 'zsh') {
        if (defined $ENV{'ZDOTDIR'}) {
            $rcFilepath = "$ENV{'ZDOTDIR'}/.zshrc";
        } else {
            $rcFilepath = "$ENV{'HOME'}/.zshrc";
        }
    } else {
        say colorize(" b[*] Updating rc-file for shell 'y[b[$shellName]' is not supported.");
        $isAuto = 0;
    }

    if (defined $rcFilepath) {
        $isAuto = ksb::Util::yesNoPrompt(colorize(" b[*] Update your b[y[$rcFilepath]?"));
    }

    if ($isAuto) {
        open(my $rcFh, '>>', "$rcFilepath") or _throw("Couldn't open $rcFilepath: $!");
        say $rcFh '';
        say $rcFh SHELL_RC_SNIPPET;
        close($rcFh);
        say colorize(<<DONE);
     - Added b[y[kdesrc-build] directory into PATH
     - Added b[y[kdesrc-run] shell function
 b[*] b[g[Shell rc-file is successfully setup].
DONE
    } else {
        say '';
        say colorize(<<DONE);
 b[*] You can manually configure your shell rc-file with the snippet below:
DONE
        say SHELL_RC_SNIPPET;
    }
}



sub _findBestInstallCmd
{
    my $os = shift;
    my $pkgsRef = _readPackages();

    my @supportedDistros =
        map  { s{^cmd/install/([^/]+)/.*$}{$1}; $_ }
        grep { /^cmd\/install\// }
            keys %{$pkgsRef};

    my $bestVendor = $os->bestDistroMatch(@supportedDistros);
    say colorize ("    Using installer for b[$bestVendor]");

    my $version = $os->vendorVersion();
    my @cmd;

    for my $opt ("$bestVendor/$version", "$bestVendor/unknown") {
        my $key = "cmd/install/$opt";
        next unless exists $pkgsRef->{$key};
        @cmd = split(' ', $pkgsRef->{$key});
        last;
    }

    _throw("No installer for $bestVendor!")
        unless @cmd;

    # If not running as root already, add sudo
    unshift @cmd, 'sudo' if $> != 0;

    return @cmd;
}

sub _findBestVendorPackageList
{
    my $os = shift;

    # Debian handles Ubuntu also
    my @supportedDistros =
        map  { s{^pkg/([^/]+)/.*$}{$1}; $_ }
        grep { /^pkg\// }
            keys %{_readPackages()};

    my $bestVendor = $os->bestDistroMatch(@supportedDistros);
    my $version = $os->vendorVersion();
    say colorize ("    Installing packages for b[$bestVendor]/b[$version]");
    return _packagesForVendor($bestVendor, $version);
}

sub _packagesForVendor
{
    my ($vendor, $version) = @_;
    my $packagesRef = _readPackages();

    foreach my $opt ("pkg/$vendor/$version", "pkg/$vendor/unknown") {
        next unless exists $packagesRef->{$opt};
        my @packages = split(' ', $packagesRef->{$opt});
        return @packages;
    }

    return;
}

1;

__DATA__
@@ pkg/debian/unknown
libyaml-libyaml-perl libio-socket-ssl-perl libjson-xs-perl
git shared-mime-info cmake build-essential flex bison gperf libssl-dev intltool
libdbusmenu-qt5-dev
liburi-perl gettext

@@ pkg/opensuse/unknown
cmake
docbook-xsl-stylesheets
docbook_4
flex bison
gettext-runtime
gettext-tools
giflib-devel
git
gperf
intltool
libboost_headers-devel
libdbusmenu-qt5-devel
libqt5-qtbase-common-devel
libqt5-qtbase-private-headers-devel
libqt5-qtimageformats-devel
libQt5Core-private-headers-devel
libQt5DesignerComponents5
libxml2-tools
lmdb-devel
make
perl
perl(IO::Socket::SSL)
perl(JSON)
perl(URI)
perl(YAML::LibYAML)
pkgconfig(libattr)
pkgconfig(libical)
pkgconfig(libnm)
pkgconfig(libpng)
pkgconfig(libqrencode)
pkgconfig(libudev)
pkgconfig(libxml-2.0)
pkgconfig(libxslt)
pkgconfig(ModemManager)
pkgconfig(openssl)
pkgconfig(Qt5Core)
pkgconfig(Qt5Multimedia)
pkgconfig(Qt5Qml)
pkgconfig(Qt5QuickControls2)
pkgconfig(Qt5Script)
pkgconfig(Qt5Svg)
pkgconfig(Qt5UiTools)
pkgconfig(Qt5WebKit)
pkgconfig(Qt5WebKitWidgets)
pkgconfig(Qt5X11Extras)
pkgconfig(Qt5XmlPatterns)
pkgconfig(sm)
pkgconfig(wayland-server)
pkgconfig(xcb-keysyms)
pkgconfig(xrender)
polkit-devel
shared-mime-info

@@ pkg/fedora/unknown
bison
boost-devel
bzr
cmake
dbusmenu-qt5-devel
docbook-style-xsl
docbook-utils
doxygen
flex
gcc
gcc-c++
gettext
gettext-devel
giflib-devel
git
gperf
intltool
libxml2
make
pam-devel
perl(IO::Socket::SSL)
perl(IPC::Cmd)
perl(JSON::PP)
perl(URI)
perl(YAML::LibYAML)
pkgconfig(dbus-1)
pkgconfig(gbm)
pkgconfig(gl)
pkgconfig(gstreamer-1.0)
pkgconfig(libassuan)
pkgconfig(libattr)
pkgconfig(libnm)
pkgconfig(libpng)
pkgconfig(libqrencode)
pkgconfig(libxml-2.0)
pkgconfig(libxslt)
pkgconfig(lmdb)
pkgconfig(ModemManager)
pkgconfig(openssl)
pkgconfig(polkit-gobject-1)
pkgconfig(sm)
pkgconfig(wayland-client)
pkgconfig(wayland-protocols)
pkgconfig(xapian-core)
pkgconfig(xcb-cursor)
pkgconfig(xcb-ewmh)
pkgconfig(xcb-keysyms)
pkgconfig(xcb-util)
pkgconfig(xfixes)
pkgconfig(xrender)
python
shared-mime-info
texinfo
systemd-devel

@@ pkg/mageia/unknown
bison
boost
cmake
docbook-style-xsl
docbook-utils
flex
gcc
gcc-c++
gettext
gettext-devel
giflib
git
gperf
intltool
lib64lmdb-devel
libdbusmenu-qt5-devel
make
perl(IO::Socket::SSL)
perl(IPC::Cmd)
perl(JSON::PP)
perl(URI)
perl(YAML::LibYAML)
pkgconfig(dbus-1)
pkgconfig(gl)
pkgconfig(gstreamer-1.0)
pkgconfig(libattr)
pkgconfig(libnm)
pkgconfig(libpng)
pkgconfig(libqrencode)
pkgconfig(libxml-2.0)
pkgconfig(libxslt)
pkgconfig(ModemManager)
pkgconfig(openssl)
pkgconfig(polkit-gobject-1)
pkgconfig(sm)
pkgconfig(wayland-client)
pkgconfig(xcb-keysyms)
pkgconfig(xrender)
python
shared-mime-info


@@ pkg/gentoo/unknown
dev-util/cmake
dev-lang/perl
dev-libs/libdbusmenu-qt

@@ pkg/arch/unknown
perl-json perl-yaml-libyaml perl-io-socket-ssl
cmake gcc make qt5-base
doxygen
boost
intltool
gperf
docbook-xsl
flex
bison
bzr
automake
autoconf
pkg-config
wayland-protocols
clang
ninja
meson
qrencode
signond
libaccounts-qt
libdbusmenu-qt5
xapian-core
qgpgme
poppler-qt5
kdsoap
xsd
xerces-c
qt5-webkit
vlc
ruby-sass
eigen
mlt
freecell-solver

@@ pkg/alpine/unknown
alpine-sdk
attr-dev
autoconf
automake
bison
boost-dev
cmake
doxygen
eudev-dev
flex
giflib-dev
gperf
gpgme-dev
grantlee-dev
gstreamer-dev
gst-plugins-base-dev
libdbusmenu-qt-dev
libdmtx-dev
libepoxy-dev
libgcrypt-dev
libinput-dev
libqrencode-dev
libxkbfile-dev
libxrender-dev
libxtst-dev
linux-pam-dev
lmdb-dev
networkmanager-dev
perl
perl-io-socket-ssl
perl-uri
perl-yaml-libyaml
polkit-elogind-dev
qt5-qtbase-dev
qt5-qtdeclarative-dev
qt5-qtquickcontrols2-dev
qt5-qtscript-dev
qt5-qtsensors-dev
qt5-qtsvg-dev
qt5-qttools-dev
qt5-qttools-static
qt5-qtwayland-dev
qt5-qtx11extras-dev
texinfo
wayland-protocols
xapian-core-dev
xcb-util-cursor-dev
xcb-util-image-dev
xcb-util-keysyms-dev
xcb-util-wm-dev

@@ cmd/install/debian/unknown
apt-get -q -y --no-install-recommends install

@@ cmd/install/opensuse/unknown
zypper install -y --no-recommends

@@ cmd/install/arch/unknown
pacman -Syu --noconfirm --needed

@@ cmd/install/fedora/unknown
dnf -y install

@@ cmd/install/alpine/unknown
apk add

@@ sample-rc
# This file controls options to apply when configuring/building modules, and
# controls which modules are built in the first place.
# List of all options: https://go.kde.org/u/ksboptions

global
    # Paths

    kdedir ~/kde/usr # Where to install KF5-based software
#   qtdir  ~/kde/qt5 # Where to install Qt5 if kdesrc-build supplies it

    source-dir ~/kde/src   # Where sources are downloaded
    build-dir  ~/kde/build # Where the source build is run

    ignore-kde-structure true # Use flat structure

    # Will pull in KDE-based dependencies only, to save you the trouble of
    # listing them all below
    include-dependencies true

    cmake-options -DCMAKE_BUILD_TYPE=RelWithDebInfo

    # kdesrc-build sets 2 options which you can use in options like make-options or set-env
    # to help manage the number of compile jobs that # happen during a build:
    #
    # 1. num-cores, which is just the number of detected CPU cores, and can be passed
    #    to tools like make (needed for parallel build) or ninja (completely optional).
    #
    # 2. num-cores-low-mem, which is set to largest value that appears safe for
    #    particularly heavyweight modules based on total memory, intended for
    #    modules like qtwebengine
    num-cores %{num_cores}
    num-cores-low-mem %{num_cores_low}

    make-options  -j ${num-cores}
end global

# With base options set, the remainder of the file is used to define modules to build, in the
# desired order, and set any module-specific options.
#
# Modules may be grouped into sets, and this is the normal practice.
#
# You can include other files inline using the "include" command. We do this here
# to include files which are updated with kdesrc-build.

# Qt and some Qt-using middleware libraries. Uncomment if your distribution's Qt
# tools are too old but be warned that Qt take a long time to build!
#include %{base_dir}/qt5-build-include
#include %{base_dir}/custom-qt5-libs-build-include

# KF5 and Plasma :)
include %{base_dir}/kf5-qt5-build-include

# To change options for modules that have already been defined, use an
# 'options' block. See qt5-build-include for an example
