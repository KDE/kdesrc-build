package ksb::FirstRun 0.10;

use ksb;

# Only include Perl core modules that are likely to always be present in
# a distro's base Perl install.
use File::Spec qw(splitpath);
use List::Util qw(min max first);
use File::Path qw(make_path);

# We can only rely on modules specifically designed to be used from FirstRun
# to avoid problems with importing Perl modules that might not be available
# on minimal containerized distros.
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

use constant {
    # Used for all sh-compatible shells
    BASE_SHELL_SNIPPET => <<'RC',
# kdesrc-build #################################################################

## Add kdesrc-build to PATH
export PATH="$HOME/kde/src/kdesrc-build:$PATH"

RC

    # Used for bash/zsh and requires non-POSIX syntax support. Use this in
    # addition to the base above.
    EXT_SHELL_RC_SNIPPET => <<'RC',
## Autocomplete for kdesrc-run
function _comp_kdesrc_run
{
  local cur
  COMPREPLY=()
  cur="${COMP_WORDS[COMP_CWORD]}"

  # Complete only the first argument
  if [[ $COMP_CWORD != 1 ]]; then
    return 0
  fi

  # Retrieve build modules through kdesrc-run
  # If the exit status indicates failure, set the wordlist empty to avoid
  # unrelated messages.
  local modules
  if ! modules=$(kdesrc-run --list-installed);
  then
      modules=""
  fi

  # Return completions that match the current word
  COMPREPLY=( $(compgen -W "${modules}" -- "$cur") )

  return 0
}

## Register autocomplete function
complete -o nospace -F _comp_kdesrc_run kdesrc-run

################################################################################
RC

  BASE_FISHSHELL_SNIPPET => <<'RC'
# kdesrc-build #################################################################

## Add kdesrc-build to PATH
set -x PATH $HOME/kde/src/kdesrc-build $PATH

RC
};

=head1 FUNCTIONS

=cut

sub yesNoPrompt {
    my $msg = shift;

    local $| = 1;
    print "$msg (y/N) ";
    chomp(my $answer = <STDIN>);
    return lc($answer) eq 'y';
}

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

=head2 suggestedNumCoresForLowMemory

Returns the suggested number of cores to use for make jobs for build jobs where
memory is a bottleneck, such as qtwebengine.

    my $num_cores = ksb::FirstRun::suggestedNumCoresForLowMemory();

=cut

sub suggestedNumCoresForLowMemory
{
    # Try to detect the amount of total memory for a corresponding option for
    # heavyweight modules
    my $os = ksb::OSSupport->new;

    # 4 GiB is assumed if no info on memory is available, as this will
    # calculate to 2 cores.
    my $mem_total = eval { $os->detectTotalMemory } // (4 * 1024 * 1024);

    my $rounded_mem = int sprintf("%.0f", $mem_total / 1024000.0);
    return max(1, int $rounded_mem / 2); # Assume 2 GiB per core
}

# Return the highest number of cores we can use based on available memory, but
# without exceeding the base number of cores available.
sub _getNumCoresForLowMemory($num_cores)
{
    return min(suggestedNumCoresForLowMemory(), $num_cores);
}

