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

=head1 FUNCTIONS

=cut

our $baseDir;

sub setupUserSystem
{
    $baseDir = shift;
    my @setup_steps = @_;
    my $os = ksb::OSSupport->new;

    eval {
        if (grep { $_ eq "install-distro-packages-perl" } @setup_steps) {
            say colorize("=== install-distro-packages-perl ===");
            my $perl_distro_deps_path = "$baseDir/data/perl-dependencies";
            _installSystemPackages($os, $perl_distro_deps_path);
        }
        if (grep { $_ eq "install-distro-packages" } @setup_steps) {
            say colorize("=== install-distro-packages ===");

            # The distro dependencies are listed in sysadmin/repo-metadata repository
            # First, we need to download metadata with Application.

            eval {
                require ksb::Application;  # Do not import in the beginning, because perl packages may not yet be installed.
            };
            if ($@){
                # We get here when even no perl-json-xs is installed. If it is, the other message will be shown.
                say colorize (" r[b[*] r[Could not load Application. Ensure you have run b[--install-distro-packages-perl]r[ first.");
            }

            ksb::Application->new(("--metadata-only", "--metadata-only"));  # invokes _downloadKDEProjectMetadata internally
            # We use a hack to catch exactly this command line to make the app not exit. This way we do not influence the normal behavior, and we
            # do not create a normal instance of Application, because it will create a lockfile.
            # todo remove this hack after moving takeLock to another place before actual work from the Application::new

            my $metadata_distro_deps_path = ($ENV{XDG_STATE_HOME} // "$ENV{HOME}/.local/state") . "/sysadmin-repo-metadata/distro-dependencies";
            _installSystemPackages($os, $metadata_distro_deps_path);
        }
        if (grep { $_ eq "generate-config" } @setup_steps) {
            say colorize("=== generate-config ===");
            eval {
                # We do not require BuildContext in the beginning of FirstRun, because it itself requires some perl dependencies to be installed (for example JSON::XS).
                # We only do this after the install-distro-packages step
                require ksb::BuildContext;
            };
            if ($@) {
                say colorize(" r[b[*] r[Could not load BuildContext. Ensure you have run b[--install-distro-packages]r[ first.");
                die;
            }
            _setupBaseConfiguration();
        }
    };

    if (had_an_exception($@)) {
        my $msg = $@->{message};
        say colorize ("  b[r[*] r[$msg]");
        return 1;
    }

    return 0;
}

# Internal functions

# Reads from the files from data/pkg and dumps the contents in a hash keyed by filename (the "[pkg/vendor/version]" part between each resource).
sub _readPackages
{
    my $vendor = shift;
    my $version = shift;
    my $deps_data_path = shift;

    my %packages;
    open(my $file, '<', "$deps_data_path/$vendor.ini") or _throw("Cannot open file \"$deps_data_path/$vendor.ini\"");
    my $cur_file;
    my $cur_value;
    my $commit = sub {
        return unless $cur_file;
        $packages{$cur_file} = ($cur_value =~ s/ *$//r);
        $cur_value = '';
    };

    while(my $line = <$file>) {
        next if $line =~ /^\s*#/;
        chomp $line;

        my ($fname) = ($line =~ /^\[ *([^ ]+) *\]$/);
        if ($fname) {
            $commit->();
            $cur_file = $fname;
        }
        else {
            $cur_value .= "$line\n";
        }
    }
    close($file);

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
    my $deps_data_path = shift;
    my $vendor = $os->vendorID;
    my $osVersion = $os->vendorVersion;

    print colorize(<<DONE);
 b[-] Installing b[system packages] for b[$vendor]...
DONE

    my @packages = _findBestVendorPackageList($os, $deps_data_path);
    if (!@packages) {
        say colorize (" r[b[*] Packages could not be installed, because kdesrc-build does not know your distribution (" . $vendor .")");
        return;
    }

    local $, = ' '; # string to use when joining arrays in a string

    my @installCmd = _findBestInstallCmd($os);

    # Remake the command for Arch Linux to not require running sudo command when not needed
    if ($vendor eq "arch") {
        my @required_packages_and_required_groups = @packages;
        my @missing_packages_and_required_groups = `pacman -T @required_packages_and_required_groups`;
        chomp(@missing_packages_and_required_groups);
        my @all_possible_groups = `pacman -Sg`;
        chomp(@all_possible_groups);

        my @required_groups;
        foreach my $package_or_group (@missing_packages_and_required_groups) {
            if (grep { $_ eq $package_or_group } @all_possible_groups) {
                push @required_groups, $package_or_group;
            }
        }

        my @missing_packages_not_grouped;
        foreach my $package_or_group (@missing_packages_and_required_groups) {
            if (!grep { $package_or_group eq $_ } @required_groups) {
                push @missing_packages_not_grouped, $package_or_group;
            }
        }

        my @missing_packages_from_required_groups;
        if (@required_groups) {
            for my $required_group (@required_groups) {
                my @missing_packages_from_required_group = `pacman -Sqg $required_group | xargs pacman -T`;
                chomp(@missing_packages_from_required_group);
                push @missing_packages_from_required_groups, (@missing_packages_from_required_group);
            }
        }

        @packages = (@missing_packages_not_grouped, @missing_packages_from_required_groups);
    }

    my $exitStatus;
    my $result;
    if (@packages) {
        say colorize(" b[*] Running 'b[@installCmd @packages]'");
        $result = system(@installCmd, @packages);
        $exitStatus = $result >> 8;
    } else {
        say colorize(" b[*] All dependencies are already installed. No need to run installer. b[:)]");
        $exitStatus = 0;
    }

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

    open(my $file, '<', "$baseDir/data/kdesrc-buildrc.in") or _throw("Embedded sample file missing!");
    my $sampleRc = do { local $/; <$file> };
    close($file);

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

    my $gl = ksb::BuildContext->new()->{"build_options"}->{"global"};  # real global defaults

    my $fill_placeholder = sub {
        my $option_name = shift;
        my $mode = shift;
        $mode //= "";

        my $value = $gl->{$option_name};
        if ($mode eq "bool_to_str") {
            # Perl doesn't have native boolean types, so config internally operates on 0 and 1.
            # But it will be convenient to users to use "true"/"false" strings in their config files.
            $value = ($value ? "true" : "false");
        } elsif ($mode eq "home_to_tilde") {
            $value =~ s|^$ENV{HOME}|~|;
        }
        $sampleRc =~ s/%\{$option_name}/$value/g;
    };

    $fill_placeholder->("include-dependencies", "bool_to_str");
    $fill_placeholder->("install-dir", "home_to_tilde");
    $fill_placeholder->("source-dir", "home_to_tilde");
    $fill_placeholder->("build-dir", "home_to_tilde");
    $fill_placeholder->("install-session-driver", "bool_to_str");
    $fill_placeholder->("install-environment-driver", "bool_to_str");
    $fill_placeholder->("stop-on-failure", "bool_to_str");
    $fill_placeholder->("directory-layout");
    $fill_placeholder->("compile-commands-linking", "bool_to_str");
    $fill_placeholder->("compile-commands-export", "bool_to_str");
    $fill_placeholder->("generate-vscode-project-config", "bool_to_str");

    make_path($xdgConfigHome);

    open my $sampleFh, '>', "$xdgConfigHome/kdesrc-buildrc"
        or _throw("Couldn't open new $xdgConfigHomeShort/kdesrc-buildrc: $!");

    print $sampleFh $sampleRc
        or _throw("Couldn't write to $xdgConfigHomeShort/kdesrc-buildrc: $!");

    close $sampleFh
        or _throw("Error closing $xdgConfigHomeShort/kdesrc-buildrc: $!");
}

sub _findBestInstallCmd
{
    my $os = shift;
    my %cmdsRef =  (
        "cmd/install/alpine/unknown"   => "apk add --virtual .makedeps-kdesrc-build",
        "cmd/install/arch/unknown"     => "pacman -S --noconfirm",
        "cmd/install/debian/unknown"   => "apt-get -q -y --no-install-recommends install",
        "cmd/install/fedora/unknown"   => "dnf -y install",
        "cmd/install/freebsd/unknown"  => "pkg install -y",
        "cmd/install/gentoo/unknown"   => "emerge -v --noreplace",
        "cmd/install/openbsd/unknown"  => "pkg_add",
        "cmd/install/opensuse/unknown" => "zypper install -y --no-recommends",
    );

    my @supportedDistros =
        map  { s{^cmd/install/([^/]+)/.*$}{$1}; $_ }
        grep { /^cmd\/install\// }
            keys %cmdsRef;

    my $bestVendor = $os->bestDistroMatch(@supportedDistros);
    say colorize ("    Using installer for b[$bestVendor]");

    my $version = $os->vendorVersion();
    my @cmd;

    for my $opt ("$bestVendor/$version", "$bestVendor/unknown") {
        my $key = "cmd/install/$opt";
        next unless exists $cmdsRef{$key};
        @cmd = split(' ', $cmdsRef{$key});
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
    my $deps_data_path = shift;

    # Debian handles Ubuntu also
    my @supportedDistros = qw/alpine arch debian fedora freebsd gentoo mageia openbsd opensuse/;

    my $bestVendor = $os->bestDistroMatch(@supportedDistros);
    my $version = $os->vendorVersion();
    say colorize ("    Installing packages for b[$bestVendor]/b[$version]");
    return _packagesForVendor($bestVendor, $version, $deps_data_path);
}

sub _packagesForVendor
{
    my ($vendor, $version, $deps_data_path) = @_;
    my $packagesRef = _readPackages($vendor, $version, $deps_data_path);

    foreach my $opt ("pkg/$vendor/$version", "pkg/$vendor/unknown") {
        next unless exists $packagesRef->{$opt};
        my @packages = split(' ', $packagesRef->{$opt});
        return @packages;
    }

    return;
}

1;
