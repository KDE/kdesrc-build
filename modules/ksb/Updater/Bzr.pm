package ksb::Updater::Bzr 0.10;

# Support the bazaar source control manager for libdbusmenu-qt

use ksb;

use parent qw(ksb::Updater);

use ksb::BuildException;
use ksb::Debug;
use ksb::Util qw(:DEFAULT run_logged_p);

# scm-specific update procedure.
# May change the current directory as necessary.
# Should return a count of files changed (or commits, or something similar)
sub updateInternal ($self, $module)
{
    my $srcbase = $module->getSourceDir();

    # Full path to source directory on-disk.
    my $srcdir = $module->fullpath('source');
    my $bzrRepoName = $module->getOption('repository');

    # Or whatever regex is appropriate to strip the bzr URI protocol.
    $bzrRepoName =~ s/^bzr:\/\///;

    my $promise;
    my $failMessage;
    my $failed;

    if (! -e "$srcdir/.bzr") {
        # BuildContext assumes bzr will create the $srcdir directory and then
        # check the source out into that directory.
        my @cmd = ('bzr', 'branch', $bzrRepoName, $srcdir);

        $promise = run_logged_p($module, 'bzr-branch', $srcbase, \@cmd);
        $failMessage = "Unable to checkout $module!";
    } else {
        # Update existing checkout. The source is currently in $srcdir
        p_chdir($srcdir);

        $promise = run_logged_p($module, 'bzr-pull', $srcdir, ['bzr', 'pull']);
        $failMessage = "Unable to update $module!";
    }

    $promise = $promise->then(sub ($exitcode) {
        $failed = ($exitcode != 0);
    });

    $promise->wait; # TODO: convert to return promise

    croak_runtime($failMessage)
        if $failed;
    return 1; # we don't count changes
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
