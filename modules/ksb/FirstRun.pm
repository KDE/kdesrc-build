package ksb::FirstRun 0.10;

use 5.014;
use strict;
use warnings;
use File::Spec qw(splitpath);

use ksb::BuildException;
use ksb::Debug qw(colorize);
use ksb::OSSupport;

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

sub setupUserSystem
{
    my $baseDir = shift;
    my $os = ksb::OSSupport->new;

    eval {
        _installSystemPackages($os);
        _setupBaseConfiguration($baseDir);
        _setupBashrcFile();
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
 b[1.] Installing b[system packages] for b[$vendor]...
DONE

    my @packages = _findBestVendorPackageList($os);
    if (@packages) {
        my @installCmd = _findBestInstallCmd($os);
        say colorize (" b[*] Running b[" . join(' ', @installCmd) . "]");
        my $result = system (@installCmd, @packages);
        if ($result >> 8 == 0) {
            say colorize (" b[*] b[g[Looks like things went OK!]");
        } else {
            say colorize (" r[b[*] Ran into an error with the installer!");
        }
    } else {
        say colorize (" r[b[*] Whoa, I'm not familiar with your distribution, skipping");
    }
}

sub _setupBaseConfiguration
{
    my $baseDir = shift;

    if (-e "kdesrc-buildrc" || -e "$ENV{HOME}/.kdesrc-buildrc") {
        print colorize(<<DONE);
 b[2.] You b[y[already have a configuration file], skipping this step...
DONE
    } else {
        print colorize(<<DONE);
 b[2.] Installing b[sample configuration file]...
DONE

        my $sampleRc = $packages{'sample-rc'} or
            _throw("Embedded sample file missing!");

        my $numCpus = `nproc 2>/dev/null` || 4;
        $sampleRc =~ s/%\{num_cpus}/$numCpus/g;
        $sampleRc =~ s/%\{base_dir}/$baseDir/g;

        open my $sampleFh, '>', "$ENV{HOME}/.kdesrc-buildrc"
            or _throw("Couldn't open new ~/.kdesrc-buildrc: $!");

        print $sampleFh $sampleRc
            or _throw("Couldn't write to ~/.kdesrc-buildrc: $!");

        close $sampleFh
            or _throw("Error closing ~/.kdesrc-buildrc: $!");
    }
}

sub _bashrcIsSetup
{
    return 1;
}

sub _setupBashrcFile
{
    if (_bashrcIsSetup()) {
        say colorize(<<DONE);
 b[3.] Your b[y[~/.bashrc is already setup], skipping this step...
DONE
    } else {
        say colorize(<<DONE);
 b[3.] Amending your ~/.bashrc to b[also point to install dir]...
DONE
        sleep 3;
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
liburi-perl gettext

@@ pkg/opensuse/unknown
perl perl-IO-Socket-SSL perl-JSON perl-YAML-LibYAML
git shared-mime-info make cmake libqt5-qtbase-common-devel libopenssl-devel intltool
polkit-devel
libqt5-qtbase-devel libqt5-qtimageformats-devel libqt5-qtmultimedia-devel libqt5-qtdeclarative-devel libqt5-qtx11extras-devel libqt5-qtxmlpatterns-devel libqt5-qtsvg-devel
gperf
gettext-runtime gettext-tools
libxml2-devel libxml2-tools libxslt-devel docbook-xsl-stylesheets docbook_4
perl-URI
libXrender-devel xcb-util-keysyms-devel
flex bison
libQt5Core-private-headers-devel
libudev-devel
libQt5WebKit5-devel libQt5WebKitWidgets-devel
libQt5DesignerComponents5 libqt5-qttools-devel libSM-devel
libattr-devel
libboost_headers1_66_0-devel
libQt5QuickControls2-devel
libqt5-qtscript-devel
wayland-devel
libqt5-qtbase-private-headers-devel
lmdb-devel
libpng16-compat-devel giflib-devel
ModemManager-devel
# This pulls in so many other packages! :(
NetworkManager-devel
qrencode-devel

@@ pkg/fedora/unknown
perl-IO-Socket-SSL perl-JSON-PP perl-YAML-LibYAML perl-IPC-Cmd
git shared-mime-info make cmake openssl-devel intltool
gcc gcc-c++ python
mesa-libGL-devel dbus-devel gstreamer1-devel
polkit-devel
gperf
gettext gettext-devel
libxml2-devel libxml2 libxslt-devel docbook-style-xsl docbook-utils
perl-URI
libXrender-devel xcb-util-keysyms-devel
flex bison
libSM-devel
libattr-devel
boost
wayland-devel
lmdb-devel
libpng-devel giflib-devel
ModemManager-devel
# This pulls in so many other packages! :(
NetworkManager-libnm-devel
qrencode-devel

@@ pkg/mageia/unknown
perl-IO-Socket-SSL perl-JSON-PP perl-YAML-LibYAML perl-IPC-Cmd
git shared-mime-info make cmake openssl-devel intltool
gcc gcc-c++ python
libgl-devel dbus-devel gstreamer1.0-devel
polkit-devel
gperf
gettext gettext-devel
libxml2-devel libxml2 libxslt-devel docbook-style-xsl docbook-utils
perl-URI
libxrender-devel xcb-util-keysyms-devel
flex bison
libsm-devel
libattr-devel
boost
wayland-devel
lmdb-devel
libpng-devel giflib-devel
modemmanager-devel
# This pulls in so many other packages! :(
libnm-devel
qrencode-devel


@@ pkg/gentoo/unknown
dev-util/cmake
dev-lang/perl

@@ pkg/arch/unknown
perl-json perl-yaml-libyaml perl-io-socket-ssl
cmake gcc make qt5-base

@@ cmd/install/debian/unknown
apt-get -q -y --no-install-recommends install

@@ cmd/install/opensuse/unknown
zypper install -y --no-recommends

@@ cmd/install/arch/unknown
pacman -Sy --noconfirm --needed

@@ cmd/install/fedora/unknown
dnf -y install

@@ sample-rc
# This file controls options to apply when configuring/building modules, and
# controls which modules are built in the first place.
# List of all options: https://go.kde.org/u/ksboptions

global
    # Paths

    kdedir ~/kde/usr # Where to install KF5-based software
    qtdir  ~/kde/qt5 # Where to find Qt5

    source-dir ~/kde/src   # Where sources are downloaded
    build-dir  ~/kde/build # Where the source build is run

    ignore-kde-structure true # Use flat structure

    # Will pull in KDE-based dependencies only, to save you the trouble of
    # listing them all below
    include-dependencies true

    cmake-options -DCMAKE_BUILD_TYPE=RelWithDebInfo
    make-options  -j%{num_cpus}
end global

# With base options set, the remainder of the file is used to define modules to build, in the
# desired order, and set any module-specific options.
#
# Modules may be grouped into sets, and this is the normal practice.
#
# You can include other files inline using the "include" command. We do this here
# to include files which are updated with kdesrc-build.

# Qt and some Qt-using middleware libraries
include %{base_dir}/qt5-build-include
include %{base_dir}/custom-qt5-libs-build-include

# KF5 and Plasma :)
include %{base_dir}/kf5-qt5-build-include

# To change options for modules that have already been defined, use an
# 'options' block
options kcoreaddons
    make-options -j4
end options
