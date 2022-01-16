package ksb::Updater::Bzr 0.10;

# Support the bazaar source control manager for libdbusmenu-qt

use ksb;

use parent qw(ksb::Updater);

use ksb::BuildException;
use ksb::Debug;
use ksb::Util;

# scm-specific update procedure.
# May change the current directory as necessary.
# Should return a count of files changed (or commits, or something similar)
sub updateInternal
{
    my $self = assert_isa(shift, 'ksb::Updater::Bzr');
    my $module = assert_isa($self->module(), 'ksb::Module');

    p_chdir($module->getSourceDir());

    # Full path to source directory on-disk.
    my $srcdir = $module->fullpath('source');
    my $bzrRepoName = $module->getOption('repository');

    # Or whatever regex is appropriate to strip the bzr URI protocol.
    $bzrRepoName =~ s/^bzr:\/\///;

    if (! -e "$srcdir/.bzr") {
        # Cmdline assumes bzr will create the $srcdir directory and then
        # check the source out into that directory.
        my @cmd = ('bzr', 'branch', $bzrRepoName, $srcdir);

        croak_runtime("Unable to checkout $module!")
            if log_command($module, 'bzr-branch', \@cmd) != 0;

        # TODO: Filtering the output by passing a subroutine to log_command
        # should give us the number of revisions, or we can just somehow
        # count files.
        my $newRevisionCount = 1;
        return $newRevisionCount;
    }
    else {
        # Update existing checkout. The source is currently in $srcdir
        p_chdir($srcdir);

        croak_runtime("Unable to update $module!")
            if log_command($module, 'bzr-pull', ['bzr', 'pull']) != 0;

        # I haven't looked at bzr up output yet to determine how to find
        # number of affected files or number of revisions skipped.
        my $changeCount = 1;
        return $changeCount;
    }

    return 0;
}

sub name
{
    return 'bzr';
}

# This is used to track things like the last successfully installed
# revision of a given module.
sub currentRevisionInternal
{
    my $self = assert_isa(shift, 'ksb::Updater::Bzr');
    my $module = $self->module();
    my $result;

    # filter_program_output can throw exceptions
    eval {
        p_chdir($module->fullpath('source'));

        ($result, undef) = filter_program_output(undef, 'bzr', 'revno');
        chomp $result if $result;
    };

    if ($@) {
        error ("Unable to run r[b[bzr], is bazaar installed?");
        error (" -- Error was: r[$@]");
        return undef;
    }

    return $result;
}

1;
