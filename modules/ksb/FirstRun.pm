package ksb::FirstRun 0.10;

use 5.014;
use strict;
use warnings;
use File::Spec qw(splitpath);

use ksb::Debug qw(colorize);
use ksb::Util;
use ksb::OSSupport;

=head1 NAME

ksb::FirstRun

=head1 DESCRIPTION

Performs initial-install setup, implementing the C<--initial-setup> option.

=head1 SYNOPSIS

    my $exitcode = ksb::FirstRun::setupUserSystem();
    exit $exitcode;

=cut

sub setupUserSystem
{
    my $os = ksb::OSSupport->new;

    eval {
        _installSystemPackages($os);
        _setupBaseConfiguration();
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
        next if $line =~ /^\s*#/;
        chomp $line;

        my ($fname) = ($line =~ /^@@ *([^ ]+)$/);
        if ($fname) {
            $commit->();
            $cur_file = $fname;
            $cur_value = '';
        }
        else {
            $cur_value .= "$line ";
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
    my @packages = _findBestVendorPackageList($os);

    say colorize(<<DONE);
 b[1.] Installing b[system packages] for b[$vendor]...
DONE

    sleep 3;
}

sub _setupBaseConfiguration
{
    if (-e "kdesrc-buildrc" || -e "$ENV{HOME}/.kdesrc-buildrc") {
        say colorize(<<DONE);
 b[2.] You b[y[already have a configuration file], skipping this step...
DONE
    } else {
        say colorize(<<DONE);
 b[2.] Installing b[sample configuration file]...
DONE
        # TODO: Bring that whole script inline here since we need to know
        # the path for bashrc
        my (undef, $baseDir) = File::Spec->splitpath($0);
        _throw("Can't find setup script")
            unless -e "$baseDir/kdesrc-build-setup" && -x _;

        my $result = system("$baseDir/kdesrc-build-setup");
        _throw("setup script failed: $!")
            unless ($result >> 8) == 0;
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

sub _findBestVendorPackageList
{
    my $os = shift;

    # Debian handles Ubuntu also
    my @supportedDistros =
        map  { s{^pkg/([^/]+)/.*$}{$1}; $_ }
        grep { /^pkg\// }
            keys %{_readPackages()};

    my $bestVendor = $os->bestDistroMatch(@supportedDistros);
    return _packagesForVendor($bestVendor);
}

sub _packagesForVendor
{
    my $vendor = shift;
    my $packagesRef = _readPackages();
    my @opts = grep { /^pkg\/$vendor\b/ } keys %{$packagesRef};

    # TODO Narrow to one set based on distro version
    my @packages;
    foreach my $opt (@opts) {
        @packages = split(' ', $packagesRef->{$opt});
    }

    return @packages;
}

1;

__DATA__
@@ pkg/debian/unknown
shared-mime-info

@@ pkg/opensuse/tumbleweed
shared-mime-info

@@ pkg/fedora/unknown
git

@@ pkg/gentoo/unknown
dev-util/cmake
dev-lang/perl

@@ pkg/arch/unknown
perl-json
