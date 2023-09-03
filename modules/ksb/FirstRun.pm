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
use ksb::Util qw(locate_exe);

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
        _setupShellRcFile($shellName, $baseDir);
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
    if (!@packages) {
        say colorize (" r[b[*] Packages could not be installed, because kdesrc-build does not know your distribution (" . $vendor .")");
        return;
    }

    local $, = ' '; # string to use when joining arrays in a string

    my @installCmd = _findBestInstallCmd($os);
    say colorize (" b[*] Running 'b[@installCmd @packages]'");
    my $result = system (@installCmd, @packages);
    my $exitStatus = $result >> 8;

    # Install one at a time if we can, but check if sudo is present
    my $hasSudo = defined locate_exe('sudo');
    if (($exitStatus != 0) && ($os->isDebianBased) && $hasSudo) {
        my $everFailed = 0;
        foreach my $onePackage (@packages) {
            my @commandLine = (qw(sudo apt-get -q -y --no-install-recommends install), $onePackage);
            say colorize (" b[*] Running 'b[@commandLine]'");
            # Allow for Ctrl+C.
            select(undef, undef, undef, 0.25);
            system(@commandLine);
            $everFailed ||= ($result >> 8) != 0;
        }

        $exitStatus = 0; # It is normal if some packages are not available.
        if ($everFailed) {
            say colorize (" y[b[*] Some packages failed to install, continuing to build.");
        }
    }

    if ($exitStatus == 0) {
        say colorize (" b[*] b[g[Looks like the necessary packages were successfully installed!]");
    } else {
        say colorize (" r[b[*] Failed with exit status $exitStatus. Ran into an error with the installer!");
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
    my ($shellName, $baseDir) = @_;
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
          say $rcFh BASE_SHELL_SNIPPET . "export PATH=\"$baseDir:\$PATH\"\n";

          say $rcFh EXT_SHELL_RC_SNIPPET
              if $extendedShell;
        } else {
          say $rcFh BASE_FISHSHELL_SNIPPET . "set -x PATH $baseDir \$PATH\n";
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
        say BASE_SHELL_SNIPPET . "export PATH=\"$baseDir:\$PATH\"\n";
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
apt-file
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
packagekit
# Frameworks dependencies
# .. polkit-qt-1
libpolkit-gobject-1-dev
libpolkit-agent-1-dev
# .. kdoctools
libxml2-dev
libxml2-utils
libxslt-dev
docbook
docbook-xsl
docbook-xml
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
libxcb-xtest0-dev
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
# .. kcalendarcore
libical-dev
# .. khtml
libjpeg-dev
libgif-dev
# .. kjs
libpcre3-dev
# .. kglobalaccel
libxcb-record0-dev
# .. knotifications
libcanberra-dev
# .. karchive
liblzma-dev
# .. plasma-workspace
libqalculate-dev
libxft-dev
libxtst-dev
libappstreamqt-dev
libpackagekitqt5-dev
libxcursor-dev
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
libxcb-present-dev
libxcb-xinerama0-dev
libxkbcommon-x11-dev
# plasma
libqalculate-dev
libxcb-randr0-dev
libxft-dev
libxtst-dev
# powerdevil
libxcb-dpms0-dev
# plasma-nm
libnm-dev
modemmanager-dev
# plasma-pa
libpulse-dev
# plymouth-kcm
libplymouth-dev
# kscreenlocker
libpam0g-dev
# kpipewire
libpipewire-0.3-dev
libavcodec-dev
libavformat-dev
libswscale-dev
# libkexiv2
libexiv2-dev

@@ pkg/opensuse/unknown
bison
clang
cmake
cmake(packagekitqt5)
cmake(packagekitqt6)
cmake(Qt5Core)
cmake(Qt5Multimedia)
cmake(Qt5Qml)
cmake(Qt5QuickControls2)
cmake(Qt5QuickTemplates2)
cmake(Qt5Script)
cmake(Qt5Sensors)
cmake(Qt5Svg)
cmake(Qt5UiTools)
cmake(Qt5WaylandClient)
cmake(Qt5WebEngine)
cmake(Qt5WebView)
cmake(Qt5X11Extras)
cmake(Qt5XmlPatterns)
cmake(Qt6Concurrent)
cmake(Qt6Core)
cmake(Qt6Core5Compat)
cmake(Qt6DBus)
cmake(Qt6Gui)
cmake(Qt6LinguistTools)
cmake(Qt6Multimedia)
cmake(Qt6Network)
cmake(Qt6PrintSupport)
cmake(Qt6Qml)
cmake(Qt6Quick)
cmake(Qt6QuickControls2)
cmake(Qt6QuickTemplates2)
cmake(Qt6QuickTest)
cmake(Qt6QuickWidgets)
cmake(Qt6Sensors)
cmake(Qt6ShaderTools)
cmake(Qt6Sql)
cmake(Qt6Svg)
cmake(Qt6Test)
cmake(Qt6ToolsTools)
cmake(Qt6UiTools)
cmake(Qt6WaylandClient)
cmake(Qt6WaylandCompositor)
cmake(Qt6WebSockets)
cmake(Qt6Widgets)
docbook-xsl-stylesheets
docbook_4
doxygen
flex
gettext-runtime
gettext-tools
giflib-devel
git
gperf
graphviz
gtk-doc
gtk3-devel
intltool
itstool
libAppStreamQt-devel
libboost_headers-devel
libdbusmenu-qt5-devel
libdisplay-info-devel
libepub-devel
libqt5-qtbase-common-devel
libqt5-qtbase-private-headers-devel
libqt5-qtimageformats-devel
libqt5-qtwayland-private-headers-devel
libQt5Core-private-headers-devel
libQt5DesignerComponents5
libsensors4-devel
libxml2-tools
lmdb-devel
make
meson
ninja
olm-devel
openjpeg2-devel
perl
perl(IO::Socket::SSL)
perl(JSON)
perl(URI)
perl(YAML::LibYAML)
pkgconfig(accounts-qt5)
pkgconfig(epoxy)
pkgconfig(exiv2)
pkgconfig(gbm)
pkgconfig(gobject-introspection-1.0)
pkgconfig(libattr)
pkgconfig(libavcodec)
pkgconfig(libavfilter)
pkgconfig(libavformat)
pkgconfig(libcanberra)
pkgconfig(libcec)
pkgconfig(libevdev)
pkgconfig(libfakekey)
pkgconfig(libical)
pkgconfig(libnl-3.0)
pkgconfig(libnm)
pkgconfig(libopenssl)
pkgconfig(libpcre)
pkgconfig(libpipewire-0.3)
pkgconfig(libpng)
pkgconfig(libqalculate)
pkgconfig(libqrencode)
pkgconfig(libsignon-qt5)
pkgconfig(libswscale)
pkgconfig(libudev)
pkgconfig(libva)
pkgconfig(libxcvt)
pkgconfig(libxml-2.0)
pkgconfig(libxslt)
pkgconfig(ModemManager)
pkgconfig(pam)
pkgconfig(sm)
pkgconfig(wayland-protocols)
pkgconfig(wayland-server)
pkgconfig(xcb-cursor)
pkgconfig(xcb-ewmh)
pkgconfig(xcb-keysyms)
pkgconfig(xcb-util)
pkgconfig(xcursor)
pkgconfig(xfixes)
pkgconfig(xft)
pkgconfig(xkbfile)
pkgconfig(xorg-evdev)
pkgconfig(xorg-libinput)
pkgconfig(xorg-server)
pkgconfig(xorg-synaptics)
pkgconfig(xrender)
pkgconfig(xtst)
pkgconfig(xxf86vm)
pkgconfig(yaml-0.1)
plymouth-devel
polkit-devel
qcoro-qt5-devel
qt6-core-private-devel
qt6-gui-private-devel
qt6-printsupport-private-devel
qt6-quick-private-devel
qt6-waylandclient-private-devel
shared-mime-info
snowball-devel
vlc-devel

@@ pkg/fedora/unknown
appstream-qt-devel
aha
bison
boost-devel
bzip2
cfitsio-devel
chmlib-devel
cmake
cyrus-sasl-devel
dbusmenu-qt5-devel
djvulibre-devel
docbook-style-xsl
docbook-utils
doxygen
ebook-tools-devel
eigen3-devel
erfa-devel
exiv2-devel
flex
fuse3-devel
fuse-devel
gcc
gcc-c++
gettext
gettext-devel
giflib-devel
git
glew-devel
gobject-introspection-devel
gperf
gpgmepp-devel
gsl-devel
gstreamer1-plugins-base-devel
ibus-devel
intltool
itstool
json-c-devel
kcolorpicker-devel
kdsoap-devel
kf5-kdnssd-devel
kf5-kplotting-devel
kf5-libkdcraw-devel
kimageannotator-devel
libaccounts-qt5-devel
libavcodec-free-devel
libavformat-free-devel
libavutil-free-devel
libblack-hole-solver-devel
libcanberra-devel
libepoxy-devel
libfreecell-solver-devel
libgcrypt-devel
libgit2-devel
libical-devel
libindi-devel
libjpeg-turbo-devel
libpcap-devel
libqalculate-devel
libmtp-devel
libnl3-devel
libnova-devel
LibRaw-devel
libsass-devel
libsmbclient-devel
libsndfile-devel
libsodium-devel
libspectre-devel
libswscale-free-devel
libssh-devel
libtirpc-devel
libuuid-devel
libwacom-devel
libXcursor-devel
libXft-devel
libxcvt-devel
libXext-devel
libXtst-devel
libxkbcommon-devel
libxkbcommon-x11-devel
libxml2
libzip-devel
lm_sensors-devel
make
meson
mpv-libs-devel
openal-soft-devel
openexr-devel
openjpeg2-devel
pam-devel
pcre-devel
perl(Digest::SHA)
perl(FindBin)
perl(IO::Compress::Gzip)
perl(IO::Socket::SSL)
perl(IPC::Cmd)
perl(JSON::PP)
perl(URI)
perl(YAML::LibYAML)
phonon-qt5-devel
pipewire-devel
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
python3-psutil
python3-sphinx
qaccessibilityclient-devel
qcoro-qt5-devel
qgpgme-devel
plymouth-devel
qt5-*-devel
qt5-qtbase-static
qt5-qttools-static
qt6-*-devel
qtkeychain-qt5-devel
PackageKit
SDL2-devel
shared-mime-info
signon-devel
stellarsolver-devel
systemd-devel
texinfo
wcslib-devel
xmlto
xorg-x11-drv-wacom-devel
xkeyboard-config

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
dev-lang/perl
dev-libs/icu
dev-libs/libdbusmenu-qt
dev-perl/IO-Socket-SSL
dev-perl/YAML-PP
dev-perl/YAML-Syck
dev-qt/designer:5
dev-qt/linguist-tools:5
dev-qt/linguist
dev-qt/pixeltool
dev-qt/qdoc:5
dev-qt/qtconcurrent:5
dev-qt/qtcore:5
dev-qt/qtdbus:5
dev-qt/qtdeclarative:5
dev-qt/qtdiag:5
dev-qt/qtgui:5
dev-qt/qthelp:5
dev-qt/qtmultimedia:5
dev-qt/qtnetwork:5
dev-qt/qtpaths:5
dev-qt/qtprintsupport:5
dev-qt/qtquickcontrols:5
dev-qt/qtsql:5
dev-qt/qttest:5
dev-qt/qtwidgets:5
dev-qt/qtx11extras:5
dev-qt/qtxml:5
dev-util/cmake
dev-util/gperf
dev-util/meson
dev-util/ninja
dev-vcs/git
sys-devel/clang
virtual/libintl

@@ pkg/arch/unknown
# Perl support
perl-json
perl-yaml-libyaml
perl-io-socket-ssl
perl-libwww
perl-xml-parser
perl-yaml-syck
# Basic build tools
# .. gnu
autoconf
automake
bison
flex
gcc
gperf
make
kdesdk
# .. llvm
clang
cmake
# .. build systems
ninja
meson
# .. rust
corrosion
# .. others
boost
docbook-xsl
doxygen
intltool
pkg-config
git
bzr
# Qt-related
qt5-base
qt5-script
qt5-websockets
qt5-svg
qt5-tools
qt5-x11extras
qca-qt5
libaccounts-qt
libdbusmenu-qt5
poppler-qt5
qtkeychain-qt5
phonon-qt5
packagekit
# Others/Unsorted
wayland-protocols
qrencode
signond
xapian-core
qgpgme
kdsoap
xsd
xerces-c
vlc
ruby-sass
eigen
mlt
freecell-solver
sane
vala
check
libolm
xmlto
itstool
libdisplay-info
python-sphinx
enchant
jasper
openexr
libutempter
docbook-xsl
shared-mime-info
giflib
libxss
upower
udisks2
xorg-server-devel
libpwquality
libfakekey
eigen
xapian-core
libdmtx
ruby-test-unit
plymouth
# appstream
gobject-introspection
xf86-input-evdev
python-chai

@@ pkg/alpine/unknown
alpine-sdk
attr-dev
autoconf
automake
bison
boost-dev
clang-extra-tools
cmake
curl-dev
cyrus-sasl-dev
doxygen
eudev-dev
exiv2-dev
ffmpeg-dev
flex
giflib-dev
gperf
gpgme-dev
graphviz
grantlee-dev
gst-plugins-base-dev
gstreamer-dev
kdsoap-dev
lcms2-dev
libaccounts-qt-dev
libcanberra-dev
libdbusmenu-qt-dev
libdisplay-info-dev
libdmtx-dev
libepoxy-dev
libgcrypt-dev
libical-dev
libinput-dev
libnl3-dev
libqalculate-dev
libqrencode-dev
libsecret-dev
libva-dev
libxcvt-dev
libxkbfile-dev
libxmlb-dev
libxrender-dev
libxslt-dev
libxtst-dev
linux-pam-dev
lm-sensors-dev
lmdb-dev
meson
modemmanager-dev
mpv-dev
networkmanager-dev
ninja
olm-dev
openjpeg-dev
openldap-dev
pcre-dev
perl
perl-io-socket-ssl
perl-uri
perl-yaml-libyaml
pipewire-dev
polkit-elogind-dev
pulseaudio-dev
py3-sphinx
qca-dev
qcoro-dev
qt5-qtbase-dev
qt5-qtdeclarative-dev
qt5-qtmultimedia-dev
qt5-qtnetworkauth-dev
qt5-qtquickcontrols2-dev
qt5-qtscript-dev
qt5-qtsensors-dev
qt5-qtsvg-dev
qt5-qttools-dev
qt5-qtwayland-dev
qt5-qtx11extras-dev
qt5-qtxmlpatterns-dev
qt6-qt5compat-dev
qt6-qtbase-dev
qt6-qtmultimedia-dev
qt6-qtpositioning-dev
qt6-qtsvg-dev
qt6-qttools-dev
qt6-qtwayland-dev
qt6-qtwebengine-dev
qtkeychain-dev
signond-dev
stb
texinfo
wayland-protocols
xapian-core-dev
xcb-util-cursor-dev
xcb-util-image-dev
xcb-util-keysyms-dev
xcb-util-wm-dev
xkeyboard-config-dev
xmlto
yaml-dev

@@ pkg/freebsd/unknown
automake
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
meson
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

@@ cmd/install/gentoo/unknown
emerge -v --noreplace

@@ sample-rc
# This file controls options to apply when configuring/building modules, and
# controls which modules are built in the first place.
# List of all options: https://docs.kde.org/trunk5/en/kdesrc-build/kdesrc-build/conf-options-table.html

global
    branch-group kf5-qt5

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

    # Use Ninja as cmake generator instead of gmake
    cmake-generator Kate - Ninja

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
