package ksb::Updater::Svn;

# Module responsible for source code updates on Subversion modules. Used as a
# superclass for our l10n update/build system as well.

use strict;
use warnings;
use v5.10;

our $VERSION = '0.10';

use ksb::Debug;
use ksb::Util;
use ksb::Updater;

our @ISA = qw(ksb::Updater);

use IPC::Open3 qw(open3);

# Returns true if a module has a base component to their name (e.g. KDE/,
# extragear/, or playground).  Note that modules that aren't in trunk/KDE
# don't necessary meet this criteria (e.g. kdereview is a module itself).
sub _has_base_module
{
    my $moduleName = shift;

    return $moduleName =~ /^(extragear|playground|KDE)(\/[^\/]+)?$/;
}

# Subroutine to return the branch prefix. i.e. the part before the branch
# name and module name.
#
# The first parameter is the module name in question.
# The second parameter should be 'branches' if we're dealing with a branch
#      or 'tags' if we're dealing with a tag.
#
# Ex: 'kdelibs'  => 'branches/KDE'
#     'kdevelop' => 'branches/kdevelop'
sub _branch_prefix
{
    my $moduleName = shift;
    my $type = shift;

    # These modules seem to have their own subdir in /tags.
    my @tag_components = qw/arts koffice amarok kst qt taglib/;

    # The map call adds the kde prefix to the module names because I don't feel
    # like typing them all in.
    my @kde_module_list = ((map {'kde' . $_} qw/-base-artwork -wallpapers accessibility
            addons admin artwork base bindings edu games graphics libs
            network pim pimlibs plasma-addons sdk toys utils webdev/));

    # If the user already has the module in the form KDE/foo, it's already
    # done.
    return "$type/KDE" if $moduleName =~ /^KDE\//;

    # KDE proper modules seem to use this pattern.
    return "$type/KDE" if list_has(\@kde_module_list, $moduleName);

    # KDE extragear / playground modules use this pattern
    return "$type" if _has_base_module($moduleName);

    # If we doing a tag just return 'tags' because the next part is the actual
    # tag name, which is added by the caller, unless the module has its own
    # subdirectory in /tags.
    return "$type" if $type eq 'tags' and not list_has(\@tag_components, $moduleName);

    # Everything else.
    return "$type/$moduleName";
}

# This subroutine is responsible for stripping the KDE/ part from the
# beginning of modules that were entered by the user like "KDE/kdelibs"
# instead of the normal "kdelibs".  That way you can search for kdelibs
# without having to strip KDE/ everywhere.
sub _moduleBaseName
{
    my $moduleName = shift;
    $moduleName =~ s/^KDE\///;

    return $moduleName;
}

