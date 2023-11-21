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

    SHELL_SEPARATOR_SNIPPET => <<'RC',
################################################################################
RC
};

=head1 FUNCTIONS

=cut

our $baseDir;

sub yesNoPrompt {
    my $msg = shift;

    local $| = 1;
    print "$msg (y/N) ";
    chomp(my $answer = <STDIN>);
    return lc($answer) eq 'y';
}

sub setupUserSystem
{
    $baseDir = shift;
    my @setup_steps = @_;
    my $os = ksb::OSSupport->new;
    my $envShell = $ENV{'SHELL'} // 'undefined';
    my $shellName = (split '/', $envShell)[-1];

    eval {
        if (grep { $_ eq "install-distro-packages" } @setup_steps) {
            _installSystemPackages($os);
        }
        if (grep { $_ eq "generate-config" } @setup_steps) {
            _setupBaseConfiguration();
        }
        if (grep { $_ eq "update-shellrc" } @setup_steps) {
            _setupShellRcFile($shellName);
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
my %packages;
sub _readPackages
{
    my $vendor = shift;
    my $version = shift;

    return \%packages if %packages;

    open(my $file, '<', "$baseDir/data/pkg/$vendor.ini") or _throw("Cannot open file \"$baseDir/data/pkg/$vendor.ini\"");
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
        if (!@packages) {
            @installCmd = "# All dependencies are already installed. No need to run pacman. :)";
        }
    }

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
    my ($shellName) = @_;
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
        $rcFilepath = "$ENV{'XDG_CONFIG_HOME'}/fish/conf.d/kdesrc-build.fish";
      } else {
        $rcFilepath = "$ENV{'HOME'}/.config/fish/conf.d/kdesrc-build.fish";
      }
    } else {
        $rcFilepath = "$ENV{'HOME'}/.profile";
        say colorize(" y[b[*] Couldn't detect the shell, using $rcFilepath.");
        $extendedShell = 0;
    }

    $printableRcFilepath = $rcFilepath;
    $printableRcFilepath =~ s/^$ENV{HOME}/~/;

    open(my $file, '<', "$baseDir/data/kdesrc-run-completions.sh") or _throw("Cannot open file \"$baseDir/data/kdesrc-run-completions.sh\"");
    my $kdesrc_run_completions = do { local $/; <$file> };
    close($file);
    # Used for bash/zsh and requires non-POSIX syntax support.
    my $EXT_SHELL_RC_SNIPPET = $kdesrc_run_completions . SHELL_SEPARATOR_SNIPPET;
    my $addToShell = yesNoPrompt(colorize(" b[*] Update your b[y[$printableRcFilepath]?"));

    if ($addToShell) {
        open(my $rcFh, '>>', $rcFilepath)
            or _throw("Couldn't open $rcFilepath: $!");

        say $rcFh '';

        if ($shellName ne 'fish') {
          say $rcFh BASE_SHELL_SNIPPET . "export PATH=\"$baseDir:\$PATH\"\n";

          say $rcFh $EXT_SHELL_RC_SNIPPET
              if $extendedShell;
        } else {
          say $rcFh BASE_SHELL_SNIPPET . "fish_add_path --global $baseDir\n";
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
        say $EXT_SHELL_RC_SNIPPET
            if $extendedShell;
    }
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

    # Debian handles Ubuntu also
    my @supportedDistros = qw/alpine arch debian fedora freebsd gentoo mageia opensuse/;

    my $bestVendor = $os->bestDistroMatch(@supportedDistros);
    my $version = $os->vendorVersion();
    say colorize ("    Installing packages for b[$bestVendor]/b[$version]");
    return _packagesForVendor($bestVendor, $version);
}

sub _packagesForVendor
{
    my ($vendor, $version) = @_;
    my $packagesRef = _readPackages($vendor, $version);

    foreach my $opt ("pkg/$vendor/$version", "pkg/$vendor/unknown") {
        next unless exists $packagesRef->{$opt};
        my @packages = split(' ', $packagesRef->{$opt});
        return @packages;
    }

    return;
}

1;