sub _setupBaseConfiguration
{
    my $baseDir = shift;
    my $packagesRef = _readPackages();

    # According to XDG spec, if $XDG_CONFIG_HOME is not set, then we should
    # default to ~/.config
    my $xdgConfigHome = $ENV{XDG_CONFIG_HOME} // "$ENV{HOME}/.config";
    my $xdgConfigHomeShort = $xdgConfigHome =~ s/^$ENV{HOME}/~/r; # Replace $HOME with ~
    my @knownLocations = ("$ENV{PWD}/kdesrc-buildrc",
                          "$xdgConfigHome/kdesrc-buildrc",
                          "$ENV{HOME}/.kdesrc-buildrc");
    my $locatedFile = first { -e $_ } @knownLocations;

    if (defined $locatedFile) {
        my $printableLocatedFile = $locatedFile =~ s/^$ENV{HOME}/~/r;
        print colorize(<<DONE);
 b[*] You already have a configuration file: b[y[$printableLocatedFile]
DONE
        return;
    }

    print colorize(<<DONE);
 b[*] Creating b[sample configuration file]: b[y["$xdgConfigHomeShort/kdesrc-buildrc"]...
DONE

    my $sampleRc = $packagesRef->{'sample-rc'} or
        _throw("Embedded sample file missing!");

    my $os = ksb::OSSupport->new;
    my $numCores;
    if ($os->vendorID eq 'linux') {
        chomp($numCores = `nproc 2>/dev/null`);
    } elsif ($os->vendorID eq 'freebsd') {
        chomp($numCores = `sysctl -n hw.ncpu`);
    }
    $numCores ||= 4;
    my $numCoresLow = _getNumCoresForLowMemory($numCores);

    $sampleRc =~ s/%\{num_cores}/$numCores/g;
    $sampleRc =~ s/%\{num_cores_low}/$numCoresLow/g;
    $sampleRc =~ s/%\{base_dir}/$baseDir/g;

    make_path($xdgConfigHome);

    open my $sampleFh, '>', "$xdgConfigHome/kdesrc-buildrc"
        or _throw("Couldn't open new $xdgConfigHomeShort/kdesrc-buildrc: $!");

    print $sampleFh $sampleRc
        or _throw("Couldn't write to $xdgConfigHomeShort/kdesrc-buildrc: $!");

    close $sampleFh
        or _throw("Error closing $xdgConfigHomeShort/kdesrc-buildrc: $!");
}

sub _setupShellRcFile
{
    my $shellName = shift;
    my $rcFilepath = undef;
    my $printableRcFilepath = undef;
    my $extendedShell = 1;

    if ($shellName eq 'bash') {
        $rcFilepath = "$ENV{'HOME'}/.bashrc";
    } elsif ($shellName eq 'zsh') {
        if (defined $ENV{'ZDOTDIR'}) {
            $rcFilepath = "$ENV{'ZDOTDIR'}/.zshrc";
        } else {
            $rcFilepath = "$ENV{'HOME'}/.zshrc";
        }
    } elsif ($shellName eq 'fish') {
      if (defined($ENV{'XDG_CONFIG_HOME'})) {
        $rcFilepath = "$ENV{'XDG_CONFIG_HOME'}/fish/functions/kdesrc-build.fish";
      } else { 
        $rcFilepath = "$ENV{'HOME'}/.config/fish/functions/kdesrc-build.fish";
      }
    } else {
        $rcFilepath = "$ENV{'HOME'}/.profile";
        say colorize(" y[b[*] Couldn't detect the shell, using $rcFilepath.");
        $extendedShell = 0;
    }

    $printableRcFilepath = $rcFilepath;
    $printableRcFilepath =~ s/^$ENV{HOME}/~/;
    my $addToShell = yesNoPrompt(colorize(" b[*] Update your b[y[$printableRcFilepath]?"));

    if ($addToShell) {
        open(my $rcFh, '>>', $rcFilepath)
            or _throw("Couldn't open $rcFilepath: $!");

        say $rcFh '';

        if ($shellName ne 'fish') {
          say $rcFh BASE_SHELL_SNIPPET;

          say $rcFh EXT_SHELL_RC_SNIPPET
              if $extendedShell;
        } else {
          say $rcFh BASE_FISHSHELL_SNIPPET;
        }

        close($rcFh)
            or _throw("Couldn't save changes to $rcFilepath: $!");

        say colorize(<<DONE);

     - Added b[y[kdesrc-build] directory into PATH
     - Added b[y[kdesrc-run] shell function
 b[*] b[g[Shell rc-file is successfully setup].
DONE
    } else {
        say colorize(<<DONE);

 b[*] You can manually configure your shell rc-file with the snippet below:
DONE
        say BASE_SHELL_SNIPPET;
        say EXT_SHELL_RC_SNIPPET
            if $extendedShell;
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
# This is woefully incomplete and not very useful.
# Perl support
libyaml-libyaml-perl
libio-socket-ssl-perl
libjson-xs-perl
liburi-perl
# Basic build tools
bison
build-essential
cmake
flex
gettext
git
gperf
libssl-dev
intltool
shared-mime-info
# Qt-related
libdbusmenu-qt5-dev
# And others
liblmdb-dev
libsm-dev
libnm-dev
libqrencode-dev
# kdoctools
libxml2-dev
libxslt1-dev

@@ pkg/neon/unknown
# Neon is a lot like Debian, except we know Qt is sufficiently new
# to install Qt dev-tools.
# Perl support
libyaml-libyaml-perl
libio-socket-ssl-perl
libjson-xs-perl
liburi-perl
# Basic build tools
bison
build-essential
cmake
flex
gettext
git
gperf
libssl-dev
intltool
meson
ninja-build
shared-mime-info
clang-format
# Qt-related
qtwayland5-private-dev
libdbusmenu-qt5-dev
libqt5svg5-dev
libqt5waylandclient5-dev
libqt5x11extras5-dev
qtbase5-private-dev
qtdeclarative5-dev
qtmultimedia5-dev
qtquickcontrols2-5-dev
qtscript5-dev
qttools5-dev
qtwayland5-dev-tools
qtxmlpatterns5-dev-tools
# Frameworks dependencies
# .. polkit-qt-1
libpolkit-gobject-1-dev
libpolkit-agent-1-dev
# .. kdoctools
libxml2-dev
libxslt-dev
# .. libksysguard
libnl-3-dev
libnl-route-3-dev
libsensors-dev
# .. kwindowsystem
libwayland-dev
libxcb-icccm4-dev
libxcb-keysyms1-dev
libxcb-res0-dev
libxcb-xfixes0-dev
libxcb-xkb-dev
libxfixes-dev
libxrender-dev
wayland-protocols
# .. kwallet
libgcrypt-dev
libgpgme11-dev
libgpgmepp-dev
# .. kactivities
libboost-dev
# .. kfilemetadata
libattr1-dev
# .. kidletime
libxcb-sync-dev
libx11-xcb-dev
# .. khtml
libjpeg-dev
libgif-dev
# .. kglobalaccel
libxcb-record0-dev
# .. karchive
liblzma-dev
# .. plasma-workspace
libqalculate-dev
libxft-dev
libxtst-dev
# And others
qt5keychain-dev
libopenal-dev
libopenjp2-7-dev
qtlocation5-dev
libraw-dev
libsane-dev
libsndfile1-dev
libxcb-glx0-dev
liblmdb-dev
libsm-dev
libnm-dev
libqrencode-dev
# .. optional discover backends
libjcat-dev
libfwupd-dev
libsnapd-qt-dev
libflatpak-dev
# kwin
libgbm-dev
libdrm-dev
libxcvt-dev
libxcb-randr0-dev
libepoxy-dev
libxcb-composite0-dev
libxcb-shm0-dev
libxcb-cursor-dev
libxcb-damage0-dev
libxcb-image0-dev
libxcb-util-dev
# plasma
libqalculate-dev
libxcb-randr0-dev
libxft-dev
libxtst-dev
# powerdevil
libxcb-dpms0-dev

@@ pkg/opensuse/unknown
cmake
clang
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
libopenssl-devel
libqt5-qtbase-common-devel
libqt5-qtbase-private-headers-devel
libqt5-qtimageformats-devel
libQt5Core-private-headers-devel
libQt5DesignerComponents5
libxml2-tools
lmdb-devel
make
openssl
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
pkgconfig(Qt5Core)
pkgconfig(Qt5Multimedia)
pkgconfig(Qt5Qml)
pkgconfig(Qt5QuickControls2)
pkgconfig(Qt5Script)
pkgconfig(Qt5Svg)
pkgconfig(Qt5UiTools)
pkgconfig(Qt5WaylandClient)
pkgconfig(Qt5X11Extras)
pkgconfig(Qt5XmlPatterns)
pkgconfig(sm)
pkgconfig(wayland-protocols)
pkgconfig(wayland-server)
pkgconfig(xcb-cursor)
pkgconfig(xcb-ewmh)
pkgconfig(xcb-keysyms)
pkgconfig(xcb-util)
pkgconfig(xrender)
polkit-devel
shared-mime-info
libXfixes-devel

@@ pkg/fedora/unknown
bison
boost-devel
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
meson
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
qt5-qtbase-devel

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
sys-devel/clang

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
vlc
ruby-sass
eigen
mlt
freecell-solver
sane
qt5-script

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
libcanberra-dev
libdbusmenu-qt-dev
libdmtx-dev
libepoxy-dev
libgcrypt-dev
libical-dev
libinput-dev
libnl3-dev
libqalculate-dev
libqrencode-dev
libsecret-dev
libxkbfile-dev
libxrender-dev
libxslt-dev
libxtst-dev
linux-pam-dev
lm-sensors-dev
lmdb-dev
networkmanager-dev
openjpeg-dev
perl
perl-io-socket-ssl
perl-uri
perl-yaml-libyaml
polkit-elogind-dev
pulseaudio-dev
py3-sphinx
qt5-qtbase-dev
qt5-qtdeclarative-dev
qt5-qtquickcontrols2-dev
qt5-qtmultimedia-dev
qt5-qtscript-dev
qt5-qtsensors-dev
qt5-qtsvg-dev
qt5-qttools-dev
qt5-qtwayland-dev
qt5-qtx11extras-dev
texinfo
wayland-protocols
xapian-core-dev
xcb-util-cursor-dev
xcb-util-image-dev
xcb-util-keysyms-dev
xcb-util-wm-dev

@@ pkg/freebsd/unknown
bison
boost-all
cmake
docbook-xsl
doxygen
eigen
gettext
gmake
gperf
gpgme
intltool
libqrencode
lmdb
mlt7
ninja
p5-YAML-PP
pkgconf
qt5
qt5-wayland
wayland-protocols
xorg

@@ cmd/install/freebsd/unknown
pkg install -y

@@ cmd/install/debian/unknown
apt-get -q -y --no-install-recommends install

@@ cmd/install/opensuse/unknown
zypper install -y --no-recommends

@@ cmd/install/arch/unknown
pacman -Syu --noconfirm --needed

@@ cmd/install/fedora/unknown
dnf -y install

@@ cmd/install/alpine/unknown
apk add --virtual .makedeps-kdesrc-build

@@ sample-rc
# This file controls options to apply when configuring/building modules, and
# controls which modules are built in the first place.
# List of all options: https://docs.kde.org/trunk5/en/kdesrc-build/kdesrc-build/conf-options-table.html

global

    # Finds and includes *KDE*-based dependencies into the build.  This makes
    # it easier to ensure that you have all the modules needed, but the
    # dependencies are not very fine-grained so this can result in quite a few
    # modules being installed that you didn't need.
    include-dependencies true

    # Install directory for KDE software
    kdedir ~/kde/usr

    # Directory for downloaded source code
    source-dir ~/kde/src

    # Directory to build KDE into before installing
    # relative to source-dir by default
    build-dir ~/kde/build

#   qtdir  ~/kde/qt5 # Where to install Qt5 if kdesrc-build supplies it

    cmake-options -DCMAKE_BUILD_TYPE=RelWithDebInfo

    # kdesrc-build sets 2 options which is used in options like make-options or set-env
    # to help manage the number of compile jobs that happen during a build:
    #
    # 1. num-cores, which is just the number of detected CPU cores, and can be passed
    #    to tools like make (needed for parallel build) or ninja (completely optional).
    #
    # 2. num-cores-low-mem, which is set to largest value that appears safe for
    #    particularly heavyweight modules based on total memory, intended for
    #    modules like qtwebengine
    num-cores %{num_cores}
    num-cores-low-mem %{num_cores_low}

    # kdesrc-build can install a sample .xsession file for "Custom"
    # (or "XSession") logins,
    install-session-driver false

    # or add a environment variable-setting script to
    # ~/.config/kde-env-master.sh
    install-environment-driver true

    # Stop the build process on the first failure
    stop-on-failure true

    # Use a flat folder layout under ~/kde/src and ~/kde/build
    # rather than nested directories
    directory-layout flat

    # Build with LSP support for everything that supports it
    compile-commands-linking true
    compile-commands-export true
end global

# With base options set, the remainder of the file is used to define modules to build, in the
# desired order, and set any module-specific options.
#
# Modules may be grouped into sets, and this is the normal practice.
#
# You can include other files inline using the "include" command. We do this here
# to include files which are updated with kdesrc-build.

# Common options that should be set for some KDE modules no matter how
# kdesrc-build finds them. Do not comment these out unless you know
# what you are doing.
include %{base_dir}/kf5-common-options-build-include

# Qt and some Qt-using middleware libraries. Uncomment if your distribution's Qt
# tools are too old but be warned that Qt take a long time to build!
#include %{base_dir}/qt5-build-include
#include %{base_dir}/custom-qt5-libs-build-include

# KF5 and Plasma :)
include %{base_dir}/kf5-qt5-build-include

# To change options for modules that have already been defined, use an
# 'options' block. See kf5-common-options-build-include for an example
