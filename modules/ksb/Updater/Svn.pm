package ksb::Updater::Svn 0.20;

# Module responsible for source code updates on Subversion modules. Used as a
# superclass for our l10n update/build system as well.

use warnings;
use v5.22;

use parent qw(ksb::Updater);

use ksb::BuildException;
use ksb::Debug;
use ksb::Util;

use IPC::Open3 qw(open3);

# Subroutine to return the appropriate SVN URL for a given module, based on
# the user settings.  For example, 'kdelibs' ->
# https://svn.kde.org/home/kde/trunk/KDE/kdelibs
#
# This operates under a double hierarchy:
# 1. If any module-specific option is present, it wins.
# 2. If only global options are present, the order override-url, tag,
#    branch, module-base-path, is preferred.
sub svn_module_url
{
    my $self = assert_isa(shift, 'ksb::Updater::Svn');
    my $module = $self->module();
    my $svn_server = $module->getOption('svn-server');
    my $modulePath;
    my $url;

    foreach my $levelLimit ('module', 'allow-inherit') {
        # Allow user to override normal processing of the module in a few ways,
        # to make it easier to still be able to use kdesrc-build even when I
        # can't be there to manually update every little special case.
        return $url if $url = $module->getOption('override-url', $levelLimit);

        croak_runtime ("$module: 'tag' option is no longer supported for svn-based modules")
            if $module->getOption('tag', $levelLimit);

        croak_runtime ("$module: 'branch' option is no longer supported for svn-based modules")
            if ($module->getOption('branch', $levelLimit) // '') ne 'trunk';

        $modulePath = $module->getOption('module-base-path', $levelLimit);
        $modulePath = "trunk/$module"
            if (not $modulePath and $levelLimit eq 'allow-inherit');

        last if $modulePath;
    }

    # Remove trailing slashes.
    $svn_server =~ s/\/*$//;

    return "$svn_server/$modulePath";
}

# Subroutine to determine whether or not the given module has the correct
# URL.  If not, a warning is printed out.
# First parameter: module to check.
# Return: Nothing.
sub _verifyCorrectServerURL
{
    my $self = assert_isa(shift, 'ksb::Updater::Svn');
    my $module = $self->module();

    my $module_expected_url = $self->svn_module_url();
    my $module_actual_url = $self->svnInfo('URL');

    if (!$module_actual_url) {
        croak_runtime ("Unable to determine working copy's svn URL for $module");
    }

    $module_expected_url =~ s{/+$}{}; # Remove trailing slashes
    $module_actual_url   =~ s{/+$}{}; # Remove trailing slashes

    if ($module_actual_url ne $module_expected_url)
    {
        # Check if the --src-only flag was passed.
        my $module = $self->module();

        warning (<<EOF);
y[!!]
y[!!] g[$module] is checked out from the wrong location
y[!!]

kdesrc-build expects:        y[$module_expected_url]
The module is actually from: y[$module_actual_url]

If the module is actually checked out from the wrong location, you can fix it
by either deleting the g[b[source] directory, or by changing to the source
directory and running:
svn switch $module_expected_url

If the module is fine, please update your configuration file to reflect the
existing location.

Once done you can run kdesrc-build again.
EOF
    }
}

# Checkout a module that is not already checked out.
#
# This function will throw an exception in the event of a failure to update.
#
# The first parameter is the module to checkout.
#
# Returns number of files affected
sub checkout_module_path
{
    my $self = assert_isa(shift, 'ksb::Updater::Svn');
    my $module = $self->module();
    my %pathinfo = $module->getInstallPathComponents('source');

    croak_runtime ("Unable to create path r[$pathinfo{path}]!")
        if (not -e $pathinfo{'path'} and not super_mkdir($pathinfo{'path'}));

    p_chdir ($pathinfo{'path'});

    my $svn_url = $self->svn_module_url();
    my $modulename = $pathinfo{'module'}; # i.e. kdelibs for KDE/kdelibs as $module

    return $self->run_svn('svn-co', [qw(svn co --non-interactive), $svn_url, $modulename]);
}

# Update a module that has already been checked out.
#
# This function will throw an exception in the event of an update failure.
#
# The first parameter is the module to checkout.
sub update_module_path
{
    my ($self) = @_;
    assert_isa($self, 'ksb::Updater::Svn');
    my $module = $self->module();

    p_chdir ($module->fullpath('source'));

    return $self->run_svn('svn-up', [qw(svn up --non-interactive)]);
}

# Run the svn command.  This is a special subroutine so that we can munge
# the generated output to see what files have been added, and adjust the
# build according.
#
# This function will throw an exception in the event of a build failure.
#
# First parameter is the ksb::Module object we're building.
# Second parameter is the filename to use for the log file.
# Third parameter is a reference to a list, which is the command ('svn')
#       and all of its arguments.
# Return value is the number of files update (may be undef if unable to tell)
sub run_svn
{
    my ($self, $logfilename, $arg_ref) = @_;
    assert_isa($self, 'ksb::Updater::Svn');
    my $module = $self->module();

    my $revision = $module->getOption('revision') || 0;
    splice (@{$arg_ref}, 2, 0, '-r', $revision)
        if $revision ne '0';

    my $count = 0;
    my $conflict = 0;

    my $callback = sub {
        return unless $_;

        # The check for capitalized letters in the second column is because
        # svn can use the first six columns for updates (the characters will
        # all be uppercase), which makes it hard to tell apart from normal
        # sentences (like "At Revision foo")
        $count++      if /^[UPDARGMC][ A-Z]/;
        $conflict = 1 if /^C[ A-Z]/;
    };

    # Do svn update.
    my $result = log_command($module, $logfilename, $arg_ref, { callback => $callback });

    return 0 if pretending();

    croak_runtime("Error updating $module!") unless $result == 0;

    if ($conflict)
    {
        warning ("Source code conflict exists in r[$module], this module will not");
        warning ("build until it is resolved.");

        die make_exception('ConflictPresent', "Source conflicts exist in $module");
    }

    return $count;
}

# scm-specific update procedure.
# May change the current directory as necessary.
# Assumes called as part of a ksb::Module (i.e. $self->isa('ksb::Module') should be true.
sub updateInternal
{
    my $self = assert_isa(shift, 'ksb::Updater::Svn');
    my $module = $self->module();
    my $fullpath = $module->fullpath('source');

    if (-e "$fullpath/.svn") {
        $self->_verifyCorrectServerURL();
        return $self->update_module_path();
    }
    else {
        return $self->checkout_module_path();
    }
}

sub name
{
    return 'svn';
}

sub currentRevisionInternal
{
    my $self = assert_isa(shift, 'ksb::Updater::Svn');
    return $self->svnInfo('Revision');
}

# Returns a requested parameter from 'svn info'.
#
# First parameter is a string with the name of the parameter to retrieve (e.g. URL).
#   Each line of output from svn info is searched for the requested string.
# Returns the string value of the parameter or undef if an error occurred.
sub svnInfo
{
    my $self = assert_isa(shift, 'ksb::Updater::Svn');
    my $module = $self->module();

    my $param = shift;
    my $srcdir = $module->fullpath('source');
    my $result; # Predeclare to outscope upcoming eval

    if (pretending() && ! -e $srcdir) {
        return 'Unknown';
    }

    # Search each line of output, ignore stderr.
    # Need to chdir into the srcdir, in case srcdir is a symlink.
    # svn info /path/to/symlink barfs otherwise.
    p_chdir ($srcdir);

    # filter_program_output can itself throw exceptions
    my @lines = filter_program_output(
        sub { /^$param:/ },
        'svn', 'info', '--non-interactive', '.'
    );

    croak_runtime ("No svn info output!")
        unless @lines;

    chomp ($result = $lines[0]);
    $result =~ s/^$param:\s*//;
    return $result;
}

1;