# Subroutine to return a module URL for a module using the 'branch' option.
# First parameter is the module in question.
# Second parameter is the type ('tags' or 'branches')
sub _handle_branch_tag_option
{
    my $module = assert_isa(shift, 'ksb::Module');
    my $type = shift;
    my $branch = _branch_prefix($module->name(), $type);
    my $svn_server = $module->getOption('svn-server');
    my $branchname = $module->getOption($type eq 'branches' ? 'branch' : 'tag');

    # Remove trailing slashes.
    $svn_server =~ s/\/*$//;

    # Remove KDE/ prefix for module name.
    my $moduleName = _moduleBaseName($module->name());

    # KDE modules have a different module naming scheme than the rest it seems.
    return "$svn_server/$branch/$branchname/$moduleName" if $branch =~ /\/KDE\/?$/;

    # Non-trunk translations happen in a single branch. Assume all non-trunk
    # global branches are intended for the stable translations.
    if ($moduleName =~ /^l10n-kde4\/?/ && $branch ne 'trunk') {
        return "$svn_server/branches/stable/$moduleName";
    }

    # Otherwise don't append the module name by default since it makes more
    # sense to branch this way in many situations (i.e. kdesupport tags, phonon)
    return "$svn_server/$branch/$branchname";
}

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

    foreach my $levelLimit ('module', 'allow-inherit') {
        $modulePath = $module->getOption('module-base-path', $levelLimit);

        # Allow user to override normal processing of the module in a few ways,
        # to make it easier to still be able to use kdesrc-build even when I
        # can't be there to manually update every little special case.
        if($module->getOption('override-url', $levelLimit))
        {
            return $module->getOption('override-url', $levelLimit);
        }

        if($module->getOption('tag', $levelLimit))
        {
            return _handle_branch_tag_option($module, 'tags');
        }

        my $branch = $module->getOption('branch', $levelLimit);
        if($branch and $branch ne 'trunk')
        {
            return _handle_branch_tag_option($module, 'branches');
        }

        my $moduleName = _moduleBaseName($module->name());

        # The following modules are in /trunk, not /trunk/KDE.  There are others,
        # but these are the important ones.
        my @non_trunk_modules = qw(extragear kdesupport koffice icecream kde-common
            playground KDE kdereview www l10n-kde4);

        my $module_root = $moduleName;
        $module_root =~ s/\/.*//; # Remove everything after the first slash

        if (not $modulePath and $levelLimit eq 'allow-inherit')
        {
            $modulePath = "trunk/KDE/$moduleName";
            $modulePath = "trunk/$moduleName" if list_has(\@non_trunk_modules, $module_root);
            $modulePath =~ s/^\/*//; # Eliminate / at beginning of string.
            $modulePath =~ s/\/*$//; # Likewise at the end.
        }

        last if $modulePath;
    }

    # Remove trailing slashes.
    $svn_server =~ s/\/*$//;

    # Note that the module name is no longer appended if module-base-path is used (i.e.
    # $branch variable was set.  This is a change as of version 1.8.
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
        if ($module->buildContext()->getOption('#allow-auto-repo-move'))
        {
            note ("g[$module] is checked out from a different location than expected.");
            note ("Attempting to correct to $module_expected_url");

            my ($expected_host, $expected_path) =
                ($module_expected_url =~ m{://([^/]+)/(.*)$});
            my ($actual_host, $actual_path) =
                ($module_actual_url =~ m{://([^/]+)/(.*)$});

            # If the path didn't change but the host info did try --relocate
            # otherwise try regular svn switch.
            if (($expected_path eq $actual_path) && ($expected_host ne $actual_host)) {
                log_command($module, 'svn-switch', [
                        'svn', 'switch', '--relocate',
                        $module_actual_url, $module_expected_url]);
            }
            else {
                log_command($module, 'svn-switch', [
                        'svn', 'switch', $module_expected_url]);
            }
            return;
        }

        warning (<<EOF);
y[!!]
y[!!] g[$module] seems to be checked out from somewhere other than expected.
y[!!]

kdesrc-build expects:        y[$module_expected_url]
The module is actually from: y[$module_actual_url]

If the module location is incorrect, you can fix it by either deleting the
g[b[source] directory, or by changing to the source directory and running
svn switch $module_expected_url

If the module is fine, please update your configuration file.

If you use kdesrc-build with --src-only it will try switching for you (might not work
correctly).
EOF
    }
    else { # The two URLs match, but are they *right*? Things changed June 2013
        my ($uid, $url);
        # uid might be empty, we use $url to see if the match succeeds.
        ($uid, $url) = $module_actual_url =~ m{^svn\+ssh://(?:([a-z]+)\@)?(svn\.kde\.org)};

        if ($url && (!$uid || $uid ne 'svn')) {
            error ("SVN login scheme has changed for y[b[$module] as of 2013-06-21");
            error ("\tPlease see http://mail.kde.org/pipermail/kde-cvs-announce/2013/000112.html");
            error ("\tPlease update your b[svn-server] option to be:");
            error ("\tb[g[svn+ssh://svn\@svn.kde.org/home/kde");
            error ("\n\tThen, re-run kdesrc-build with the b[--src-only] option to complete the repair.");

            if (!$uid) {
                error (" r[b[* * *]: Note that your SVN URL has *no* username");
                error (" r[b[* * *]: You should probably also double-check ~/.ssh/config");
                error (" r[b[* * *]: for b[svn.kde.org] to ensure the correct default user (svn)");
            }

            croak_runtime ("SVN server has changed login scheme, see error message");
        }
    }
}

# This procedure should be run before any usage of a local working copy to
# ensure it is valid. This should only be run if there's actually a local
# copy.
#
# Any errors will be fatal, so a 'Runtime' exception would be raised.
sub check_module_validity
{
    my $self = assert_isa(shift, 'ksb::Updater::Svn');
    my $module = $self->module();

    # svn 1.7 has a different working copy format that must be manually
    # converted. This will mess up everything else so make this our first
    # check.
    p_chdir($module->fullpath('source'));

    # gensym makes a symbol that can be made a filehandle by open3
    use Symbol qw(gensym);

    # Can't use filter_program_output as that doesn't capture STDERR on
    # purpose. We, on the other hand, just want STDERR.
    my $stderrReader = gensym();
    my $pid = open3(undef, undef, $stderrReader,
        'svn', '--non-interactive', 'status');

    my @errorLines = grep { /:\s*E155036:/ } (<$stderrReader>);
    waitpid ($pid, 0);

    if (@errorLines) {
        warning (<<EOF);
y[*] A new version of svn has been installed which requires a b[one-time] update
y[*] Currently running b[svn upgrade], this may take some time but should only
y[*] be needed once.
EOF

        if (0 != log_command($module, 'svn-upgrade', ['svn', '--non-interactive', 'upgrade'])) {
            error (<<EOF);
r[*] Unable to run b[svn upgrade] for b[r[$module]!
r[*] If you have no local changes you should try deleting the $module
r[*] source directory, and re-run b[kdesrc-build], which will re-download.
r[*]
r[*] There is no way for kdesrc-build to safely make this check for you as
r[*] the old version of b[svn] is required to read the current repository!
EOF
            croak_runtime("Unable to run svn upgrade for $module");
        }

        # By this point svn-upgrade should have run successfully, unless
        # we're in pretend mode.
        if (pretending()) {
            croak_runtime("Unable to use --pretend for svn module $module until svn-upgrade is run");
        }
    }

    # Ensure the URLs are correct.
    $self->_verifyCorrectServerURL();
}

# Subroutine used to handle the checkout-only option.  It handles updating
# subdirectories of an already-checked-out module.
#
# This function can throw an exception in the event of a update failure.
#
# First parameter is the module.
# All remaining parameters are subdirectories to check out.
#
# Returns the number of files changed by the update, or undef if unable to
# be determined.
sub update_module_subdirectories
{
    my $self = assert_isa(shift, 'ksb::Updater::Svn');
    my $module = $self->module();
    my $numChanged = 0;

    # If we have elements in @path, download them now
    for my $dir (@_)
    {
        info ("\tUpdating g[$dir]");

        my $logname = $dir;
        $logname =~ tr{/}{-};

        my $count = $self->run_svn("svn-up-$logname", [ 'svn', 'up', $dir ]);
        $numChanged = undef unless defined $count;
        $numChanged += $count if defined $numChanged;
    }

    return $numChanged;
}

# Checkout a module that has not been checked out before, along with any
# subdirectories the user desires.
#
# This function will throw an exception in the event of a failure to update.
#
# The first parameter is the module to checkout (including extragear and
# playground modules).
# All remaining parameters are subdirectories of the module to checkout.
#
# Returns number of files affected, or undef.
sub checkout_module_path
{
    my $self = assert_isa(shift, 'ksb::Updater::Svn');
    my $module = $self->module();
    my @path = @_;
    my %pathinfo = $module->getInstallPathComponents('source');
    my @args;

    if (not -e $pathinfo{'path'} and not super_mkdir($pathinfo{'path'}))
    {
        croak_runtime ("Unable to create path r[$pathinfo{path}]!");
    }

    p_chdir ($pathinfo{'path'});

    my $svn_url = $self->svn_module_url();
    my $modulename = $pathinfo{'module'}; # i.e. kdelibs for KDE/kdelibs as $module

    push @args, ('svn', 'co', '--non-interactive');
    push @args, '-N' if scalar @path; # Tells svn to only update the base dir
    push @args, $svn_url;
    push @args, $modulename;

    note ("Checking out g[$module]");

    my $count = $self->run_svn('svn-co', \@args);

    p_chdir ($pathinfo{'module'}) if scalar @path;

    my $count2 = $self->update_module_subdirectories(@path);

    return $count + $count2 if defined $count and defined $count2;
    return undef;
}

# Update a module that has already been checked out, along with any
# subdirectories the user desires.
#
# This function will throw an exception in the event of an update failure.
#
# The first parameter is the module to checkout (including extragear and
# playground modules).
# All remaining parameters are subdirectories of the module to checkout.
sub update_module_path
{
    my ($self, @path) = @_;
    assert_isa($self, 'ksb::Updater::Svn');
    my $module = $self->module();
    my $fullpath = $module->fullpath('source');
    my @args;

    p_chdir ($fullpath);

    push @args, ('svn', 'up', '--non-interactive');
    push @args, '-N' if scalar @path;

    note ("Updating g[$module]");

    my $count = eval { $self->run_svn('svn-up', \@args); };

    # Update failed, try svn cleanup.
    if ($@ && $@->{exception_type} ne 'ConflictPresent')
    {
        info ("\tUpdate failed, trying a cleanup.");
        my $result = safe_system('svn', 'cleanup');
        $result == 0 or croak_runtime ("Unable to update $module, " .
                           "svn cleanup failed with exit code $result");

        info ("\tCleanup complete.");

        # Now try again (allow exception to bubble up this time).
        $count = $self->run_svn('svn-up-2', \@args);
    }

    my $count2 = $self->update_module_subdirectories(@path);

    return $count + $count2 if defined $count and defined $count2;
    return undef;
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

    my $revision = $module->getOption('revision');
    if ($revision ne '0')
    {
        my @tmp = @{$arg_ref};

        # Insert after first two entries, deleting 0 entries from the
        # list.
        splice @tmp, 2, 0, '-r', $revision;
        $arg_ref = \@tmp;
    }

    my $count = 0;
    my $conflict = 0;

    my $callback = sub {
        return unless $_;

        # The check for capitalized letters in the second column is because
        # svn can use the first six columns for updates (the characters will
        # all be uppercase), which makes it hard to tell apart from normal
        # sentences (like "At Revision foo"
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

# Subroutine to check for subversion conflicts in a module.  Basically just
# runs svn st and looks for "^C".
#
# First parameter is the module to check for conflicts on.
# Returns 0 if a conflict exists, non-zero otherwise.
sub module_has_conflict
{
    my $module = assert_isa(shift, 'ksb::Module');
    my $srcdir = $module->fullpath('source');

    if ($module->getOption('no-svn'))
    {
        whisper ("\tSource code conflict check skipped.");
        return 1;
    }
    else
    {
        info ("\tChecking for source conflicts... ");
    }

    my $pid = open my $svnProcess, "-|";
    if (!$pid)
    {
        error ("\tUnable to open check source conflict status: b[r[$!]");
        return 0; # false allows the build to proceed anyways.
    };

    if (0 == $pid)
    {
        close STDERR; # No broken pipe warnings

        disable_locale_message_translation();
        exec {'svn'} (qw/svn --non-interactive st/, $srcdir) or
            croak_runtime("Cannot execute 'svn' program: $!");
        # Not reached
    }

    while (<$svnProcess>)
    {
        if (/^C/)
        {
            error (<<EOF);
The $module module has source code conflicts present.  This can occur
when you have made changes to the source code in the local copy
at $srcdir
that interfere with a change introduced in the source repository.
EOF

            error (<<EOF);
To fix this, y[if you have made no source changes that you haven't committed],
run y[svn revert -R $srcdir]
to bring the source directory back to a pristine state and trying building the
module again.

NOTE: Again, if you have uncommitted source code changes, running this command
will delete your changes in favor of the version in the source repository.
EOF

            kill "TERM", $pid; # Kill svn
            waitpid ($pid, 0);
            close $svnProcess;
            return 0;
        }
    }

    # conflicts cleared apparently.
    waitpid ($pid, 0);
    close $svnProcess;
    return 1;
}

# scm-specific update procedure.
# May change the current directory as necessary.
# Assumes called as part of a ksb::Module (i.e. $self->isa('ksb::Module') should be true.
sub updateInternal
{
    my $self = assert_isa(shift, 'ksb::Updater::Svn');
    my $module = $self->module();
    my $fullpath = $module->fullpath('source');
    my @options = split(' ', $module->getOption('checkout-only'));

    if (-e "$fullpath/.svn") {
        $self->check_module_validity();
        my $updateCount = $self->update_module_path(@options);

        my $log_filter = sub {
            return unless defined $_;
            print $_ if /^C/;
            print $_ if /Checking for/;
            return;
        };

        # Use log_command as the check so that an error file gets created.
        if (0 != log_command($module, 'conflict-check',
                             ['kdesrc-build', 'ksb::Updater::Svn::module_has_conflict',
                                              $module],
                             { callback => $log_filter, no_translate => 1 })
           )
        {
            croak_runtime (" * Conflicts present in module $module");
        }

        return $updateCount;
    }
    else {
        return $self->checkout_module_path(@options);
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
    # eval since filter_program_output uses exceptions.
    eval
    {
        # Need to chdir into the srcdir, in case srcdir is a symlink.
        # svn info /path/to/symlink barfs otherwise.
        p_chdir ($srcdir);

        my @lines = filter_program_output(
            sub { /^$param:/ },
            'svn', 'info', '--non-interactive', '.'
        );

        croak_runtime ("No svn info output!") unless @lines;
        chomp ($result = $lines[0]);
        $result =~ s/^$param:\s*//;
    };

    if($@)
    {
        error ("Unable to run r[b[svn], is the Subversion program installed?");
        error (" -- Error was: r[$@]");
        return undef;
    }

    return $result;
}

1;

